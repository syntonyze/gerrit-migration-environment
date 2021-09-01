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

1. Make sure Java 11 is installed on all the target Docker images:
```
sudo yum update
sudo yum -y install java-11-openjdk
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
3. Update `$GERRIT_SITE/etc/gerrit.config` configuration, add to the `container` section the following:

```
javaOptions = "-verbose:gc -Xlog:gc*::time -Xloggc:$GERRIT_SITE/logs/jvm11_gc_log"
javaHome = "<java11_home_directory>"
```
On CentOS Java is usually installed here: `/usr/lib/jvm/`

4. Restart gerrit-1
5. Verify Java 11 is running:
```
> grep jvm error_log
2021-09-01T10:50:36.685+0200] [main] INFO  org.eclipse.jetty.server.Server : jetty-9.4.35.v20201120; built: 2020-11-20T21:17:03.964Z; git: bdc54f03a5e0a7e280fab27f55c3c75ee8da89fb; jvm 11.0.10+9
```
It is also possible checking it in the Javamelody graphs (https://<gerrit-hostoname>/monitoring)
in the "Details" section.

6. Mark gerrit-1 as healthy:
`mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`
7. Test the node is working fine.
8. Repeat for half of the primary nodes (gerrit-2, gerrit-3) and 2 of the ASG replicas

Observation period (1 week?)
===
* Before completing the migration is good practice to leave an observation period, to compare the JVM GC logs of the two Java versions, Java 8 Vs Java 11 (see notes about JVM GC tooling)
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
4. Check Java 8 is running
```
> grep jvm error_log
2021-09-01T10:50:36.685+0200] [main] INFO  org.eclipse.jetty.server.Server : jetty-9.4.35.v20201120; built: 2020-11-20T21:17:03.964Z; git: bdc54f03a5e0a7e280fab27f55c3c75ee8da89fb; jvm 1.8.0_292-b10
```
It is also possible checking it in the Javamelody graphs (https://<gerrit-hostoname>/monitoring)
in the "Details" section.

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* Useful tool to compare JVM GC logs [1]

[1]: https://gceasy.io/
