Cut over plan: migration from Gerrit version 2.14.20 to 2.15 latest
==

The described migration plan will allow no downtime. Both Read and Write
operation will be allowed during the migration.

There will be a short readonly window to allow backing up the git
repositories and ReviewDB. The window depends on the backup strategy used,
see [prerequisites](./Prerequisites).

Once the cutover actions will be reviewed, agreed tested and measured in staging,
all the operational side of the cutover should be automated to reduce possible
human mistakes.

Pre-cutover (1 week before)
==

* Disable draft changes, WIP, Private and patch-sets and notify a deadline for the people to
publish their drafts. The following configuration change will be needed to block
the drafts to be published on all the master nodes:

`[change]
  allowDrafts = false
  disablePrivateChanges = true`

* Notify all users that didn't created drafts. Run this query to identify users
with open drafts:

`SELECT distinct(email_address) FROM "changes", "account_external_ids"
  WHERE "status" = 'd'
    AND  owner_account_id = account_id
    AND email_address IS NOT NULL;`

Prerequisites
==
1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels
3. Backup git repositories, Review DB, caches and indexes. There are 2 possible ways
of doing it:
3a. Simple with longer Read Only window:
 * Put the system in Read Only (`touch ./etc/gerrit.readonly`)
 * Take a snapshot of Git repos, review DB, caches, indexes
 * Put the system back in Read Write (`rm ./etc/gerrit.readonly`)
 3b. Complex with short Read Only window:
  * ???

Migration and testing
==

First phase: secondary node migration and observation
==

1. Run a baseline with the Gatling tests
2. Mark secondary node as unhealthy, so it won't receive any traffic: `touch ./data/healthcheck/fail`
3. Stop the secondary node
4. Take note of the time the node has been stopped (we will refer it as
  `migration-start-time`). It will be needed in case of [rollback](./Partial failure).
5. Upgrade plugins, lib and war file on the secondary node
6. Run gerrit init on the secondary node `java -jar gerrit-2.15.22.war init -d <gerrit_dir> --no-auto-start`:
  * When prompted for `Migrate draft changes to private changes (default is work-in-progress)` response `y`
  * When prompted for `Execute the following SQL to drop unused objects:
                        DROP TABLE account_external_ids;
                        DROP TABLE accounts;
                        ALTER TABLE patch_sets DROP COLUMN draft;

                        Execute now [Y/n]?` response `n`
7. Restart secondary node
8. Wait for the online reindexing of accounts, changes and groups to finish (this step will require some time)
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
  * Further check is the following, where `groups_0002`, `accounts_0007` and `changes_0048` need to be marked as `ready = true`:
  `> cat index/gerrit_index.config
[index "groups_0002"]
	ready = true
[index "accounts_0007"]
	ready = true
[index "changes_0048"]
	ready = true`
9. Run Gatling tests against the secondary node
10. Compare and assess the results of the tests and decide if going forward with
the migration or rollback
11. Mark node as healthy: `rm ./data/healthcheck/fail`

At this point it is good practice to introduce an observation period where nodes are
running the two versions alongside.

The observation period should be enough to have *real traffic* going through the
system for a number of hours and see the real E2E flow going.

This will allow a [quick rollback](./Partial failure) to Gerrit v2.14 if needed.

Second phase: primary node migration
==

12. Mark primary node as unhealthy, so it won't receive any traffic: `touch ./data/healthcheck/fail`
13. Stop the primary node
14. Take note of the time the node has been stopped (we will refer it as `migration-start-time`)
It will be needed in case of [rollback](./Partial failure).
15. Upgrade plugins, lib and war file on the secondary node
16. Copy indexes over from secondary node to primary. All the `<gerrit_home>/index` directory
need to be copied over
17. The HA plugin keeps the last update timestamp for each index in the following files:
`<gerrit_home>/data/high-availability/group`
`<gerrit_home>/data/high-availability/account`
`<gerrit_home>/data/high-availability/change`
The timestamp is stored in this format `yyyy-mm-ddTHH:MM:SS.ss`, i.e.: 2020-12-18T12:17:53.25.
Set it back of one hour compared to the current value.
18. Restart primary node
16. Run Gatling tests against the primary node
17. Compare and assess the results of the tests and decide if going forward wiht
the migration or rollback
18. Mark node as healthy: `rm ./data/healthcheck/fail`

Observation period (1 week)
==

Once the release is done the system is stable it will be possible to enable WIP
and private changes removing the following configuration from all the master nodes:

`[change]
  allowDrafts = false
  disablePrivateChanges = true`

Rollback strategy
==

Partial failure
===

The rollback outlined is not meant to cover a disaster recovery case, but only the case of version rollback of a single node:
1. Set node to rollback as unhealthy: `touch ./gerrit/data/healthcheck/fail`
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
`<gerrit_home>/data/high-availability/group`
`<gerrit_home>/data/high-availability/account`
`<gerrit_home>/data/high-availability/change`
The timestamp is stored in this format `yyyy-mm-ddTHH:MM:SS.ss`, i.e.: 2020-12-18T12:17:53.25.
Set those timestamp to `migration-start-time - 1h`.
7. Restart the node
8. Set node to rollback as healthy: `rm ./gerrit/data/healthcheck/fail`

Total system failure
===

1. Stop the nodes
2. Downgrade plugins, lib and gerrit.war to 2.14.20
3. Restore previous indexes, caches, git repositories and DB from the initial backup
4. Restart the nodes

Notes
==
* All the operations need to be performed in a staging environment first to anticipate possible issues happening in production
* All the operations need to be timed to have an idea on how long the whole process will take
* In case resource consumption or time taken for the online reindex would take too long it would be possible to:
  * align staging data with production
  * run the reindex in staging
  * copy the staging index over to production and only run a delta reindex in production to reduce time and resources usage
* We recommend to avoid upgrading to 2.14.22, and directly upgrading from 2.14.20 to 2.15.22

Useful references
==

[1]: [WIP and private workflows](https://www.gerritcodereview.com/2.15.html#new-workflows)

[2]: [Gerrit 2.14 documentation](https://www.gerritcodereview.com/2.14.html)

[3]: [Gerrit 2.15 documentation](https://www.gerritcodereview.com/2.15.html)

[4]: [Plugins artifacts](https://archive-ci.gerritforge.com/)

[5]: [Zero downtime Gerrit](https://www.slideshare.net/lucamilanesio/zerodowntime-gerrit-code-review-upgrades)
