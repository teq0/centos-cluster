#!/usr/bin/env bash

#---------------------------------------------------------------------
# Install script for Centos via Vagrant that will
#   - install Java
#   - install Docker
#   - install a bunch of Confluent docker containers to set up a Kafka environment including
#       - Zookeeper
#       - Kafka
#       - Confluent Schema Registry
#       - Kafka Connect
#       - Confluent Control Center (TODO)
#---------------------------------------------------------------------

#global vars

IP=
NODE_NAME=
DC=
CONSUL_MASTER=
ZK_ID=
ZK_SERVERS=
KAFKA_BROKER_ID=
KAFKA_ZK=
KAFKA_BOOTSTRAP=
UPGRADE=1
IS_DC_PRIMARY=0

# docker repos
# [0] is the internet
# [1] is a repo on the host system
# [2] is CBA artefactory (TODO - get the URLs for the CBA Artifactory repos)

DOCKER_REPO_ID=0

DOCKER_REPO[0]="confluentinc"
DOCKER_REPO[1]="10.0.2.2:5000/confluentinc"
DOCKER_REPO[2]="no idea"

CURRENT_DOCKER_REPO=${DOCKER_REPO[$DOCKER_REPO_ID]}

#CP_VERSION="latest"
CP_VERSION="3.1.1"

DOCKER_ZOOKEEPER_IMAGE=cp-zookeeper

DOCKER_KAFKA_IMAGE=cp-kafka
#not sure when we need to use this
#DOCKER_KAFKA_IMAGE=cp-enterprise-kafka

DOCKER_SCHEMA_REGISTRY_IMAGE=cp-schema-registry

#DOCKER_KAFKA_CONNECT_IMAGE=cp-kafka-connect
# replicator image is connect plus replicator libraries (I think)
DOCKER_KAFKA_CONNECT_IMAGE=cp-enterprise-replicator

#DOCKER_CONTROL_CENTER_IMAGE=cp-control-center
DOCKER_CONTROL_CENTER_IMAGE=cp-enterprise-control-center


# local docker registry not currently working either

echo Current docker repo is $CURRENT_DOCKER_REPO

# parse our arguments, which will be passed from the Vagrant file

while [[ $# -gt 1 ]]
do
key="$1"

#echo $1 "=" $2

case $key in
    -i|--ip)
    IP="$2"
    shift # past argument
    ;;
    -n|--name)
    NODE_NAME="$2"
    shift # past argument
    ;;
    -dc|--datacenter)
    DC="$2"
    shift # past argument
    ;;
    -cm|--consul_master)
    CONSUL_MASTER="$2"
    shift # past argument
    ;;
    -zk_id|--zookeeper_id)
    ZK_ID="$2"
    shift # past argument
    ;;
    -zk_servers|--zookeeper_servers)
    ZK_SERVERS="$2"
    shift # past argument
    ;;
    -kafka_id|--kafka_broker_id)
    KAFKA_BROKER_ID="$2"
    shift # past argument
    ;;
    -kafka_zk|--kafka_zookeeper_env)
    KAFKA_ZK="$2"
    shift # past argument
    ;;
    -kafka_bootstrap|--kafka_bootstrap_servers)
    KAFKA_BOOTSTRAP="$2"
    shift # past argument
    ;;
    -v|--verbose)
    VERBOSE=1
    ;;
    -u|--upgrade)
    UPGRADE=1
    ;;
    --default)
    DEFAULT=YES
    ;;
    *)
            # unknown option
    ;;
esac
shift # past argument or value
done

#TODO: this script is copied from a consul vagrant script, need to update it to install docker etc
# and set up config for zookeeper and kafka

if [ "$CONSUL_MASTER" = "" ]
then
	echo "Configuring $NODE_NAME as a Consul master..."
	CONSUL_MASTER="\"server\": true, \n\"bootstrap\": true"
	IS_DC_PRIMARY=1
else
	echo "Configuring $NODE_NAME as a Consul slave..."
	CONSUL_MASTER="\"start_join\": [\"$CONSUL_MASTER\"]"
fi

echo Installing dependencies...

# install java jre 1.8

# NOTE: Confluent includes Zulu OpenJDK in their images so this isn't entirely necessary unless we start running other Java stuff.
# so not installing it anymore until we need it

#if ! type java >/dev/null 2>&1
#then
#    JAVA_VER=0
#else
#    JAVA_VER=$(java -version 2>&1 | sed 's/java version "\(.*\)\.\(.*\)\..*"/\1\2/; 1q')
#fi
#
#echo "Java version is $JAVA_VER"
#
#if [ $JAVA_VER -lt 18 ]
#then
#    sudo rpm -Uvh /vagrant/vendor/jre-8u102-linux-x64.rpm
#fi

# TODO - one day we'll tie it all together with Mesos
#if [ "$MASTER" = "" ]
#then
    #echo "Installing mesos..."
#    sudo rpm -Uvh /vagrant/vendor/mesos-1.0.1-2.0.93.centos701406.x86_64.rpm
#else
    #echo "Mesos already installed"
#fi

#Install Docker

if ! type docker >/dev/null 2>&1
then
    echo "Installing docker..."
    curl -fsSL https://get.docker.com/ | sh
    sudo chkconfig docker on
    sudo systemctl start docker.service
else
    echo "Docker already installed"
fi

# put our user into the docker group

# using vagrant user for now, probably should pick this up from config
DOCKER_USER=vagrant
DOCKER_GROUP=docker

if id -nG "$DOCKER_USER" | grep -qw "$DOCKER_GROUP"; then
    echo user $DOCKER_USER belongs to group "$DOCKER_GROUP"
else
    echo Adding user $DOCKER_USER to group "$DOCKER_GROUP"
    sudo usermod -aG $DOCKER_GROUP $DOCKER_USER
fi

# a folder for our scripts
if [ ! -d /etc/cba-kafka ]
then
    sudo mkdir /etc/cba-kafka
    sudo chmod a+w /etc/cba-kafka
    echo "/etc/cba-kafka created"
fi


#====================================================================================================================
#
#                                   U T I L I T Y  F U N C T I O N S
#
# some utility functions we will need in various places
#
#====================================================================================================================

sudo cat > /etc/cba-kafka/functions.sh << EOL
function docker_container_exists () {
    local retval=0
    local RUNNING=0

    RUNNING=\$(docker inspect --format="{{ .State.Running }}" \$1 2> /dev/null)

    if [ \$? -eq 1 ]; then
      retval=1
    fi

    return \$retval
}

function docker_container_running () {
    local retval=1
    local RUNNING=0

    RUNNING=\$(docker inspect --format="{{ .State.Running }}" \$1 2> /dev/null)

    if [ \$? -eq 0 ]; then
        if [ "\$RUNNING" == "true" ];
        then
            retval=0
        fi
    fi

    return \$retval
}
EOL


#====================================================================================================================
#
#                                   C O N S U L
#
# TODO - Consul for load balancing
#
#====================================================================================================================

if [ ! -d /etc/consul.d ]
then
sudo mkdir /etc/consul.d
sudo chmod a+w /etc/consul.d
fi

sudo cat > /etc/consul.d/config.json << EOL
{
  "datacenter": "$DC",
  "data_dir": "/var/cache/consul",
  "log_level": "DEBUG",
  "node_name": "$NODE_NAME",
  "bind_addr": "0.0.0.0",
  "advertise_addr": "$IP",
  "client_addr": "$IP",
  "domain": "consul.",
  "recursor": "8.8.8.8",
  "encrypt": "p4T1eTQtKji/Df3VrMMLzg==",
  "ui": true,
  $CONSUL_MASTER
}
EOL

if [ ! -d /opt/consul ]
then
sudo mkdir /opt/consul
sudo chmod a+w /opt/consul
fi

sudo cat > /etc/cba-kafka/consul.sh << EOL
source /etc/cba-kafka/functions.sh

if docker_container_running consul;
then
    echo Stopping old consul container...
    systemctl disable docker-consul.service
    docker stop consul >/dev/null
fi

if docker_container_exists consul;
then
    echo Removing old consul container...
    docker rm consul >/dev/null
fi

docker run -d --name consul \\
    --net=host \\
    -v /etc/consul.d:/consul/config \\
    -v /opt/consul:/consul/data \\
    consul agent

EOL

sudo chmod +x /etc/cba-kafka/consul.sh

# Set up as a service

sudo cat > /etc/systemd/system/docker-consul.service << EOL
[Unit]
Description=Consul container
Requires=docker.service
After=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a consul
ExecStop=/usr/bin/docker stop -t 2 consul

[Install]
WantedBy=default.target
EOL


#====================================================================================================================
#
#                                   C O N F L U E N T   P L A T F O R M
#
#====================================================================================================================


#TODO - implement an upgrade flag in these scripts so we can selectively upgrade instead of removing and recreating all the containers every time
#NOTE - these have been implemented as a bunch of different script files so they can be run individually for debugging etc


#====================================================================================================================
#
#                                   Z O O K E E P E R
#
#====================================================================================================================

if [ ! -d /opt/zk_data ]
then
    sudo mkdir /opt/zk_data
    sudo chmod a+w /opt/zk_data
    echo "/opt/zk_data created"
else
    echo "/opt/zk_data exists"
fi

if [ ! -d /opt/zk_logs ]
then
    sudo mkdir /opt/zk_logs
    sudo chmod a+w /opt/zk_logs
    echo "/opt/zk_logs created"
else
    echo "/opt/zk_logs exists"
fi

sudo cat > /etc/cba-kafka/zk.sh << EOL
source /etc/cba-kafka/functions.sh

if docker_container_running zk;
then
    echo Stopping old zk container...
    systemctl disable docker-zk.service
    docker stop zk >/dev/null
fi

if docker_container_exists zk;
then
    echo Removing old zk container...
    docker rm zk >/dev/null
fi

docker run -d \
    --name zk \
    -e ZOOKEEPER_SERVER_ID=$ZK_ID \\
    -e ZOOKEEPER_SERVERS="$ZK_SERVERS" \\
    -e ZOOKEEPER_CLIENT_PORT=2181 \\
    -e ZOOKEEPER_TICK_TIME=2000 \\
    -e ZOOKEEPER_INIT_LIMIT=5 \\
    -e ZOOKEEPER_SYNC_LIMIT=2 \\
    -P \\
    --net=host \\
    -v /opt/zk_data:/var/lib/zookeeper/data \\
    -v /opt/zk_logs:/var/lib/zookeeper/log \\
     $CURRENT_DOCKER_REPO/$DOCKER_ZOOKEEPER_IMAGE:$CP_VERSION
EOL

sudo chmod +x /etc/cba-kafka/zk.sh

# Set up as a service

sudo cat > /etc/systemd/system/docker-zk.service << EOL
[Unit]
Description=Zookeeper container
Requires=docker.service
After=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a zk
ExecStop=/usr/bin/docker stop -t 2 zk

[Install]
WantedBy=default.target
EOL

#====================================================================================================================
#
#                                   K A F K A
#
#====================================================================================================================

if [ ! -d /opt/kafka_data ]
then
    sudo mkdir /opt/kafka_data
    sudo chmod a+w /opt/kafka_data
    echo "/opt/kafka_data created"
else
    echo "/opt/kafka_data exists"
fi

sudo cat > /etc/cba-kafka/kafka.sh << EOL

source /etc/cba-kafka/functions.sh

if docker_container_running kafka;
then
    echo Stopping old kafka container...
    systemctl disable docker-kafka.service
    docker stop kafka >/dev/null
fi

if docker_container_exists kafka;
then
    echo Removing old kafka container...
    docker rm kafka >/dev/null
fi

docker run -d \\
    --name kafka \\
    -e KAFKA_ZOOKEEPER_CONNECT=$KAFKA_ZK \\
    -e KAFKA_BROKER_ID=$KAFKA_BROKER_ID \\
    -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://$IP:9092 \\
    -P \\
    --net=host \\
    -v /opt/kafka_data:/var/lib/kafka/data \\
    $CURRENT_DOCKER_REPO/$DOCKER_KAFKA_IMAGE:$CP_VERSION

# allow deleting topics
# can't find a way to do this from the docker run line so have to do it after the container is created
# probs don't want to do this in production

docker exec kafka /bin/bash -c  'echo "delete.topic.enable=true" >> /etc/kafka/server.properties'

EOL

sudo chmod +x /etc/cba-kafka/kafka.sh

sudo cat > /etc/systemd/system/docker-kafka.service << EOL
[Unit]
Description=Kafka container
Requires=docker.service
After=docker-zk.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a kafka
ExecStop=/usr/bin/docker stop -t 2 kafka

[Install]
WantedBy=default.target
EOL


#====================================================================================================================
#
#                                   S C H E M A   R E G I S T R Y
#
#
# TODO - use the Schema Registry + nginx + Kerberos version
#
#====================================================================================================================


sudo cat > /etc/cba-kafka/schema-registry.sh << EOL

source /etc/cba-kafka/functions.sh

if docker_container_running schema-registry;
then
    echo Stopping old schema-registry container...
    systemctl disable docker-schema-registry.service
    docker stop schema-registry >/dev/null
fi

if docker_container_exists schema-registry;
then
    echo Removing old schema-registry container...
    docker rm schema-registry >/dev/null
fi

docker run -d \\
  --net=host \\
  --name=schema-registry \\
  -P \\
  -e SCHEMA_REGISTRY_KAFKASTORE_CONNECTION_URL=$IP:2181 \\
  -e SCHEMA_REGISTRY_HOST_NAME=$NODE_NAME \\
  -e SCHEMA_REGISTRY_LISTENERS=http://0.0.0.0:8081 \\
  -e SCHEMA_REGISTRY_DEBUG=true \\
  $CURRENT_DOCKER_REPO/$DOCKER_SCHEMA_REGISTRY_IMAGE:$CP_VERSION

EOL

sudo chmod +x /etc/cba-kafka/schema-registry.sh


sudo cat > /etc/systemd/system/docker-schema-registry.service << EOL
[Unit]
Description=Schema registry container
Requires=docker.service
After=docker-kafka.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a schema-registry
ExecStop=/usr/bin/docker stop -t 2 schema-registry

[Install]
WantedBy=default.target
EOL


#====================================================================================================================
#
#                                   K A F K A   C O N N E C T  /  M D C   R E P L I C A T O R
#
#====================================================================================================================


sudo cat > /etc/cba-kafka/kafka-connect.sh << EOL

source /etc/cba-kafka/functions.sh

if [ ! -d /opt/kafka_connect_data ]
then
    sudo mkdir /opt/kafka_connect_data
    sudo chmod a+w /opt/kafka_connect_data
    echo "/opt/kafka_connect_data created"
else
    echo "/opt/kafka_connect_data exists"
fi


if docker_container_running kafka-connect;
then
    echo Stopping old kafka-connect container...
    systemctl disable docker-kafka-connect.service
    docker stop kafka-connect >/dev/null
fi

if docker_container_exists kafka-connect;
then
    echo Removing old kafka-connect container...
    docker rm kafka-connect >/dev/null
fi

docker run -d \\
  --name=kafka-connect \\
  --net=host \\
  -e CONNECT_PRODUCER_INTERCEPTOR_CLASSES=io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor \\
  -e CONNECT_CONSUMER_INTERCEPTOR_CLASSES=io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor \\
  -e CONNECT_BOOTSTRAP_SERVERS=$KAFKA_BOOTSTRAP \\
  -e CONNECT_REST_PORT=8082 \\
  -e CONNECT_GROUP_ID="cba_connect" \\
  -e CONNECT_CONFIG_STORAGE_TOPIC="cba-connect-config" \\
  -e CONNECT_OFFSET_STORAGE_TOPIC="cba-connect-offsets" \\
  -e CONNECT_STATUS_STORAGE_TOPIC="cba-connect-status" \\
  -e CONNECT_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \\
  -e CONNECT_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \\
  -e CONNECT_INTERNAL_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \\
  -e CONNECT_INTERNAL_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \\
  -e CONNECT_REST_ADVERTISED_HOST_NAME="$NODE_NAME" \\
  -e CONNECT_LOG4J_ROOT_LOGLEVEL=DEBUG \\
  -v /opt/kafka_connect_data:/tmp/quickstart \\
  $CURRENT_DOCKER_REPO/$DOCKER_KAFKA_CONNECT_IMAGE:$CP_VERSION

EOL

sudo chmod +x /etc/cba-kafka/kafka-connect.sh


sudo cat > /etc/systemd/system/docker-kafka-connect.service << EOL
[Unit]
Description=Kafka Connect container
Requires=docker.service
After=docker-kafka.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a kafka-connect
ExecStop=/usr/bin/docker stop -t 2 kafka-connect

[Install]
WantedBy=default.target
EOL

#====================================================================================================================
#
#                                   C O N T R O L   C E N T E R
#
#====================================================================================================================

if [ ! -d /tmp/control-center/data ]
then
mkdir -p /tmp/control-center/data
fi

sudo cat > /etc/cba-kafka/control-center.sh << EOL

source /etc/cba-kafka/functions.sh

if docker_container_running control-center;
then
    echo Stopping old control-center container...
    systemctl disable docker-control-center.service
    docker stop control-center >/dev/null
fi

if docker_container_exists control-center;
then
    echo Removing old control-center container...
    docker rm control-center >/dev/null
fi

docker run -d \\
  --name=control-center \\
  --net=host \\
  --ulimit nofile=16384:16384 \\
  -p 9021:9021 \\
  -v /tmp/control-center/data:/var/lib/confluent-control-center \\
  -e CONTROL_CENTER_ZOOKEEPER_CONNECT=$KAFKA_ZK \\
  -e CONTROL_CENTER_BOOTSTRAP_SERVERS=$KAFKA_BOOTSTRAP \\
  -e CONTROL_CENTER_REPLICATION_FACTOR=3 \\
  -e CONTROL_CENTER_MONITORING_INTERCEPTOR_TOPIC_PARTITIONS=1 \\
  -e CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS=1 \\
  -e CONTROL_CENTER_STREAMS_NUM_STREAM_THREADS=2 \\
  -e CONTROL_CENTER_CONNECT_CLUSTER=http://$IP:28082 \\
  $CURRENT_DOCKER_REPO/$DOCKER_CONTROL_CENTER_IMAGE:$CP_VERSION

EOL

sudo chmod +x /etc/cba-kafka/control-center.sh

sudo cat > /etc/systemd/system/docker-control-center.service << EOL
[Unit]
Description=Confluent Control Center container
Requires=docker.service
After=docker-kafka.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a control-center
ExecStop=/usr/bin/docker stop -t 2 control-center

[Install]
WantedBy=default.target
EOL

#====================================================================================================================
#
#                                   R E S T   A P I
#
# TODO
#
#====================================================================================================================

#====================================================================================================================
#
#                                   T O P I C   U I
#
# TODO - https://github.com/Landoop/kafka-topics-ui
#
#====================================================================================================================



#====================================================================================================================
#
#                                   OK, LET'S GO
#
#====================================================================================================================


if [ $UPGRADE = 1 ];
then
    echo Creating consul container
    /etc/cba-kafka/consul.sh
    echo Creating zk container
    /etc/cba-kafka/zk.sh
    sleep 10
    echo Creating kafka container
    /etc/cba-kafka/kafka.sh

    # only install schema registry and control-center on one machine per DC
    if [ $IS_DC_PRIMARY = 1 ];
    then
        sleep 10
        echo Creating schema-registry container
        /etc/cba-kafka/schema-registry.sh
        sleep 10
        echo Creating control-center container
        /etc/cba-kafka/control-center.sh
        sleep 3
    fi

    # create the connect/MDC container in case we need it
    echo Creating kafka-connect container
    /etc/cba-kafka/kafka-connect.sh
fi

# start our containers at boot

echo Enabling auto-start

systemctl enable docker-consul.service
systemctl enable docker-zk.service
systemctl enable docker-kafka.service
if [ $IS_DC_PRIMARY = 1 ];
then
    systemctl enable docker-schema-registry.service
    #control center uses a bit of cpu and causes a bunch of replication etc, so best to only run manually when needed
    #systemctl enable docker-control-center.service
    # unless testing distributed connect best to leave this off
    systemctl enable docker-kafka-connect.service
fi

