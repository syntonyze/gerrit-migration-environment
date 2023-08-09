Cut over plan: migration from Gerrit version 3.5.6 to 3.6.6
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

* The ignore feature is completely removed from Gerrit’s web app;
  the ignore and unignore actions and the associated is:ignored predicate
  are not supported [anymore](https://www.gerritcodereview.com/3.6.html#breaking-changes).
  Asses automation scripts that might use the predicate.

* Enhance metric name sanitize function to remove collision on ‘_’ between metrics.

  Collision between the sanitized metric names can be easily created e.g. foo_bar will collide with foo+bar.
  In order to avoid collisions keep the rules about slashes and replace not supported chars
  with _0x[HEX CODE]_ string. The replacement prefix 0x is prepended with another replacement
  prefix.

  Make sure you won't be affected by metrics renaming.

* Prolog rules have been [deprecated](https://www.gerritcodereview.com/3.6.html#submit-requirements) in favour of [submit requirements](https://gerrit-documentation.storage.googleapis.com/Documentation/3.6.6/config-submit-requirements.html)

* Project Owners implicit delete reference permission has been [removed](https://www.gerritcodereview.com/3.6.html#breaking-changes).
Before this release all Project Owners had implicit delete permission to all refs unless
force-push was blocked for the user.
Admins that are relying on previous behavior or wish to maintain it for their users
can simply add the permission explicitly in All-Projects:
```
        [access "refs/*"]
            delete = Project Owners
```

*NOTE*: If you choose to do so, blocking force-push no longer has any effect on permission to
delete refs by means other than git (REST, UI).

* Support for CentOS is dropped and the base image replaced by AlmaLinux

* Full release notes for 3.6 can be found [here](https://www.gerritcodereview.com/3.6.html)

* Download new plugins and war files:
    - Gerrit 3.6.6 war file can be found in
      the [Gerrit Code Review 3.6 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.6.6.war).
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

    - Download additional plugins and libraries from the [GerritForge CI](https://gerrit-ci.gerritforge.com/view/Plugins-stable-3.6/)

 * Make sure custom plugins are compatible with the new Gerrit version:
   * Rebuild them from source against Gerrit 3.6.6
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
  * Run a baseline against Gerrit 3.5 and record the results

2. Schedule maintenance window to avoid alarms flooding
3. Announce Gerrit upgrade via the relevant channels

Migration
==

This cutover plan will first migrate the primary instance and then the replicas.

1. Stop Gerrit process on gerrit primary
2. Backup git repositories, caches and indexes
3. Upgrade non-core plugins, lib and war file on gerrit primary
4. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.6.6.war init -d $GERRIT_SITE \
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

5. Start Gerrit
6. Online reindexing of the changes will automatically starts. Check in the logs for the following lines to make sure reindexing is finished:

```shell
$ grep OnlineReindexer logs/error_log | grep v71-v77
      [2021-08-20T14:32:55.858+0200] [Reindex changes v71-v77] INFO  com.google.gerrit.server.index.OnlineReindexer : Starting online reindex of changes from schema version 71 to 77
      [2021-08-20T14:32:56.423+0200] [Reindex changes v71-v77] INFO  com.google.gerrit.server.index.OnlineReindexer : Reindex changes to version 77 complete
      [2021-08-20T14:32:56.424+0200] [Reindex changes v71-v77] INFO  com.google.gerrit.server.index.OnlineReindexer : Using changes schema version 77
  ```

Once reindexing will be over, the change indexes will be migrated from 71 to 77.
In `$GERRIT_SITE/index/gerrit_index.config` the following will change from:

  ```shell
    [index "changes_0071"]
	    ready = true
  ```
    to:

  ```shell
    [index "changes_0071"]
	    ready = false
    [index "changes_0077"]
	    ready = true
  ```

7. Run the "acceptance tests" against Gerrit 3.6 and compare the results:
 * If everything is ok, continue with the replicas migration
 * If there are concerns:
  * consider rolling back
  * assess the issues and plan the changes needed before the next migration
  * re-run the migration plan

*NOTE:* migration of the replicas will be the same, but there will be no reindexing
since replicas don't have changes index.

Rollback strategy
===

1. Stop gerrit-X
2. Downgrade plugins, libs and gerrit.war to 3.5.6
3. Stop Gerrit
4. Run init on gerrit

        java -jar <path-to>/gerrit-3.5.6.war init -d $GERRIT_SITE \
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

5. Restore indexes and cahcne from the previously taken backup
6. Restart Gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* The testing has to be done with a staging environment as close as possible
  to the production one in term of specs, data type and amount, traffic
* The upgrade needs to be performed with traffic on the system