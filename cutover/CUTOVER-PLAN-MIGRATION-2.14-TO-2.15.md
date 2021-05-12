Cut over plan: migration from Gerrit version 2.14.20 to 2.15 latest
==

The described migration plan will allow no downtime. Both Read and Write
operation will be allowed during the migration.

There will only be a short readonly window to allow backing up the git
repositories and ReviewDB.

Once the cutover actions will be reviewed and agreed, all the operational side
of the cutover should be automated to reduce possible human mistakes.

Prerequisites
==
1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels
3. Put both primary and secondary gerrit in Read only mode
4. Take a snapshot Git repos, review DB, caches indexes

Migration and testing
==
0. Ensure primary and secondary gerrit are still in RO.
1. Upgrade plugins, lib and war file on the secondary node
2. Run gerrit init on the secondary node `java -jar gerrit-2.15.22.war init -d <gerrit_dir> --install-all-plugins  --no-auto-start`:
  * When prompted for `Migrate draft changes to private changes (default is work-in-progress)` response `y`
  * When prompted for `Execute the following SQL to drop unused objects:
                        DROP TABLE account_external_ids;
                        DROP TABLE accounts;
                        ALTER TABLE patch_sets DROP COLUMN draft;

                        Execute now [Y/n]?` response `n`
3. Restart secondary node
4. Put back system to RW
5. Wait for the online reindexing to finish (this step will require some time)
  * You will see this in the logs once the reindexing is done:
    `INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 48 complete
     INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 48`
6. Migrate primary node as well
  * Online reindexing time on the first node can be reduced by copying the indexes from the secondary node and run a delta reindex of the missing changes

Rollback strategy
==

Before starting any operation all the data will be backed up (git repositories, Postgres, indexes) to allow recovery in case of failure.

The rollback will consists in:
1. Put both primary and secondary gerrit in Read only mode
2. Downgrade plugins, lib and gerrit.war to 2.14.20
3. Restore previously backed up indexes, caches, git and DB.
4. Restart the services

Notes
==
* All the operations need to be performed in a staging environment first to anticipate possible issues happening in production
* All the operations need to be timed to have an idea on how long the whole process will take
* In case resource consumption or time taken for the online reindex would take too long it would be possible to:
  * align staging data with production
  * run the reindex in staging
  * copy the staging index over to production and only run a delta reindex in production to reduce time and resources usage
* We recommend to avoid upgrading to 2.14.22, and directly upgrading to 2.15.22

Useful references
==

[1]: [WIP and private workflows](https://www.gerritcodereview.com/2.15.html#new-workflows)

[2]: [Gerrit 2.14 documentation](https://www.gerritcodereview.com/2.14.html)

[3]: [Gerrit 2.15 documentation](https://www.gerritcodereview.com/2.15.html)

[4]: [Plugins artifacts](https://archive-ci.gerritforge.com/)

[5]: [Zero downtime Gerrit](https://www.slideshare.net/lucamilanesio/zerodowntime-gerrit-code-review-upgrades)
