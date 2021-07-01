Cut over plan: migration from Gerrit version 2.15.22 to 2.16.27 latest
==

Glossary
==
* HA (High-Availability): highly available installation of Gerrit with 2 masters
and X slaves
* gerrit-1: the name of the first Gerrit master in HA
* gerrit-2: the name of the second Gerrit master in HA
* primary: Gerrit instance currently receiving both read and write traffic
* secondary: Gerrit instance in standby, not receiving traffic
* git repositories: bare git repositories served by Gerrit stored in `gerrit.basePath`
* caches: persistent H2 database files stored in the `$GERRIT_SITE/cache` directory
* indexes: Lucene index files stored in the `$GERRIT_SITE/index` directory
* ReviewDB: Postgres database containing review data
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit specified
  during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration plan will allow no downtime. Both Read and Write
operation will be allowed during the migration.

There will be a short readonly window to allow backing up the git
repositories and ReviewDB. The window depends on the backup strategy used,
see the prerequisites section below.

Once the cutover actions will be reviewed, agreed tested and measured in staging,
all the operational side of the cutover should be automated to reduce possible
human mistakes.

Pre-cutover (2 week before cutover)
==
1. Notify all users (2 weeks before cutover) that new projects creation will be disabled.

Pre-cutover (1 week before cutover)
==
1. Block new projects creation by changing the [Create Project ACL](https://gerrit-documentation.storage.googleapis.com/Documentation/2.15.22/access-control.html#capability_createProject)
2. Create production enviroment snapshot and restore it on staging
3. On *staging* run offline reindexing for projects index:
3a. Stop secondary gerrit instance
3b. Upgrade secondary gerrit instance to 2.16.27
`java -jar gerrit-2.16.27.war init -d $GERRIT_SITE --no-auto-start --no-reindex --batch`
3c. Run offline reindexing for projects index
`java -jar gerrit-2.16.27.war reindex --index projects -d $GERRIT_SITE`
3d. Keep $GERRIT_SITE/index/projects_0004 directory

Prerequisites before starting the migration
==
1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels
3. Backup git repositories, ReviewDB, caches and indexes. There are 2 possible ways
of doing it:
3a. Simple with longer Read Only window:
  * Put the system in Read Only (`touch $GERRIT_SITE/etc/gerrit.readonly` on both gerrit-1 and gerrit-2)
  * Take a snapshot of Git repositories, review DB, caches, indexes
  * Put the system back in Read Write (`rm $GERRIT_SITE/etc/gerrit.readonly` on both gerrit-1 and gerrit-2)
3b. Complex with short Read Only window:
  * Rsync the git repositories prior to starting the migration to a backup storage
  * Put system in Read Only (`touch $GERRIT_SITE/etc/gerrit.readonly` on both gerrit-1 and gerrit-2)
  just before starting the migration
  * Rsync the git repositories to the backup storage used earlier and backup ReviewDB and indexes
  * Put the system in Read Write (`rm $GERRIT_SITE/etc/gerrit.readonly` on both gerrit-1 and gerrit-2)
4. Add exception to load balancer to route gatling test traffic to gerrit-2.
   This can be done in two ways:
   - route by source ip
   - route by HTTP header - this way requires a small change in the gatling tests
     to set  HTTP header.

Migration and testing
==

First phase: gerrit-2 node migration and observation
==

1. Run a baseline with the Gatling tests
2. Mark gerrit-2 as unhealthy, so it won't receive any traffic. Log into gerrit-2 and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin remove healthcheck`
3. Stop gerrit-2
4. Take note of the time the node has been stopped (we will refer it as
  `migration-start-time-gerrit-2`). It will be needed in case of rollback (See __Rollback strategy__ below).
5. Upgrade plugins, lib and war file on gerrit-2
   - All plugins can be found in the [GerritForge CI](https://gerrit-ci.gerritforge.com/view/Plugins-stable-2.16/)
   - Gerrit.war file can be found [here](https://gerrit-releases.storage.googleapis.com/gerrit-2.16.27.war)
6. Run gerrit init on gerrit-2 `java -jar gerrit-2.16.27.war init -d $GERRIT_SITE --no-reindex --no-auto-start --batch`
7. Copy projects index(projects_0004 directory) from staging to $GERRIT_SITE/index/ directory.
8. Append following projects index version to $GERRIT_SITE/index/gerrit_index.config:
[index "projects_0004"]
        ready = true
9. Run offline reindexing for groups index:
  `java -jar gerrit-2.16.27.war reindex --index groups -d $GERRIT_SITE`
10. Restart gerrit-2
8. Wait for the online reindexing of accounts and changes to finish (this step will need to be carefully timed during the staging environment migration)
  * Check for the indexing to finish:
    `> grep "OnlineReindexer : Using" logs/error_log
[2021-07-01 19:27:25,644] [Reindex accounts v7-v10] INFO  com.google.gerrit.server.index.OnlineReindexer : Using accounts schema version 10
[2021-07-01 19:27:25,810] [Reindex changes v48-v50] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 50`
  * Check for indexing errors:
    `> grep "OnlineReindexer : Error" logs/error_log`
  * If errors are present something similar will be found in the logs:
  `grep "OnlineReindexer : Error" logs/error_log
[2021-05-12 19:33:23,890] [Reindex changes v48-v50] WARN  com.google.gerrit.server.index.OnlineReindexer : Error activating new changes schema version 50`
  * Furthermore, check the following indexes migration status on the `$GERRIT_SITE/index/gerrit_index.config`, where `groups_0007`, `accounts_0010` and `changes_0050` need to be marked as `ready = true`:
  `> cat index/gerrit_index.config
[index "projects_0004"]
        ready = true
[index "groups_0007"]
        ready = true
[index "accounts_0010"]
        ready = true
[index "changes_0050"]
        ready = true
`
9. Run Gatling tests against gerrit-2
10. Compare and assess the results of the tests and decide if going forward with
the migration or rollback.
11. Migrate the Gerrit slaves (see the __Gerrit slaves migration__ section below)
12. Run the Jenkins build verification tests
13. Mark node as healthy. Log into gerrit-2 and run
  `mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`
14. Route traffic to gerrit-2 making it the primary node. Set gerrit-2 as primary
node in the load balancer

At this point it is good practice to introduce an observation period where nodes are
running the two versions. gerrit-2 with 2.16 will be the primary node and gerrit-1 with 2.15
the secondary.

The observation period should be enough to have *real traffic* going through the
system for a number of hours and see the real E2E flow going.

This will allow a quick rollback (see the __Rollback strategy__ below) to Gerrit v2.15 if needed.

Second phase: gerrit-1 node migration
==

13. Mark gerrit-1 as unhealthy, so it won't receive any traffic. Log into gerrit-1 and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin remove healthcheck`
14. Stop gerrit-1
15. Take note of the time the node has been stopped (we will refer it as `migration-start-time-gerrit-1`)
It will be needed in case of rollback (see the __Rollback strategy__ section below).
16. Upgrade plugins, lib and war file on gerrit-1
17. Set gerrit-2 in Read Only (`touch $GERRIT_SITE/etc/gerrit.readonly` on gerrit-2)
18. Copy indexes over from gerrit-2 node to gerrit-1. All the `$GERRIT_SITE/index` directory
need to be copied over
19. Set gerrit-2 as read-write (`rm $GERRIT_SITE/etc/gerrit.readonly` on gerrit-2)
20. The HA plugin keeps the last update timestamp for each index in the following files:
`$GERRIT_SITE/data/high-availability/group`
`$GERRIT_SITE/data/high-availability/account`
`$GERRIT_SITE/data/high-availability/change`
The timestamp is stored in this format `yyyy-mm-ddTHH:MM:SS.ss`, i.e.: 2020-12-18T12:17:53.25.
Set it back of to `migration-start-time-gerrit-1`.
21. Restart gerrit-1
22. Run Gatling tests against gerrit-1
23. Compare and assess the results of the tests and decide if going forward with
the migration or rollback
24. Mark node as healthy. Log into gerrit-1 and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin enable healthcheck`

Gerrit slaves migration
==

Once happy with the masters upgrade, it will be possible to migrate the slaves as well.
For each slave these are the steps to follow:
1. Remove slave from pool
2. Stop the slave
3. Upgrade plugins, lib and war file
4. Run offline reindexing for groups index
`java -jar gerrit-2.16.27.war reindex --index groups -d $GERRIT_SITE`
5. Restart slaves
6. Put back slave in the pool

Consolidation period and cleanup (TBC - at least 24h after the successful migration)
==

Once the release is done the system is stable, the full Gerrit v2.16 features can be enabled
again.

Rollback strategy
===

The rollback outlined is not meant to cover a disaster recovery case, but only the case of version rollback of a single node:
1. Set node to rollback as unhealthy. Log into the node and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin remove healthcheck`
2. Stop the node
3. Downgrade plugins, lib and gerrit.war to 2.15.22
4. Restore previous indexes version in `index/gerrit_index.config`:
`[index "groups_0004"]
  ready = true
[index "accounts_0007"]
  ready = true
[index "changes_0048"]
  ready = true`
5. Downgrade schema version `update schema_version set version_nbr = 161;`
6. The HA plugin keeps the last update timestamp for each index in the following files:
`$GERRIT_SITE/data/high-availability/group`
`$GERRIT_SITE/data/high-availability/account`
`$GERRIT_SITE/data/high-availability/change`
The timestamp is stored in this format `yyyy-mm-ddTHH:MM:SS.ss`, i.e.: 2020-12-18T12:17:53.25.
Set those timestamp to `migration-start-time-<node_name>`.
7. Restart the node
8. Set node to rollback as healthy. Log into gerrit-1 and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin enable healthcheck`

Disaster recovery
===

1. Stop the nodes
2. Downgrade plugins, lib and gerrit.war to 2.15.22
3. Restore previous indexes, caches, git repositories and DB from the initial backup. **NOTE** All data created or modified in Gerrit
   after the initial backup would be lost. This path should therefore taken as __last resort__ after the rollback strategy has failed
   and no remediation has been identified.
4. Restart the nodes

Notes
==
* All the operations need to be performed in a staging environment first to anticipate possible issues happening in production
* All the operations need to be timed to have an idea on how long the whole process will take

Useful references
==

[1]: [Gerrit 2.15 documentation](https://www.gerritcodereview.com/2.15.html)

[2]: [Gerrit 2.16 documentation](https://www.gerritcodereview.com/2.16.html)

[3]: [Zero downtime Gerrit](https://www.slideshare.net/lucamilanesio/zerodowntime-gerrit-code-review-upgrades)
