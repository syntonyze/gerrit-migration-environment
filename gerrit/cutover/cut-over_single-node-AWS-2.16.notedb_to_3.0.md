Cut over plan: migration from Gerrit version 2.16.27 to 3.0.16
==

This migration is intended for a single gerrit installation having following
characteristics:

* Runs 2.16.27 NoteDb
* Runs on an EC2 instance in AWS
* All data (git repositories, caches, databases and indexes) is stored on a
  single EBS volume.

Glossary
==

* gerrit: the name of the primary Gerrit instance
* git repositories: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* caches: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* indexes: Lucene index files stored in the `$GERRIT_SITE/index` directory
* ReviewDB: Postgres database containing review data
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration plan *will* require downtime. This is due to the fact
that the current installation is not in a highly-available environment since
only one gerrit instance exists.

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration and observation
==

1. Run a baseline with the Gatling tests
2. Stop gerrit process
3. Trigger EBS backup from AWS and wait for completion
4. Upgrade plugins and war file on gerrit:
    - Gerrit 3.0.16 war file can be found in
      the [Gerrit Code Review 3.0 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.0.16.war)
      . This should be downloaded in a temporary directory (i.e. /tmp/). Note
      that this war file contains also all core plugins. For 3.0 these are:

    ```
    codemirror-editor, commit-message-length-validator, delete-project,
    download-commands, gitiles, hooks, plugin-manager, replication, reviewnotes,
    singleusergroup, webhooks
    ```

    - Download additional plugins in the `$GERRIT_SITE/plugins`. The latest
      stable plugins for 3.0 can be found in
      the [GerritForge Archive CI](https://archive-ci.gerritforge.com/view/Plugins-stable-3.0/)
5. Run init on gerrit

   `java -jar <path-to>/gerrit-3.0.16.war init -d $GERRIT_SITE --install-all-plugins --batch`:

6. Wait for the online reindexing of accounts, changes and groups to finish (
   this step will need to be carefully timed during the staging environment
   migration). You can check the status of the reindex in the `error_log`

* Check for the indexing to start

    ```
    $ grep "OnlineReindexer : Starting" logs/error_log
    [2021-08-13 15:34:59,479] [Reindex changes v50-v56] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 50 to 56
    ```

* Check for the indexing to finish:

    ```
    $ grep "OnlineReindexer : Using" logs/error_log
    [2021-08-13 15:35:04,149] [Reindex changes v50-v56] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 56
    ```

* Check for the indexing errors:

    ```
    $ grep "OnlineReindexer : Error" logs/error_log
    ```

* If errors are present something similar will be found in the logs:

    ```
    $ grep "OnlineReindexer : Error" logs/error_log
    [2021-08-13 15:35:04,149] [Reindex changes v50-v56] INFO  com.google.gerrit.server.index.OnlineReindexer : Error activating new changes schema version 56
    ```

* Furthermore, check the following indexes' migration status on
  the `$GERRIT_SITE/index/gerrit_index.config`, where `groups_0007`
  , `projects_0004`, `accounts_0010` and `changes_0056` need to be marked
  as `ready = true`:

    ```
    [index "accounts_0010"]
        ready = true
    [index "changes_0050"]
        ready = false
    [index "groups_0007"]
        ready = true
    [index "projects_0004"]
        ready = true
    [index "changes_0056"]
        ready = true
    ```

9. Run Gatling tests against gerrit
10. Compare and assess the results against the result of the tests executed at
    point 1., and decide whether considering the migration successful or
    rollback.

Rollback strategy
===

1. Stop gerrit
2. Downgrade plugins and gerrit.war to 2.16.27
3. Restore previous indexes version in `$GERRIT_SITE/index/gerrit_index.config`:

    ```
    [index "accounts_0010"]
        ready = true
    [index "changes_0050"]
        ready = true
    [index "groups_0007"]
        ready = true
    [index "projects_0004"]
        ready = true
    ```

4. Restart gerrit

Disaster recovery
===

1. Stop gerrit
2. Downgrade plugins, lib and gerrit.war to 2.16.27
3. Restore previous indexes, caches, git repositories and DB from the initial
   backup. **NOTE** All data created or modified in Gerrit after the initial
   backup would be lost. This path should therefore taken as __last resort__
   after the rollback strategy has failed and no remediation has been
   identified.
4. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* All the operations need to be timed to have an idea on how long the whole
  process will take

Useful references
==

[1]: [Gerrit 2.16 documentation](https://www.gerritcodereview.com/2.16.html)

[2]: [Gerrit 3.0 documentation](https://www.gerritcodereview.com/3.0.html)

[3]: [Plugins artifacts](https://archive-ci.gerritforge.com/)

[4]: [Gerrit 3.0 is here](https://gitenterprise.me/2019/05/20/gerrit-v3-0-is-here/)
