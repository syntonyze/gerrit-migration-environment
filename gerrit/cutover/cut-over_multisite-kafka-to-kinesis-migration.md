Cut over plan: multi site Kafka to Kinesis migration
==

This migration is intended for a multi-site Gerrit installation having following
characteristics:

* Runs Gerrit 3.4.1 in a multi-site setup
* Use Kafka as broker

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

1. Gather the name of the Kafka topics:
```
docker run -it confluentinc/cp-kafka /bin/bash -c "\
echo 'bootstrap.servers=<yourbroker>' >> client-ssl.properties; \
echo 'security.protocol=SSL' >> client-ssl.properties;\
kafka-topics --bootstrap-server <yourbroker>' --command-config client-ssl.properties --list"
```

2. Make sure the user running Gerrit has read/write access to the AWS Kinesis stream you will create

3. Create an AWS Kinesis streams for each topic that needs to be forwarded
```
aws kinesis create-stream --shard-count 1 --stream-name <streamName>
```

4. Start the Kafka to Kinesis bridge

4.1 Export the following variables:
```
export BRIDGE_KAFKA_BOOTSTRAPSERVERS="<listOfYourServers>"
export BRIDGE_COMMON_ONLY_FORWARD_LOCAL_MESSAGES=false
```

4.2 Run the brdige in a screen session
```
java -jar ./stream-technologies-bridge-*.jar kafkaToKinesis >> bridge-kafkaToKinesis.log  2>&1
```

4.3 Make sure data is forwarded in the Kinesis streams (check cloudwatch metrcis for the streams)

Migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels
3. Update gerrit.config with the following section:
```
[plugin "events-aws-kinesis"]
    sendAsync = true
    numberOfSubscribers = 6
    pollingIntervalMs = 1000
    applicationName = <sameOneUsedByKafkaBroker>
    initialPosition = trim_horizon
```
3. Mark gerrit-1 as unhealthy and wait for the open connections to be drained (`ssh -p 29418 admin@localhost gerrit show-queue -q -w`):
`mv $GERRIT_SITE/plugins/healthcheck.jar $GERRIT_SITE/plugins/healthcheck.jar.disabled`
4. Stop Gerrit process on gerrit-1
5. Remove events Kafka plugin
```
rm plugins/events-kafka.jar
```
6. Add events AWS Kinesis plugin
7. Start the Kinesis to Kafka bridge

7.1 Export the following variables:
```
export BRIDGE_KAFKA_BOOTSTRAPSERVERS="<listOfYourServers>"
export BRIDGE_COMMON_ONLY_FORWARD_LOCAL_MESSAGES=true

// Add instanceId
```

7.2 Run the brdige in a screen session
```
java -jar ./stream-technologies-bridge-*.jar kinesisToKafka >> bridge-kinesisToKafka.log  2>&1
```

7.3 Make sure data is forwarded in the Kinesis streams (check cloudwatch metrcis for the streams)

8. Verify Kinesis broker is working and publishing data to the stream:
```

```

9. Repeat for half of the nodes

Observation period (1 week?)
===

XXXXXXXX

* Before completing the migration is good practice to leave an observation period, to compare the JVM GC logs of the two Java versions, Java 8 Vs Java 11 (see notes about JVM GC tooling)
* Once the observation period is over, and you are happy with the result the migration of the rest of the nodes can be completed (gerrit-4, gerrit-5, gerrit-6 and the rest of the ASG replicas)
* Keep the migrated node under observation as you did for the other

Rollback strategy
===

XXXXXXXX

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
