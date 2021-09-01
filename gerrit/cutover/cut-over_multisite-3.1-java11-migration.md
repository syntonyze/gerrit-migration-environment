Cut over plan: multi site Java 11 migration - Gerrit 3.1
==

This migration is intended for a multi-site Gerrit installation having following
characteristics:

* Runs Gerrit 3.1.7 in a multi-site setup
* Uses java 8
* 6 Gerrit primary, 4 ASG replicas  

Glossary
==

* gerrit-X: the name of Gerrit primary number X in the multi site setup
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

1. Make sure Java 11 is installed on all the target Docker images

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration
==

1. Mark gerrit-1 as unhealthy and wait for the open connections to be drained (`ssh -p 29418 admin@localhost gerrit show-queue -q -w`):
`mv $GERRIT_SITE/plugins/healthcheck.jar $GERRIT_SITE/plugins/healthcheck.jar.disabled`
2. Stop Gerrit process on gerrit-1
3. Update `$GERRIT_SITE/etc/gerrit.config` configuration, add to the `container` section the following:

```
javaOptions = "-verbose:gc -Xlog:gc*::time -Xloggc:$GERRIT_SITE/logs/jvm_gc_log"
javaHome = "<java11_home_directory>"
```
4. Restart gerrit-1
5. Mark gerrit-1 as healthy:
`mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`
6. Test the node is working fine. XXX: Any particular metric to look at ??
7. Repeat for half of the nodes gerrit-2, gerrit-3 and 2 of the ASG replicas

Observation period (1 week?)
===
* Before completing the migration is good practice to leave an observation period, to compare the JVM GC logs of the two Java versions, Java 8 Vs Java 11
* Once the observation period is over, and you are happy with the result the migration of the rest of the nodes can be completed (gerrit-4, gerrit-5, gerrit-6 and the rest of the ASG replicas)
* Keep the migrated node under observation as you did for the other

Rollback strategy
===

1. Stop gerrit-X
2. Restore previous Gerrit configuration, by adding to the `container` section the following:

```
javaOptions = "-verbose:gc -XX:+PrintGCDateStamps -Xloggc:$GERRIT_SITE/logs/jvm_gc_log"
javaHome = "<java8_home_directory>"
```
3. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* Useful tool to compare JVM GC logs [1]

[1]: https://gceasy.io/
