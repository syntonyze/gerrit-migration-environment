Cut over plan: migration from Gerrit version 3.3.11 to 3.4.5
==

This migration is intended for a single gerrit installation having the following
characteristics:

* Runs 3.3.11
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

Once the cuto ver actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

Pre-cutover
==

* Gerrit `3.4` removes the `is:mergeable` predicate by default. Computing is:
  mergeable is computationally expensive depending on the number of open changes
  on a branch and on the size of the changes, so it has been removed by default.

  You should check in the logs if any query containing `is:mergeable` is
  executed. If so, set `change.mergeabilityComputationBehavior`
  in `$GERRIT_SITE/gerrit.config`
  to `API_REF_UPDATED_AND_CHANGE_REINDEX` at point 7
  of `Migration and observation`.

* Unresolved comments that were left on older patchsets will now also be shown
  on newer patchsets. Users might find this confusing and should be educated on
  the new expected behaviour.

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration and observation
==

1. Run a baseline with the Gatling tests
2. Stop gerrit process
3. Trigger EBS backup from AWS and wait for completion.
4. Upgrade plugins and war file on gerrit:
    - Gerrit 3.4.5 war file can be found in
      the [Gerrit Code Review 34 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.4.5.war)
      . This should be downloaded in a temporary directory (i.e. /tmp/). Note
      that this war file contains also all core plugins. For 3.4 these are:

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
      The latest stable plugins for 3.4 can be found in
      the [GerritForge CI](https://gerrit-ci.gerritforge.com/view/Plugins-stable-3.4/)

5. Run init on gerrit

        java -jar <path-to>/gerrit-3.4.5.war init -d $GERRIT_SITE \
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

   The output will be similar to the following:

    ```shell
    Initialized $GERRIT_SITE
    ```

   No schema change is required, however the `changes` index version has been
   increased to version `61` (from version `60`), new change search operators
   were added: `mergedafter` and `mergedbefore`.

6. Trigger offline reindex of changes:

   a. Offline reindex. The reindexing will happen *before* the gerrit process is
   started again so this approach will lengthen your outage window, and it
   should be chosen only if the time it takes is acceptable by the business. If
   this step is taking too long, please consider step 7b instead.

    ```shell
    java -jar $GERRIT_SITE/bin/gerrit.war reindex -d $GERRIT_SITE --index changes
    ```
   This might take some time (which should be measured in staging). The output
   of the reindex will be similar to:

    ```shell
    Reindexing changes: project-slices: 100% (x/x), 100% (x/x), done
    Reindexed xxx documents in changes index in x.xs (xx.x/s)
    Index changes in version 61 is ready
    ```

   b. Online reindex. Do not run offline reindex at step 7a, but just head to
   step 8, which will trigger an online reindex.

7. (if relevant) Set `change.mergeabilityComputationBehavior`
   in `$GERRIT_SITE/gerrit.config`
   to `API_REF_UPDATED_AND_CHANGE_REINDEX` (see `Pre-cutover`)

8. Restart gerrit process

9. This step is only relevant, if you have not executed the offline reindex (
   step 7a). Wait for the online reindexing of changes to finish (
   this step will need to be carefully timed during the staging environment
   migration). You can check the status of the reindex in the `error_log`

    * Changes (from version `60` to version `61`)

        ```shell
         $ grep OnlineReindexer logs/error_log | grep v60-v61
         [Reindex changes v60-v61] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 60 to 61
         [Reindex changes v60-v61] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 61 complete
         [Reindex changes v60-v61] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 61
        ```

10. Check the index configuration contains also the following sections:

    ```shell
    cat $GERRIT_SITE/index/gerrit_index.config
    [index "projects_0004"]
        ready = true
    [index "accounts_0011"]
        ready = true  
    [index "groups_0008"]
        ready = true
    [index "changes_0061"]
       ready = true
    ```

11. Run Gatling tests against gerrit
12. Compare and assess the results against the result of the tests executed at
    point 1., and decide whether considering the migration successful or
    rollback.

Rollback strategy
===

1. Stop gerrit
2. Downgrade plugins, libs and gerrit.war to 3.3.11
3. Restore previous indexes version in `$GERRIT_SITE/index/gerrit_index.config`:

    ```
    [index "accounts_0011"]
    ready = true
    [index "changes_0060"]
    ready = true
    [index "groups_0008"]
    ready = true
    [index "projects_0004"]
    ready = true
    ```

4. Run init on gerrit

        java -jar <path-to>/gerrit-3.3.11.war init -d $GERRIT_SITE \
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

5. (Optional) Run reindex. This is needed only if new changes, accounts or
   groups have been created between the rollout and the rollback.

    ```shell
    java -jar $GERRIT_SITE/bin/gerrit.war reindex
    ```

   1. Remove `change.mergeabilityComputationBehavior`
      from `$GERRIT_SITE/gerrit.config` (if relevant)
6. Restart gerrit

Disaster recovery
===

1. Stop gerrit
2. Downgrade plugins and gerrit.war to 3.3.11
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

Useful references
==

[1]: [Gerrit 3.4 documentation](https://www.gerritcodereview.com/3.4.html)

[2]: [Gerrit 3.3 documentation](https://www.gerritcodereview.com/3.3.html)

[3]: [Plugins artifacts](https://gerrit-ci.gerritforge.com/)