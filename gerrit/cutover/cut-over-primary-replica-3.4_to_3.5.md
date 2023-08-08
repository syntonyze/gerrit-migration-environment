Cut over plan: migration from Gerrit version 3.4.5 to 3.5.6
==

This migration is intended for a primary/replica Gerrit.

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

The described cutover plan will migrate one node at a time to avoid any downtime.

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

* Java >= 11.0.10 is needed. Support for [Java 8 has been dropped](https://www.gerritcodereview.com/3.5.html#support-for-java-8-dropped)

* Repo download scheme has been renamed to [repo](https://www.gerritcodereview.com/3.5.html#breaking-changes)

* Full release notes for 3.5 can be found [here](https://www.gerritcodereview.com/3.5.html)

* Download new plugins and war files:
    - Gerrit 3.5.6 war file can be found in
      the [Gerrit Code Review 3.5 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.5.6.war).
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
 
 * Make sure custom plugins are compatible with the new Gerrit version

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration
==

Gerrit 3.4 and 3.5 can coexist. This cutover plan will first migrate the primary instance and then the replicas.

1. Mark gerrit-1 (primary) as unhealthy and wait for the open connections to be drained (`ssh -p 29418 admin@localhost gerrit show-queue -q -w`)
    * Wheather healthcheck plugin is used mark the node as unhealthy by disabling it:
    `mv $GERRIT_SITE/plugins/healthcheck.jar $GERRIT_SITE/plugins/healthcheck.jar.disabled`
2. Make sure `gerrit.experimentalRollingUpgrade` is set to `true`
3. Stop Gerrit process on gerrit-1
4. Backup git repositories, caches and indexes
5. Upgrade plugins, lib and war file on gerrit-1
6. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.5.6.war init -d $GERRIT_SITE \
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

7. Allow users to login with mixed case usernames without the risk to create duplicate accounts:
```shell
git config -f $GERRIT_SITE/etc/gerrit.config auth.userNameCaseInsensitive false  && \
java -jar $GERRIT_SITE/bin/gerrit.war ChangeExternalIdCaseSensitivity --batch -d $GERRIT_SITE
```

7. Run project reindex offline. Consider increasing memory configuration (`-Xmx<>`) if
the memory allocated is not enough for the reindexing.
See below an example of reindex with 60g of heap:

```shell
  java -jar -Xmx60g <path-to-war-file>/gerrit-3.5.6.war reindex --verbose -d $GERRIT_SITE
```

* Change indexes will be migrated from 61 to 71:

  ```shell
    [index "accounts_0011"]
	    ready = true
    [index "changes_0061"]
	    ready = true
    [index "groups_0008"]
	    ready = true
    [index "projects_0004"]
	    ready = true
  ```
    to:

  ```shell
    [index "accounts_0011"]
	    ready = true
    [index "groups_0008"]
	    ready = true
    [index "changes_0071"]
	    ready = true
    [index "projects_0004"]
	    ready = true
  ```

8. Start Gerrit
9. Test the node is working fine.
10. Mark gerrit-1 as healthy:
    * Wheather healthcheck plugin is used mark the node as unhealthy by enabling it:
    `mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`

Observation period (1 week?)
===

* The primary/replica setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the replica nodes can be completed
* Keep the migrated node under observation as you did for the other


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

5. Reindex Gerrit
    `java -jar gerrit-3.4.5.war reindex -d site_path`  

6. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* The testing has to be done with a staging environment as close as possible
  to the production one in term of specs, data type and amount, traffic
* The upgrade needs to be performed with traffic on the system