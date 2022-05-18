Cut over plan: migration from Java 8 to Java 11 Corretto
==

This migration is intended for a single gerrit installation having the following
characteristics:

* Runs 3.2.14
* Runs on an EC2 instance in AWS on java 8 Corretto
* All data (git repositories, caches, databases and indexes) is stored on a
  single EBS volume.

Glossary
==

* `gerrit`: the name of the primary Gerrit instance
* `git repositories`: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* `caches`: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* `indexes`: Lucene index files stored in the `$GERRIT_SITE/index` directory
* `gerrit user`: the owner of the process running gerrit
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration plan *will* require downtime. This is due to the fact
that the current installation is not in a highly-available environment since
only one gerrit instance exists.

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

Pre-cutover
==

1. Make sure Java 11 is installed on the ec2 instance, as
   described [here](https://docs.aws.amazon.com/en_gb/corretto/latest/corretto-11-ug/amazon-linux-install.html)

```
sudo yum install -y java-11-amazon-corretto
```

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration and observation
==

1. Run a baseline with the Gatling tests
2. Stop gerrit process
3. Trigger EBS backup from AWS and wait for completion.
4. Update `$GERRIT_SITE/etc/gerrit.config` configuration, add to the `container`
   section the following:

```
javaOptions = "-verbose:gc -Xlog:gc*::time -XX:+PrintGCDetails -Xloggc:$GERRIT_SITE/logs/jvm11_gc_log"
javaHome = "/usr/lib/jvm/java-11-amazon-corretto.x86_64"
```

5. Restart gerrit process
6. Verify Java 11 is running:

```
> grep jvm error_log
[2022-05-18T20:26:49.333+0000] [main] INFO  org.eclipse.jetty.server.Server : jetty-9.4.35.v20201120; built: 2020-11-20T21:17:03.964Z; git: bdc54f03a5e0a7e280fab27f55c3c75ee8da89fb; jvm 11.0.15+9-LTS
```

It is also possible checking it in the Javamelody
graphs (`https://<gerrit-hostname>/monitoring`)
in the `Details` section.

7. Run Gatling tests against gerrit
8. Compare and assess the results against the result of the tests executed at
   point 1., and decide whether considering the migration successful or
   rollback.

Observation period (1 week?)
===

* Before completing the migration is good practice leaving an observation
  period, to compare the JVM GC logs of the two Java versions, Java 8 Vs Java
  11 (see notes about JVM GC tooling)

Rollback strategy
===

1. Stop gerrit
2. Remove Java 11 corretto, as
   explained [here](https://docs.aws.amazon.com/en_gb/corretto/latest/corretto-11-ug/amazon-linux-install.html)

```
sudo yum remove -y java-11-amazon-corretto
```

3. Restore previous Gerrit configuration, by adding to the `container` section
   the following:

```
javaOptions = "-verbose:gc -XX:+PrintGCDateStamps -Xloggc:$GERRIT_SITE/logs/jvm_gc_log"
javaHome = "/usr/lib/jvm/java-1.8.0-amazon-corretto.x86_64/jre"
```

3. Restart gerrit
4. Check Java 8 is running

```
> grep jvm error_log
[2022-05-18T20:47:31.713+0000] [main] INFO  org.eclipse.jetty.server.Server : jetty-9.4.35.v20201120; built: 2020-11-20T21:17:03.964Z; git: bdc54f03a5e0a7e280fab27f55c3c75ee8da89fb; jvm 1.8.0_332-b08
```

It is also possible checking it in the Javamelody graphs (https://<
gerrit-hostoname>/monitoring)
in the "Details" section.

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* All the operations need to be timed to have an idea on how long the whole
  process will take

Useful references
==

* Useful tool to compare JVM GC logs [1]

[1]: https://gceasy.io/