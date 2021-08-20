Cut over plan: migration from Gerrit version 3.1.15 to 3.2.11
==

This migration is intended for a single gerrit installation having following
characteristics:

* Runs 3.1.15
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

* ListGroups: the `–query2` option in the groups query REST-API has been renamed
  to `–query`. Check in the `httpd_log` for any possible client making such
  requests to the `/groups/` endpoint.
  [Documentation](https://gerrit-documentation.storage.googleapis.com/Documentation/3.2.11/rest-api-groups.html#query-groups)

* For performance reasons, gerrit metrics associated with H2 disk-statistics are
  now disabled by default. If you rely on those metrics, you must explicitly
  enabled them again by setting
  `cache.enableDiskStatMetrics` in `gerrit.config`.

* The number of comments per change are limited to `5000`, and their size
  to `16k`. The limits can be customized in `gerrit.config` using
  the `change.maxComments` and
  `change.commentSizeLimit` settings.

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
    - Gerrit 3.1.15 war file can be found in
      the [Gerrit Code Review 3.2 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.2.11.war)
      . This should be downloaded in a temporary directory (i.e. /tmp/). Note
      that this war file contains also all core plugins. For 3.2 these are:

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
      The latest stable plugins for 3.2 can be found in
      the [GerritForge CI](https://gerrit-ci.gerritforge.com/view/Plugins-stable-3.2/)

6. Run init on gerrit

        java -jar <path-to>/gerrit-3.2.11.war init -d $GERRIT_SITE \
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
    Migrating data to schema 182 ...
    Found a total of xxx zombie draft refs in All-Users repo.
    Cleanup percentage = xxx
    Number of zombie refs to be cleaned = xxx
    Migrating data to schema 183 ...
    ```

   This output shows two things of interest:
    * The schema upgrade from `181` to `183`.
    * The cleanup of draft comments. The deletion of draft comment refs was
      broken until `2.16.14`, resulting in draft comment refs not getting
      deleted properly. Although it has been fixed, it’s still possible that
      zombie refs exist from previous versions.

7. Trigger offline reindex of changes:

   a. Offline reindex. The reindexing will happen *before* the gerrit process is
   started again so this approach will lengthen your outage window, and it
   should be chosen only if the time it takes is acceptable by the business. If
   this step is taking to long, please consider step 7b instead.

    ```shell
    java -jar $GERRIT_SITE/bin/gerrit.war reindex -d $GERRIT_SITE --index changes
    ```
   This might take some time (which should be measured in staging). The output
   of the reindex will be similar to:

    ```shell
    Reindexing changes: project-slices: 100% (x/x), 100% (x/x), done
    Reindexed xxx documents in changes index in x.xs (xx.x/s)
    Index changes in version 60 is ready
    ```

   b. Online reindex. Do not run offline reindex at step 7a, but just head to
   step 8, which will trigger an online reindex.

8. Restart gerrit process

9. This step is only relevant, if you have not executed the offline reindex (
   step 7a). Wait for the online reindexing of changes to finish (
   this step will need to be carefully timed during the staging environment
   migration). You can check the status of the reindex in the `error_log`

    * Changes (from version `57` to version `60`)

        ```shell
         $ grep OnlineReindexer logs/error_log | grep v57-v60
         [2021-08-20T14:32:55.858+0200] [Reindex changes v57-v60] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 57 to 60
         [2021-08-20T14:32:56.423+0200] [Reindex changes v57-v60] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 60 complete
         [2021-08-20T14:32:56.424+0200] [Reindex changes v57-v60] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 60
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
    [index "changes_0060"]
       ready = true
    ```

10. Run Gatling tests against gerrit
11. Compare and assess the results against the result of the tests executed at
    point 1., and decide whether considering the migration successful or
    rollback.

Rollback strategy
===

1. Stop gerrit
2. Downgrade plugins, libs and gerrit.war to 3.1.15
3. Restore previous indexes version in `$GERRIT_SITE/index/gerrit_index.config`:

    ```
    [index "accounts_0011"]
    ready = true
    [index "changes_0057"]
    ready = true
    [index "groups_0008"]
    ready = true
    [index "projects_0004"]
    ready = true
    ```

4. Downgrade the schema version from 183 to 181.

    ```shell
      cd $GERRIT_SITE/git/All-Projects.git
      git show refs/meta/version # should return 183
      git update-ref refs/meta/version $(echo -n '181' | git hash-object --stdin)
    ```

5. Run init on gerrit

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

6. (Optional) Run reindex. This is needed only if new changes, accounts or
   groups have been created between the rollout and the rollback.

    ```shell
    java -jar $GERRIT_SITE/bin/gerrit.war reindex
    ```

6. Restart gerrit

*Note*: It is possible that the gerrit UI might return some error, in case the
customers' browsers cached some client side requests done on 3.2. In this case
simply clear the browsers cache.

If this is the case, the error_log might show something like:

```shell
[2021-08-18 17:32:50,769] [HTTP GET /changes/test~1021/detail?O=d16314 (admin from [0:0:0:0:0:0:0:1])] ERROR com.google.gerrit.httpd.restapi.RestApiServlet : Error in GET /changes/tony-test~1021/detail?O=d16314
java.lang.IllegalArgumentException: unknown com.google.gerrit.extensions.client.ListChangesOption: 800000
```

Disaster recovery
===

1. Stop gerrit
2. Downgrade plugins and gerrit.war to 3.1.15
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

[1]: [Gerrit 3.1 documentation](https://www.gerritcodereview.com/3.1.html)

[2]: [Gerrit 3.2 documentation](https://www.gerritcodereview.com/3.2.html)

[3]: [Plugins artifacts](https://gerrit-ci.gerritforge.com/)