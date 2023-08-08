Cut over plan: migration from Gerrit version 3.4.5 to 3.5.6-46-gbeae5f2021
==

This migration is intended for a single primary and multiple replicas Gerrit.

**NOTE:** the cutover plan is intented for a vanilla Gerrit installation.
More details on how to deal with custom plugins later on.

Glossary
==

* primary: Gerrit instance receiving both read and write traffic
* replica: Gerrit instance receiving only read traffic
* git repositories: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* caches: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* indexes: Lucene index files stored in the `$GERRIT_SITE/index` directory
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described cutover plan will migrate one node at a time to mitigate the service degradation.
The system will be in readonly while the primary instance won't be reachable.

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

*NOTE*: the following instructions describe a migration for Gerrit running in a mutable installation.
When using Docker, immutable images will need to be created, reflecting configuration and
software versions described.

Pre-cutover
==

* Java >= 11.0.10 is needed. Support for [Java 8 has been dropped](https://www.gerritcodereview.com/3.5.html#support-for-java-8-dropped)

* Repo download scheme has been renamed to [repo](https://www.gerritcodereview.com/3.5.html#breaking-changes)

* Full release notes for 3.5 can be found [here](https://www.gerritcodereview.com/3.5.html)

* Download new plugins and war files:
    - Gerrit 3.5.6-46-gbeae5f2021 will be provided by GerritForge.
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

    - Download additional plugins and libraries from the archived [GerritForge CI](https://archive-ci.gerritforge.com/job/)
        * *NOTE: the plugin version archived might not be the latest. Make sure you are running the latest version available by checking the most up to date version of the code. If in doubt, GerritForge can provide help with that.*

 * Make sure custom plugins are compatible with the new Gerrit version:
   * Rebuild them from source against Gerrit 3.5.6-46-gbeae5f2021
   * Run any acceptance tests against the new version of Gerrit and the plugins

Prerequisites before starting the migration
==

1. Run 3.4 "acceptance tests" baseline
 * Define a test plan with acceptance criteria for the migration to be succesfull, including:
   * functional tests results
   * client-side performance
   * server-side performance

*NOTE:* We suggest using [Gatling](https://gatling.io/) to automate tests and compare performance between releases. [Here](https://github.com/GerritForge/gatling-sbt-gerrit-test)
an example of test suite. This suite is just an example and doesn't provide an exhaustive
test coverage.
 * Run a baseline against Gerrit 3.4 and record the results

2. Schedule maintenance window to avoid alarms flooding
3. Announce Gerrit upgrade via the relevant channels

Migration
==

This cutover plan will first migrate the primary instance and then the replicas.

1. Stop Gerrit process on gerrit primary
2. Set `index.paginationType` [pagination type](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#index) to `NONE`
3. Backup git repositories, caches and indexes
4. Upgrade non-core plugins, lib and war file on gerrit primary
5. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.5.6-46-gbeae5f2021.war init -d $GERRIT_SITE \
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

6. Start Gerrit
7. Online reindexing of the changes will automatically starts. Check in the logs for the following lines to make sure reindexing is finished:

  ```shell
$ grep OnlineReindexer logs/error_log | grep v61-v71
      [2021-08-20T14:32:55.858+0200] [Reindex changes v61-v71] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 61 to 71
      [2021-08-20T14:32:56.423+0200] [Reindex changes v61-v71] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 71 complete
      [2021-08-20T14:32:56.424+0200] [Reindex changes v61-v71] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 71

  ```

Once reindexing will be over, the change indexes will be migrated from 61 to 71.
In `$GERRIT_SITE/index/gerrit_index.config` the following will change from:

  ```shell
    [index "changes_0061"]
	    ready = true
  ```
    to:

  ```shell
    [index "changes_0071"]
	    ready = true
  ```

8. Run `copy-approvals`:

```shell
java -jar $GERRIT_SITE/bin/gerrit-3.5.6-46-gbeae5f2021.war copy-approvals -d $GERRIT_SITE
```

Check [gerrit copy-approvals](https://gerrit-documentation.storage.googleapis.com/Documentation/3.5.2/cmd-copy-approvals.html)
to get more information.

9. Run the "acceptance tests" against Gerrit 3.5 and compare the results:
 * If everything is ok, continue with the replicas migration
 * If there are concerns:
  * consider rolling back
  * assess the issues and plan the changes needed before the next migration
  * re-run the migration plan

*NOTE*: when migrating the replicas step #8 (`copy-approval` script) can be skipped

Rollback strategy
===

1. Stop gerrit-X
2. Downgrade plugins, libs and gerrit.war to 3.4.5
3. Stop Gerrit
4. Run init on gerrit

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
        --no-auto-start \
        --batch

5. Restore indexes from the previously taken backup
6. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* The testing has to be done with a staging environment as close as possible
  to the production one in term of specs, data type and amount, traffic
* The upgrade needs to be performed with traffic on the system