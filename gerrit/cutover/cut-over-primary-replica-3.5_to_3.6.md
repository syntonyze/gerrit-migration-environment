Cut over plan: migration from Gerrit version 3.5.6 to 3.6.6
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

* The ignore feature is completely removed from Gerrit’s web app;
  the ignore and unignore actions and the associated is:ignored predicate
  are not supported [anymore](https://www.gerritcodereview.com/3.6.html#breaking-changes). Asses automation scripts that might use the predicate.

* Enhance metric name sanitize function to remove collision on ‘_’ between metrics.

  Collision between the sanitized metric names can be easily created e.g. foo_bar will collide with foo+bar. In order to avoid collisions keep the rules about slashes and replace not supported chars with _0x[HEX CODE]_ string. The replacement prefix 0x is prepended with another replacement prefix.

  Make sure you won't be affected by metrics renaming.

* Prolog rules have been [deprecated](https://www.gerritcodereview.com/3.6.html#submit-requirements)

* Project Owners implicit delete reference permission has been [removed](https://www.gerritcodereview.com/3.6.html#breaking-changes). Before this release all Project Owners
had implicit delete permission to all refs unless force-push was blocked for the user.
Admins that are relying on previous behavior or wish to maintain it for their users
can simply add the permission explicitly in All-Projects:
```
        [access "refs/*"]
            delete = Project Owners
```

*NOTE*: If you choose to do so, blocking force-push no longer has any effect on permission to delete refs by means other than git (REST, UI).

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

 * Make sure custom plugins are compatible with the new Gerrit version

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration
==

Gerrit 3.5 and 3.6 can coexist. This cutover plan will first migrate the primary instance and then the replicas.

1. Make sure to have [`httpd.gracefulStopTimeout`](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#http)
   and [`sshd.gracefulStopTimeout`](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#sshd) set.
   A good value is the max expected time to clone a repository.
2. Make sure `gerrit.experimentalRollingUpgrade` is set to `true`
3. Set `index.paginationType` [pagination type](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#index) to `NONE`
3. Stop Gerrit process on gerrit-1
4. Backup git repositories, caches and indexes
5. Upgrade plugins, lib and war file on gerrit-1
6. Run init on Gerrit:

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

7. Run project reindex offline. Consider increasing memory configuration (`-Xmx<>`) if
the memory allocated is not enough for the reindexing.
See below an example of reindex with 60g of heap:

```shell
  java -jar -Xmx60g <path-to-war-file>/gerrit-3.5.6.war reindex --verbose -d $GERRIT_SITE
```

*NOTE*: reindexing can be done online as well to minimize downtime. In case of online reindexing assess the resource impact during the testing stage.

* Change indexes will be migrated from 61 to 71:

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
    to:

  ```shell
    [index "accounts_0011"]
	    ready = true
    [index "groups_0008"]
	    ready = true
    [index "changes_0077"]
	    ready = true
    [index "projects_0004"]
	    ready = true
  ```

8. Start Gerrit
9. Test the node is working fine.

Observation period (1 week?)
===

* The primary/replica setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the replica nodes can be completed
* Keep the migrated node under observation as you did for the other
* Replicas will have to be migrated one by one to minimize the impact on the system.
  Observation period can be eventually adjusted to shorted the complete rollout of the new version.

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

5. Reindex Gerrit
    `java -jar gerrit-3.5.6.war reindex -d site_path`

6. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* The testing has to be done with a staging environment as close as possible
  to the production one in term of specs, data type and amount, traffic
* The upgrade needs to be performed with traffic on the system