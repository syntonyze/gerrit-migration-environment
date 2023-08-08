Cut over plan: migration from Gerrit version 3.4.5 to 3.5.6-46-gbeae5f2021
==

This migration is intended for a single primary and multiple replicas Gerrit.

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

 * Make sure custom plugins are compatible with the new Gerrit version

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration
==

Gerrit 3.4 and 3.5 can coexist. This cutover plan will first migrate the primary instance and then the replicas.

1. Make sure to have [`httpd.gracefulStopTimeout`](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#http)
   and [`sshd.gracefulStopTimeout`](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#sshd) set.
   A good value is the max expected time to clone a repository.
2. Make sure `gerrit.experimentalRollingUpgrade` is set to `true`
3. Set `index.paginationType` [pagination type](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#index) to `NONE`
4. Stop Gerrit process on gerrit-1
5. Backup git repositories, caches and indexes
6. Upgrade plugins, lib and war file on gerrit-1
7. Run init on Gerrit:

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

8. Make sure `auth.userNameCaseInsensitive` is set to `false`

*NOTE*:
The above configuration is necessary when using LDAP authentication type with
[`ldap.localUsernameToLowerCase`](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#ldap.localUsernameToLowerCase)
set to `false`.

If authentication type is different from LDAP, for example SAML, usernames will need to
be normalized, i.e.: all migrated to lower case.

9. Run project reindex offline. Consider increasing memory configuration (`-Xmx<>`) if
the memory allocated is not enough for the reindexing.

When going OOM you will get this error while running the reindexing:

```
Caused by: java.lang.OutOfMemoryError: GC overhead limit exceeded
```

See below an example of reindex with 60g of heap:

```shell
  java -jar -Xmx60g <path-to-war-file>/gerrit-3.5.6.war reindex --verbose -d $GERRIT_SITE
```

*NOTE*: reindexing can be done online as well to minimize downtime. In case of online reindexing assess the resource impact during the testing stage.

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

10. Start Gerrit
11. Test the node is working fine.
12. Run `copy-approvals`:

```shell
java -jar $GERRIT_SITE/bin/gerrit-3.5.6-46-gbeae5f2021.war copy-approvals -d $GERRIT_SITE
```

Check [gerrit copy-approvals](https://gerrit-documentation.storage.googleapis.com/Documentation/3.5.2/cmd-copy-approvals.html)
to get more information.


Observation period (1 week?)
===

* The primary/replica setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the replica nodes can be completed
  *NOTE*: when migrating the replicas step #12 (`copy-approval` script) can be skipped
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