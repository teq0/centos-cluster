#!/usr/bin/env bash
[ -z "$CONFLUENT_HOME" ] && echo "Need to set CONFLUENT_HOME" && exit 1;
[ -z "$ZOOKEEPER_CONNECT" ] && echo "Need to set ZOOKEEPER_CONNECT" && exit 1;
[ -z "$KAFKA_BOOTSTRAP_SERVERS" ] && echo "Need to set KAFKA_BOOTSTRAP_SERVERS" && exit 1;

echo "exclude.internal.topics=false" > /tmp/consumer.config

$CONFLUENT_HOME/bin/kafka-console-consumer --consumer.config /tmp/consumer.config \
--formatter "kafka.coordinator.GroupMetadataManager\$OffsetsMessageFormatter" \
--zookeeper $ZOOKEEPER_CONNECT --topic __consumer_offsets --from-beginning
