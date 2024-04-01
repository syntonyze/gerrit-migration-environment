Cut over plan: migration from Gerrit version 3.2.14 to 3.3.11
==

This migration is intended for a multi-site Gerrit installation having following
characteristics:

* Runs Gerrit 3.2.14 in a multi-site setup
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

* Gerrit 3.3 introduces
  the [Attention Set feature](https://gerrit-documentation.storage.googleapis.com/Documentation/3.3.11/user-attention-set.html)
  . This might change the habitual workflow that gerrit users are familiar with.
  Before this migration happens, users should be given the possibility of
  reading the documentation, asking questions and possibly familiarizing with
  the attention-set in a dedicated environment.

* Gerrit 3.3 introduces a new log timestamp format, which supports both ISO-8601
  and RFC3339. You might be affected if you have any scripts that is parsing the
  timestamp logs with a static format. Check if such scripts/queries exist and
  amend them to parse the new format.

* Download new plugins and war files:
    - Gerrit 3.3.11 war file can be found in
      the [Gerrit Code Review 3.3 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.3.11.war).
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

    - Download additional plugins and libraries from [Archive GerritForge CI](https://archive-ci.gerritforge.com/job/)

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
  java -jar <path-to-war-file>/gerrit-3.3.11.war init -d $GERRIT_SITE \
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
   Auto-configured "receive.autogc = false" to disable auto-gc after
   git-receive-pack. Auto-configured "protocol.version = 2" to activate git wire
   protocol version 2. Migrating data to schema 184 ...
   ```

This output shows three things of interest:

* The schema upgrade from `183` to `184` (this renames the `Non-Interactive`
 Users group to `Service Users`).

* Disable `receive.autogc` option in `$GERRIT_SITE/etc/jgit.config` (so that no
 gc is executed after receiving data from git-push and updating refs).

* enable git `protocol version 2`, so that gerrit sites benefit from improved
 fetch performance (when enabled by the clients too).

7. Restart gerrit process (*NOTE*: no reindexing is needed for this upgrade)
8. Mark gerrit-1 as healthy:
 `mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`
9. Test the node is working fine.
10. Repeat for half of the primary nodes (gerrit-2, gerrit-3) and 2 of the ASG replicas

Observation period (1 week?)
===

* The multi-site setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the nodes can be completed (gerrit-4, gerrit-5, gerrit-6 and the rest of the ASG replicas)
* Keep the migrated node under observation as you did for the other

Rollback strategy
===

1. Stop gerrit-X
2. Downgrade plugins, libs and gerrit.war to 3.2.14
3. Revert renaming of `Non-Interactive` users to `Service Users`.

    ```shell
      cd /tmp
      git clone $GERRIT_SITE/git/All-Users.git
      git fetch origin refs/meta/group-names && git checkout FETCH_HEAD
      git revert <sha1-prior-to-group-renaming>
      git push origin HEAD:refs/meta/group-names
    ```

4. Run init on gerrit

        java -jar <path-to>/gerrit-3.2.14.war init -d $GERRIT_SITE \
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

5. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production