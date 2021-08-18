Cut over plan: migration from Gerrit version 3.0.16 to 3.1.15
==

This migration is intended for a single gerrit installation having following
characteristics:

* Runs 3.0.16
* Runs on an EC2 instance in AWS
* All data (git repositories, caches, databases and indexes) is stored on a
  single EBS volume.

Glossary
==

* `gerrit`: the name of the primary Gerrit instance
* `git repositories`: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* `caches`: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* `indexes`: Lucene index files stored in the `$GERRIT_SITE/index` directory
* `gerrit user`: the owner of the process running gerrit
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration plan *will* require downtime. This is due to the fact
that the current installation is not in a highly-available environment since
only one gerrit instance exists.

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

Pre-cutover
==

1. Internet Explorer is officially not supported anymore. Gain some statistics
   on how many users are using IE.

   ```shell
     grep -i '\bwindows\b' <httpd_logs> | perl -pe 's/.*\[HTTP-\d+\] - (\S+).*/$1/' | sort -u
   ```

2. Check for `change.allowDrafts` in `gerrit.config`. If set to `true`, then
   users used to be able to push to `refs/drafts/branch`. This functionality
   will no longer work on 3.1. Users need to be informed that they should push
   WIP changes instead, as such:

    ```shell
    git push origin HEAD:refs/for/<branch>%wip
   ```

3. Check for `receive.allowPushToRefsChanges` in `gerrit.config`. If set to
   true, then users used to be able to push directly
   to `refs/changes/<change number>`.

   This functionality will no longer work on 3.1. Users need to be informed that
   they should push to the refs/for meta ref instead, as such:

    ```shell
    git push origin HEAD:refs/for/<branch>
   ```

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration and observation
==

1. Run a baseline with the Gatling tests
2. Stop gerrit process
3. Trigger EBS backup from AWS and wait for completion.
4. JGit’s configuration options are now read from
   the `$GERRIT_SITE/etc/jgit.config` file rather than the system
   level `.gitconfig`. Copy the content of `<gerrit user home>/.gitconfig`
   into `$GERRIT_SITE/etc/jgit.config`.
5. Upgrade plugins and war file on gerrit:
    - Gerrit 3.1.15 war file can be found in
      the [Gerrit Code Review 3.1 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.1.15.war)
      . This should be downloaded in a temporary directory (i.e. /tmp/). Note
      that this war file contains also all core plugins. For 3.1 these are:

        * codemirror-editor
        * commit-message-length-validator
        * delete-project
        * download-commands
        * gitiles
        * hooks
        * plugin-manager
        * replication
        * reviewnotes
        * singleusergroup
        * webhooks

    - Download additional plugins and libraries in the `$GERRIT_SITE/plugins`.
      The latest stable plugins for 3.1 can be found in
      the [GerritForge Archive CI](https://archive-ci.gerritforge.com/view/Plugins-stable-3.1/)

6. Run init on gerrit

        java -jar <path-to>/gerrit-3.1.15.war init -d $GERRIT_SITE \
        --install-plugin codemirror-editor \
        --install-plugin commit-message-length-validator \
        --install-plugin delete-project \
        --install-plugin download-commands \
        --install-plugin gitiles \
        --install-plugin hooks \
        --install-plugin replication \
        --install-plugin reviewnotes \
        --install-plugin singleusergroup \
        --install-plugin webhooks \
        --batch

   *Note*: that you should remove any core plugin you don't want to install

7. Restart gerrit process
8. Wait for the online reindexing of changes, accounts and groups to finish (
   this step will need to be carefully timed during the staging environment
   migration). You can check the status of the reindex in the `error_log`

* Groups (from version `7` to version `8`)

    ```shell
      $ grep OnlineReindexer logs/error_log | grep v7-v8
      [2021-08-18 15:27:34,691] [Reindex groups v7-v8] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of groups from schema version 7 to 8
      [2021-08-18 15:27:34,913] [Reindex groups v7-v8] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex groups to version 8 complete
      [2021-08-18 15:27:34,913] [Reindex groups v7-v8] INFO  com.google.gerrit.server.index.OnlineReindexer : Using groups schema version 8
    ```

* Accounts (from version `10` to version `11`)

    ```shell
    $ grep OnlineReindexer logs/error_log | grep v10-v11
    [2021-08-18 15:27:34,692] [Reindex accounts v10-v11] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of accounts from schema version 10 to 11
    [2021-08-18 15:27:34,886] [Reindex accounts v10-v11] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex accounts to version 11 complete
    [2021-08-18 15:27:34,887] [Reindex accounts v10-v11] INFO  com.google.gerrit.server.index.OnlineReindexer : Using accounts schema version 11
    ```


* Changes (from version `56` to version `57`)

    ```shell
    $ grep OnlineReindexer logs/error_log | grep v56-v57
    [2021-08-18 15:27:34,691] [Reindex changes v56-v57] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 56 to 57
    [2021-08-18 15:27:34,724] [Reindex changes v56-v57] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 57 complete
    [2021-08-18 15:27:34,724] [Reindex changes v56-v57] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 57
    ```

* Check for the indexing errors:

    ```shell
    $ grep "OnlineReindexer" error_log | egrep -i '(error|failed)'
    ```

* If errors are present something similar will be found in the logs:

    ```shell
    $ grep "OnlineReindexer : Error" logs/error_log
    [2021-08-18 15:18:55,169] [Reindex groups v7-v8] ERROR com.google.gerrit.server.index.OnlineReindexer : Online reindex of groups schema version 8 failed
    ```

* Furthermore, check the following indexes' migration status on
  the `$GERRIT_SITE/index/gerrit_index.config`, where `groups_0008`
  , `projects_0004`, `accounts_0011` and `changes_0057` need to be marked
  as `ready=true`, whilst all previous versions should be marked
  as `ready=false`:

    ```
    [index "accounts_0010"]
      ready = false
    [index "changes_0056"]
      ready = false
    [index "groups_0007"]
      ready = false
    [index "projects_0004"]
      ready = true
    [index "changes_0057"]
      ready = true
    [index "accounts_0011"]
      ready = true
    [index "groups_0008"]
      ready = true
    ```

9. Run Gatling tests against gerrit
10. Compare and assess the results against the result of the tests executed at
    point 1., and decide whether considering the migration successful or
    rollback.

Rollback strategy
===

1. Stop gerrit
2. Downgrade plugins, libs and gerrit.war to 3.0.16
3. Remove `$GERRIT_SITE/etc/jgit.config`
4. Restore previous indexes version in `$GERRIT_SITE/index/gerrit_index.config`:

    ```
    [index "accounts_0010"]
    ready = true
    [index "changes_0056"]
    ready = true
    [index "groups_0007"]
    ready = true
    [index "projects_0004"]
    ready = true
    ```

5. Run init on gerrit

        java -jar <path-to>/gerrit-3.0.16.war init -d $GERRIT_SITE \
        --install-plugin codemirror-editor \
        --install-plugin commit-message-length-validator \
        --install-plugin delete-project \
        --install-plugin download-commands \
        --install-plugin gitiles \
        --install-plugin hooks \
        --install-plugin replication \
        --install-plugin reviewnotes \
        --install-plugin singleusergroup \
        --install-plugin webhooks \
        --batch

6. Restart gerrit

Disaster recovery
===

1. Stop gerrit
2. Downgrade plugins and gerrit.war to 3.0.16
3. Restore previous indexes, caches, git repositories and DB from the initial
   EBS backup. **NOTE** All data created or modified in Gerrit after the initial
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
* Version 3.1 is the first Gerrit release that supports Git protocol V2,
  introducing big optimization in the way client and server communicate during
  clones and fetches. Documentation on how to enable this can be found here [4]

Useful references
==

[1]: [Gerrit 3.0 documentation](https://www.gerritcodereview.com/3.0.html)

[2]: [Gerrit 3.1 documentation](https://www.gerritcodereview.com/3.1.html)

[3]: [Plugins artifacts](https://archive-ci.gerritforge.com/)

[4]: [How to enable Git v2 in Gerrit Code Review](https://gitenterprise.me/2020/05/15/gerrit-goes-git-v2/)