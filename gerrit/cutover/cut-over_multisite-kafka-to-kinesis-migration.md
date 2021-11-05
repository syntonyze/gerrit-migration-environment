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
export BRIDGE_COMMON_INSTANCEID=<GerritInstanceID>
```

7.2 Run the brdige in a screen session
```
java -jar ./stream-technologies-bridge-*.jar kinesisToKafka >> bridge-kinesisToKafka.log  2>&1
```

7.3 Make sure data is forwarded in the Kinesis streams (check cloudwatch metrcis for the streams)

8. Restart Gerrit-1
9. Verify Kinesis broker is working and publishing data to the Kafka topics
10. Repeat for the rest of the nodes

Observation period (1 day?)
===

* Before moving on

Rollback strategy
===

1. Stop gerrit-X
2. Stop Kafka to Kinesis and Kinesis to Kafka bridges
3. Remove events AWS Kinesis bridge
```
rm plugins/events-aws-kinesis.jar
```
4. Add events events Kafka plugin
5. Restart Gerrit-X