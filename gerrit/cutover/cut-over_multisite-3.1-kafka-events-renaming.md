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

* gerrit-1: the name of the first Gerrit master in the multi site setup
* gerrit-2: the name of the second Gerrit master in the multi site setup
* primary: Gerrit instance currently receiving both read and write traffic
* repplica: Gerrit instance currently receiving read only traffic
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

1. Mark gerrit-2 as unhealthy and wait for the open connections to be drained
2. Stop Gerrit process on gerrit-2
3. Remove the old Kafka broker plugin: `rm $GERRIT_SITE/plugin/kafka-events.jar`
4. Upgrade plugins and libraries:
  - `multi-site` and `events-broker` need to go in the `$GERRIT_SITE/lib` directory
  - `multi-site`, `events-kafka`, `zookeeper-refdb`, `websession-broker` need to go in the `$GERRIT_SITE/plugin` directory
5. Update `$GERRIT_SITE/etc/gerrit.config` configuration, by renaming
`[plugin "kafka-events"]` to `[plugin "events-kafka"]`
6. Restart gerrit-2
7. Mark gerrit-2 as healthy
8. Test the node is working fine with particular attention to:
- projects, changes and groups creation/updates consumption and production
- projects, changes and groups indexing
- websessions synchronization
9. Repeat for gerrit-1 and all the other master instances

Rollback strategy
===

1. Stop gerrit
2. Downgrade plugins, libs
3. Restore previous configuration
4. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* Group reindexing has been fixed in the latest version of the Kafka broker plugin [1]

[1]: https://gerrit-review.googlesource.com/c/plugins/multi-site/+/301208
