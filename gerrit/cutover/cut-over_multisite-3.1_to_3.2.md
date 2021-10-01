Cut over plan: migration from Gerrit version 3.1.7 to 3.2.13
==

This migration is intended for a multi-site Gerrit installation having following
characteristics:

* Runs Gerrit 3.1.7 in a multi-site setup
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

Pre-cutover
==

* ListGroups: the `–query2` option in the groups query REST-API has been renamed
  to `–query`. Check in the `httpd_log` for any possible client making such
  requests to the `/groups/` endpoint and inform them of this change.
  [Documentation](https://gerrit-documentation.storage.googleapis.com/Documentation/3.2.12/rest-api-groups.html#query-groups)

* For performance reasons, Gerrit metrics associated with H2 disk-statistics are
  now disabled by default. If you rely on those metrics, you must explicitly
  enabled them again by setting
  `cache.enableDiskStatMetrics` in `gerrit.config`.

* Download new plugins and war files:
    - Gerrit 3.2.13 war file can be found in
      the [Gerrit Code Review 3.2 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.2.13.war).
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

    - Download additional plugins and libraries from [GerritForge CI](https://gerrit-ci.gerritforge.com/view/Plugins-stable-3.2/)

 * A known issue on 3.2 causes a degradation in the [Account caching](https://bugs.chromium.org/p/gerrit/issues/detail?id=14945).
 This will require a more aggressive GC of the `All-Users` repository (at least once an hour).

The `All-Users.git/config` file will need to be updated with the following parameters:
```
[gc]
  prunepackexpire=61.minutes.ago
  pruneexpire=61.minutes.ago
```

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration
==

1. Mark gerrit-1 as unhealthy and wait for the open connections to be drained (`ssh -p 29418 admin@localhost gerrit show-queue -q -w`):
`mv $GERRIT_SITE/plugins/healthcheck.jar $GERRIT_SITE/plugins/healthcheck.jar.disabled`
2. Stop Gerrit process on gerrit-1
3. Backup git repositories, caches and indexes
4. Upgrade plugins, lib and war file on gerrit-1
5. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.2.12.war init -d $GERRIT_SITE \
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

6. Restart gerrit process
7. Wait for the online reindexing of changes to finish (
this step will need to be carefully timed during the staging environment
migration). You can check the status of the reindex in the `error_log`

 * Changes (from version `57` to version `60`)

     ```shell
      $ grep OnlineReindexer logs/error_log | grep v57-v60
      [2021-08-20T14:32:55.858+0200] [Reindex changes v57-v60] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 57 to 60
      [2021-08-20T14:32:56.423+0200] [Reindex changes v57-v60] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 60 complete
      [2021-08-20T14:32:56.424+0200] [Reindex changes v57-v60] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 60
     ```

8. Check the index configuration contains also the following sections:

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

9. Mark gerrit-1 as healthy:
 `mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`
10. Test the node is working fine.
11. Repeat for half of the primary nodes (gerrit-2, gerrit-3) and 2 of the ASG replicas

Observation period (1 week?)
===

* The multi-site setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the nodes can be completed (gerrit-4, gerrit-5, gerrit-6 and the rest of the ASG replicas)
* Keep the migrated node under observation as you did for the other

Rollback strategy
===

1. Stop gerrit-X
2. Downgrade plugins, libs and gerrit.war to 3.1.7
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
      echo "*** Current schema version is: "
      git show refs/meta/version # should return 183
      git update-ref refs/meta/version $(echo -n '181' | git hash-object --stdin)
      echo "*** Downgraded schema version is: "
      git show refs/meta/version # should return 181
    ```

5. Run init on gerrit

        java -jar <path-to>/gerrit-3.1.7.war init -d $GERRIT_SITE \
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

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
