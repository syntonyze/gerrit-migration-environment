Cut over plan: multi site events Kafka broker library renaming
==

This migration is intended for a multi-site Gerrit installation having following
characteristics:

* Runs Gerrit 3.1.7 in a multi-site setup
* Have the following plugin and library versions installed:
** kafka-events: v2.15-31-gd99875cfee
** multi-site: b11026ed7c
** websession-broker: 0223cd27bf
** zookeeper: 43afc92e7a
** events-broker: 3.1.3

Glossary
==

* gerrit-1: the name of the first Gerrit primary in the multi site setup
* gerrit-2: the name of the second Gerrit primary in the multi site setup
* primary: Gerrit instance currently receiving both read and write traffic
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

1. Download the latest versions of the plugins:
  - events-kafka: https://archive-ci.gerritforge.com/job/plugin-events-kafka-bazel-stable-3.1/lastSuccessfulBuild/artifact/bazel-bin/plugins/events-kafka/events-kafka.jar
  - zookeeper-refdb: https://archive-ci.gerritforge.com/job/plugin-zookeeper-refdb-bazel-stable-3.1/lastSuccessfulBuild/artifact/bazel-bin/plugins/zookeeper-refdb/zookeeper-refdb.jar
  - websession-broker: https://archive-ci.gerritforge.com/job/plugin-websession-broker-bazel-stable-3.1/lastSuccessfulBuild/artifact/bazel-bin/plugins/websession-broker/websession-broker.jar
  - multi-site: https://archive-ci.gerritforge.com/job/plugin-multi-site-bazel-stable-3.1/lastSuccessfulBuild/artifact/bazel-bin/plugins/multi-site/multi-site/.jar
  - events-broker: https://repo1.maven.org/maven2/com/gerritforge/events-broker/3.1.11/events-broker-3.1.11.jar

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration and observation
==

1. Mark gerrit-2 as unhealthy and wait for the open connections to be drained (`ssh -p 29418 admin@localhost gerrit show-queue -q -w`):
`mv $GERRIT_SITE/plugins/healthcheck.jar $GERRIT_SITE/plugins/healthcheck.jar.disabled`
2. Stop Gerrit process on gerrit-2
3. Remove the old Kafka broker plugin: `rm $GERRIT_SITE/plugins/kafka-events.jar`
4. Upgrade plugins and libraries:
  - `multi-site` and `events-broker` need to go in the `$GERRIT_SITE/lib` directory
  - `multi-site`, `events-kafka`, `zookeeper-refdb`, `websession-broker` need to go in the `$GERRIT_SITE/plugins` directory
5. Update `$GERRIT_SITE/etc/gerrit.config` configuration, by renaming
`[plugin "kafka-events"]` to `[plugin "events-kafka"]`
6. Update `$GERRIT_SITE/etc/gerrit.config` mandatory plugin section:

```
[plugins]
        mandatory = replication
        mandatory = zookeeper-refdb
        mandatory = events-kafka
        mandatory = multi-site
```

7. Rename `$GERRIT_SITE/etc/zookeeper.config` to `$GERRIT_SITE/etc/zookeeper-refdb.config`
8. Restart gerrit-2
9. Mark gerrit-2 as healthy:
`mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`
10. Test the node is working fine with particular attention to:
- projects, changes and groups events creations/updates consumption and production:
 -- check Prometheus metrics
 -- check `$GERRIT_SITE/logs/message_log`
- projects, changes and groups indexing
 -- check Prometheus metrics
 -- check `$GERRIT_SITE/logs/error_log`, with particular attention to `ForwardedIndex`:
  `grep "ForwardedIndex" | $GERRIT_SITE/logs/error_log`
- websessions synchronization:
 -- check `$GERRIT_SITE/logs/websession_log`
11. Repeat for gerrit-1 and all the other primary instances

Rollback strategy
===

1. Stop gerrit-X
2. Downgrade plugins and libs
3. Restore previous configuration , by renaming
`[plugin "events-kafka"]` to `[plugin "kafka-events"]`
4. Restore `$GERRIT_SITE/etc/gerrit.config` mandatory plugin section:

```
[plugins]
        mandatory = replication
        mandatory = zookeeper
        mandatory = kafka-events
        mandatory = multi-site
```
5. Rename `$GERRIT_SITE/etc/zookeeper-refdb.config` to `$GERRIT_SITE/etc/zookeeper.config`
6. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* Group reindexing has been fixed in the latest version of the multisite plugin [1]

[1]: https://gerrit-review.googlesource.com/c/plugins/multi-site/+/301208
