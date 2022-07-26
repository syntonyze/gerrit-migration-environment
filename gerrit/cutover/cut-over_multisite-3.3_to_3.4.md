Cut over plan: migration from Gerrit version 3.3.11 to 3.4.5
==

This migration is intended for a multi-site Gerrit installation having following
characteristics:

* Runs Gerrit 3.3.11 in a multi-site setup
* 6 Gerrit primary, 4 ASG replicas

Glossary
==

* gerrit-X: the name of Gerrit primary number X in the multi site setup
* primary: Gerrit instance receiving both read and write traffic
* replica: Gerrit instance currently receiving read only traffic
* git repositories: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* caches: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* indexes: Lucene index files stored in the `$GERRIT_SITE/index` directory
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration will migrate one node at a time to avoid any downtime.

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

We suggest to use [Gatling](https://gatling.io/) to compare performance between releases
before the upgrade. [Here](https://github.com/GerritForge/gatling-sbt-gerrit-test)
an example of test suite. This suite is just an example and doesn't provide an exhaustive
test coverage.

*NOTE*: the following instructions describe a migration for Gerrit running in a mutable installation.
When using Docker, immutable images will need to be created, reflecting configuration and
software versions described.

Pre-cutover
==

* Gerrit `3.4` removes the `is:mergeable` predicate by default. The evaluation
  of `is:mergeable` is computationally expensive depending on the number of open
  changes on a branch and on the size of the changes, so it has been removed by
  default.

  You should check in the logs if any query containing `is:mergeable` is
  executed. If so, set `change.mergeabilityComputationBehavior`
  in `$GERRIT_SITE/gerrit.config`
  to `API_REF_UPDATED_AND_CHANGE_REINDEX` at point 7
  of `Migration and observation`.

* Unresolved comments that were left on older patchsets will now also be shown
  on newer patchsets. Users might find this confusing and should be educated on
  the new expected behaviour.

* Download new plugins and war files:
    - Gerrit 3.4.5 war file can be found in
      the [Gerrit Code Review 3.4 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.4.5.war).
      This war file contains also all core plugins:
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

    - Download additional plugins and libraries from [GerritForge CI](https://gerrit-ci.gerritforge.com/job/)

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration
==

1. Mark gerrit-1 as unhealthy and wait for the open connections to be drained (`ssh -p 29418 admin@localhost gerrit show-queue -q -w`):
`mv $GERRIT_SITE/plugins/healthcheck.jar $GERRIT_SITE/plugins/healthcheck.jar.disabled`
2. Stop Gerrit process on gerrit-1
3. Set `gerrit.experimentalRollingUpgrade` to `true` in `gerrit.config`
4. Backup git repositories, caches and indexes
5. Upgrade plugins, lib and war file on gerrit-1
6. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.4.5.war init -d $GERRIT_SITE \
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
```

   *Note*: that you should remove any core plugin you don't want to install

   The output will be similar to the following:

   ```shell
   Initialized $GERRIT_SITE
   ```

 No schema change is required, however the `changes` index version has been
 increased to version `61` (from version `60`), new change search operators
 were added: `mergedafter` and `mergedbefore`.

7. (if relevant) Set `change.mergeabilityComputationBehavior`
  in `$GERRIT_SITE/gerrit.config`
  to `API_REF_UPDATED_AND_CHANGE_REINDEX` (see `Pre-cutover`)
8. Restart gerrit process
9. Wait for the online reindexing of changes to finish (
this step will need to be carefully timed during the staging environment
migration). You can check the status of the reindex in the `error_log`

 * Changes (from version `60` to version `61`)

     ```shell
      $ grep OnlineReindexer logs/error_log | grep v60-v61
      [2022-07-20T14:32:55.858+0200] [Reindex changes v60-v61] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 60 to 61
      [2022-07-20T14:32:56.423+0200] [Reindex changes v60-v61] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 61 complete
      [2022-07-20T14:32:56.424+0200] [Reindex changes v60-v61] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 61
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

11. Mark gerrit-1 as healthy:
 `mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`
12. Test the node is working fine.
13. Repeat for half of the primary nodes (gerrit-2, gerrit-3) and 2 of the ASG replicas

Observation period (1 week?)
===

* The multi-site setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the nodes can be completed (gerrit-4, gerrit-5, gerrit-6 and the rest of the ASG replicas)
* Keep the migrated node under observation as you did for the other

Rollback strategy
===

1. Stop gerrit-X
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

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production

Useful references
==

[1]: [Gerrit 3.4 documentation](https://www.gerritcodereview.com/3.4.html)

[2]: [Gerrit 3.3 documentation](https://www.gerritcodereview.com/3.3.html)

[3]: [Plugins artifacts](https://gerrit-ci.gerritforge.com/)
