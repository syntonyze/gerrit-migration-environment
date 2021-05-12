Cut over plan: migration from Gerrit version 2.14.20 to 2.15 latest
==

Glossary
==
* HA (High-Availability): highly available installation of Gerrit with 2 masters
and X replicas
* gerrit-1: the name of the first Gerrit master in HA
* gerrit-2: the name of the second Gerrit master in HA
* primary: Gerrit instance currently receiving both read and write traffic
* secondary: Gerrit instance in standby, not receiving traffic
* git repositories: bare git repositories served by Gerrit stored in `gerrit.basePath`
* caches: persistent H2 database files stored in the `$GERRIT_SITE/cache` directory
* indexes: Lucene index files stored in the `$GERRIT_SITE/index` directory
* ReviewDB: Postgres database containing review data
* $GERRIT_SITE: environment variable pointing to the base directory of Gerrit specified
  during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration plan will allow no downtime. Both Read and Write
operation will be allowed during the migration.

There will be a short readonly window to allow backing up the git
repositories and ReviewDB. The window depends on the backup strategy used,
see [prerequisites](./Prerequisites).

Once the cutover actions will be reviewed, agreed tested and measured in staging,
all the operational side of the cutover should be automated to reduce possible
human mistakes.

Pre-cutover (2 weeks before cutover)
==

* Notify all users (2 weeks before cutover) that they should publish all their drafts
  otherwise they will be forcibly published.

* Notify all users (e.g. e-mail or other means) that have created drafts.
  Run this query to identify users with open drafts:

`SELECT distinct(email_address) FROM "changes", "account_external_ids"
  WHERE "status" = 'd'
    AND  owner_account_id = account_id
    AND email_address IS NOT NULL;`

Pre-cutover (1 week before cutover)
==

* Publish all pending draft changes.

* Disable draft changes. The following configuration change will be needed to block
the drafts to be published on all the master nodes:

`[change]
  allowDrafts = false
  disablePrivateChanges = true`

* Upgrade of Gerrit Code Review to [v2.14.22](https://www.gerritcodereview.com/2.14.html):

  - Shutdown Gerrit
  - Replace gerrit.war
  - Upgrade high-availability plugin to the [latest version on GerritForge's Support](https://support.gerritforge.com/support/download/gerrit/stable-2.14/plugins/high-availability/v2.14.12-7-ge177db0ea3/high-availability.jar)
  - Startup Gerrit

* Disable calls to WIP [1] for inline patch creation at Load balancer level.
The following calls need to be blocked:

`POST <gerrit_url>/changes/
POST <gerrit_url>/changes/test-project~1/wip`

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
   - high-availability plugin can be found on the [GerritForge Support URL](https://support.gerritforge.com/support/download/gerrit/stable-2.15/plugins/high-availability/v2.15-11-gcdfd0a7e0e/high-availability.jar)
   - metrics-reporter-prometheus plugin can be found on the [GerritForge Support URL](https://support.gerritforge.com/support/download/gerrit/stable-2.15/plugins/metrics-reporter-prometheus/1dedb87219/metrics-reporter-prometheus.jar)
   - other plugins can be found in the [GerritForge Archive CI](https://archive-ci.gerritforge.com/view/Plugins-stable-2.15/)
6. Run gerrit init on gerrit-2 `java -jar gerrit-2.15.22.war init -d $GERRIT_SITE --no-auto-start`:
  * When prompted for `Migrate draft changes to private changes (default is work-in-progress)` response `y` (all drafts should have been published anyway, so this choice isn't strictly relevant anymore)
  * When prompted for `Execute the following SQL to drop unused objects:
                        DROP TABLE account_external_ids;
                        DROP TABLE accounts;
                        ALTER TABLE patch_sets DROP COLUMN draft;
                        Execute now [Y/n]?` response `n`
7. Restart gerrit-2
8. Wait for the online reindexing of accounts, changes and groups to finish (this step will need to be carefully timed during the staging environment migration)
  * Check for the indexing to finish:
    `> grep "OnlineReindexer : Using" logs/error_log
[2021-05-12 19:33:23,754] [Reindex accounts v4-v7] INFO  com.google.gerrit.server.index.OnlineReindexer : Using accounts schema version 7
[2021-05-12 19:33:23,769] [Reindex groups v2-v4] INFO  com.google.gerrit.server.index.OnlineReindexer : Using groups schema version 4
[2021-05-12 19:33:33,598] [Reindex changes v39-v48] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 48`
  * Check for indexing errors:
    `> grep "OnlineReindexer : Error" logs/error_log`
  * If errors are present something similar will be found in the logs:
  `grep "OnlineReindexer : Error" logs/error_log
[2021-05-12 19:33:23,890] [Reindex groups v2-v4] WARN  com.google.gerrit.server.index.OnlineReindexer : Error activating new groups schema version 4`
  * Furthermore, check the following indexes migration status on the `$GERRIT_SITE/index/gerrit_index.config`, where `groups_0004`, `accounts_0007` and `changes_0048` need to be marked as `ready = true`:
  `> cat index/gerrit_index.config
[index "groups_0004"]
	ready = true
[index "accounts_0007"]
	ready = true
[index "changes_0048"]
	ready = true`
9. Run Gatling tests against gerrit-2
10. Compare and assess the results of the tests and decide if going forward with
the migration or rollback.
11. Migrate the Gerrit slaves (see the __Gerrit slaves migration__ section below)
12. Run the Jenkins build verification tests
13. Mark node as healthy. Log into gerrit-2 and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin enable healthcheck`
14. Route traffic to gerrit-2 making it the primary node. Set gerrit-2 as primary
node in the load balancer

At this point it is good practice to introduce an observation period where nodes are
running the two versions. gerrit-2 with 2.15 will be the primary node and gerrit-1 with 2.14
the secondary.

The observation period should be enough to have *real traffic* going through the
system for a number of hours and see the real E2E flow going.

This will allow a quick rollback (see the __Rollback strategy__ below) to Gerrit v2.14 if needed.

Second phase: gerrit-1 node migration
==

13. Mark gerrit-1 as unhealthy, so it won't receive any traffic. Log into gerrit-1 and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin remove healthcheck`
14. Stop gerrit-1
15. Take note of the time the node has been stopped (we will refer it as `migration-start-time-gerrit-1`)
It will be needed in case of rollback (see the __Rollback strategy__ section below).
16. Upgrade plugins, lib and war file on gerrit-1
17. Copy indexes over from gerrit-2 node to gerrit-1. All the `$GERRIT_SITE/index` directory
need to be copied over
18. The HA plugin keeps the last update timestamp for each index in the following files:
`$GERRIT_SITE/data/high-availability/group`
`$GERRIT_SITE/data/high-availability/account`
`$GERRIT_SITE/data/high-availability/change`
The timestamp is stored in this format `yyyy-mm-ddTHH:MM:SS.ss`, i.e.: 2020-12-18T12:17:53.25.
Set it back of to `migration-start-time-gerrit-1`.
19. Restart gerrit-1
20. Run Gatling tests against gerrit-1
21. Compare and assess the results of the tests and decide if going forward with
the migration or rollback
22. Mark node as healthy. Log into gerrit-1 and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin enable healthcheck`

Gerrit slaves migration
==

Once happy with the masters upgrade, it will be possible to migrate the replicas as well.
For each replica these are the steps to follow:
1. Remove replica from pool
2. Stop the replica
3. Upgrade plugins, lib and war file
4. Replicate [the account data](https://gerrit-documentation.storage.googleapis.com/Documentation/2.15/config-accounts.html#replication)
from the All-Users.git repository from master.
5. Restart replica
6. Put back replica in the pool

Consolidation period and cleanup (TBC - at least 24h after the successful migration)
==

Once the release is done the system is stable, the full Gerrit v2.15 features can be enabled
again.

**NOTE** Once the Gerrit v2.15 features are fully enabled, it isn't possible anymore to
migrate back to v2.14. The decision to start this phase must be carefully evaluated and
signed off with the management.

As part of this phase, we enable WIP and private changes removing the following
configuration from all the master nodes:

`[change]
  disablePrivateChanges = true`

Enable calls to WIP [1] for inline patch creation at Load balancer level. The following
calls need to be unblocked:

  `POST <gerrit_url>/changes/
  POST <gerrit_url>/changes/test-project~1/wip`

Rollback strategy
===

The rollback outlined is not meant to cover a disaster recovery case, but only the case of version rollback of a single node:
1. Set node to rollback as unhealthy. Log into the node and run
  `ssh -p 29418 gerritadmin@localhost gerrit plugin remove healthcheck`
2. Stop the node
3. Downgrade plugins, lib and gerrit.war to 2.14.20
4. Restore previous indexes version in `index/gerrit_index.config`:
`[index "accounts_0004"]
  ready = true
[index "changes_0039"]
  ready = true
[index "groups_0002"]
  ready = true`
5. Downgrade schema version `update schema_version set version_nbr = 142;`
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
2. Downgrade plugins, lib and gerrit.war to 2.14.20
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

[1]: [WIP and private workflows](https://www.gerritcodereview.com/2.15.html#new-workflows)

[2]: [Gerrit 2.14 documentation](https://www.gerritcodereview.com/2.14.html)

[3]: [Gerrit 2.15 documentation](https://www.gerritcodereview.com/2.15.html)

[4]: [Plugins artifacts](https://archive-ci.gerritforge.com/)

[5]: [Zero downtime Gerrit](https://www.slideshare.net/lucamilanesio/zerodowntime-gerrit-code-review-upgrades)
