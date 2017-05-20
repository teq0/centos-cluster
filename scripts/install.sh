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
DC_PRIMARY=127.0.0.1
IS_DC_PRIMARY=0

# Port assignments

ZK_PORT=2181
KAFKA_PORT=9092
SCHEMA_REGISTRY_PORT=8081
KAFKA_REST_PORT=8082
KAFKA_CONNECT_REST_PORT=8083

SCHEMA_REGISTRY_UI_PORT=9000
KAFKA_TOPIC_UI_PORT=9001

CONTROL_CENTER_PORT=9003
CONTROL_CENTER_CLUSTER_PORT=28082


# docker repos
# [0] is the internet
# [1] is a repo on the host system
# [2] is internal artefactory (TODO - get the URLs for the CBA Artifactory repos)

DOCKER_REPO_ID=0

DOCKER_REPO[0]="confluentinc"
DOCKER_REPO[1]="10.0.2.2:5000/confluentinc"
#DOCKER_REPO[2]="no idea"

CURRENT_DOCKER_REPO=${DOCKER_REPO[$DOCKER_REPO_ID]}

#CP_VERSION="latest"
CP_VERSION="3.2.1"

DOCKER_ZOOKEEPER_IMAGE=cp-zookeeper
DOCKER_KAFKA_IMAGE=cp-enterprise-kafka
DOCKER_SCHEMA_REGISTRY_IMAGE=cp-schema-registry
DOCKER_KAFKA_REST_IMAGE=cp-kafka-rest
# replicator image is connect plus replicator libraries (I think)
DOCKER_KAFKA_CONNECT_IMAGE=cp-enterprise-replicator
DOCKER_CONTROL_CENTER_IMAGE=cp-enterprise-control-center

# a folder for our scripts
if [ ! -d /etc/kafka-env ]
then
    sudo mkdir /etc/kafka-env
    sudo chmod a+w /etc/kafka-env
    echo "/etc/kafka-env created"
fi

#====================================================================================================================
#
#                                   U T I L I T Y  F U N C T I O N S
#
# some utility functions we will need in various places
#
#====================================================================================================================

function isinstalledYum {
  if yum list installed "$@" >/dev/null 2>&1; then
    true
  else
    false
  fi
}

# create_service(name, container_name, after)

function create_service () {

local dependency_name

if [ "$3" == "" ];
then
    dependency_name="docker"
else
    dependency_name="docker-$3"
fi

sudo cat > /etc/systemd/system/docker-$2.service << EOL
[Unit]
Description=$1 container
Requires=docker.service
After=${dependency_name}.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a $2
ExecStop=/usr/bin/docker stop -t 2 $2

[Install]
WantedBy=default.target
EOL

}

sudo cat > /etc/kafka-env/functions.sh << EOL
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

function remove_container() {
    if docker_container_running \$1;
    then
        echo Stopping old \$1 container...
        systemctl disable docker-\$1.service
        docker stop \$1 >/dev/null
    fi

    if docker_container_exists \$1;
    then
        echo Removing old \$1 container...
        docker rm \$1 >/dev/null
    fi
 }

EOL


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
    -prim|--primary_server)
    DC_PRIMARY="$2"
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


if [ "$CONSUL_MASTER" = "" ]
then
	IS_DC_PRIMARY=1
fi


#====================================================================================================================
#
#                                   S Y S T E M
#
#====================================================================================================================

echo Setting system params...

sudo timedatectl set-timezone Australia/Sydney

if [ $IS_DC_PRIMARY = 1 ];
then

    if isinstalledYum krb5-server;
    then
        echo "Kerberos already installed"
    else

        # install KDC server
        echo Installing Kerberos server...

        sudo yum -y install krb5-server krb5-libs

sudo cat > /etc/krb5.conf << EOL
[libdefaults]
    default_realm = KAFKA.ROCKS
    dns_lookup_realm = false
    dns_lookup_kdc = false
    ticket_lifetime = 24h
    forwardable = true
    udp_preference_limit = 1000000
    default_tkt_enctypes = des-cbc-md5 des-cbc-crc des3-cbc-sha1
    default_tgs_enctypes = des-cbc-md5 des-cbc-crc des3-cbc-sha1
    permitted_enctypes = des-cbc-md5 des-cbc-crc des3-cbc-sha1

[realms]
    KAFKA.ROCKS = {
        kdc = kdc.kdc.kafka.rocks:88
        admin_server = kdc.kafka.rocks:749
        default_domain = kafka.rocks
    }

[domain_realm]
    .kafka.rocks = KAFKA.ROCKS
     kafka.rocks = KAFKA.ROCKS

[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log

EOL

sudo cat > /var/kerberos/krb5kdc.conf << EOL

default_realm = KAFKA.ROCKS

[kdcdefaults]
    v4_mode = nopreauth
    kdc_ports = 0

[realms]
    KAFKA.ROCKS = {
        kdc_ports = 88
        admin_keytab = /etc/kadm5.keytab
        database_name = /var/kerberos/krb5kdc/principal
        acl_file = /var/kerberos/krb5kdc/kadm5.acl
        key_stash_file = /var/kerberos/krb5kdc/stash
        max_life = 10h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        master_key_type = des3-hmac-sha1
        supported_enctypes = arcfour-hmac:normal des3-hmac-sha1:normal des-cbc-crc:normal des:normal des:v4 des:norealm des:onlyrealm des:afs3
        default_principal_flags = +preauth
    }

EOL

sudo cat > /var/kerberos/krb5kdc.conf << EOL

*/admin@CW.COM	    *

EOL

    sudo kdb5_util create -r KAFKA.ROCKS -s

    sudo kadmin.local << EOL
addprinc root/admin
addprinc user1
ktadd -k /var/kerberos/krb5kdc/kadm5.keytab kadmin/admin
ktadd -k /var/kerberos/krb5kdc/kadm5.keytab kadmin/changepw
exit
EOL


    systemctl start krb5kdc.service
    systemctl start kadmin.service
    systemctl enable krb5kdc.service
    systemctl enable kadmin.service


    sudo kadmin.local << EOL
kadmin.local:  addprinc -randkey host/kdc.kafka.rocks
kadmin.local:  ktadd host/kdc.kafka.rocks
EOL

    fi

fi

# echo Installing dependencies...

# install java jre 1.8

# NOTE: Confluent includes Zulu OpenJDK in their images so right now installing Java isn't necessary unless we start running other Java stuff.
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


#====================================================================================================================
#
#                                   D O C K E R
#
#====================================================================================================================

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



#====================================================================================================================
#
#                                   C O N S U L
#
# TODO - Consul for load balancing
#
#====================================================================================================================

COMPONENT_NAME="Consul"
CONTAINER_NAME="consul"
DEPENDENCY=""

if [ "$CONSUL_MASTER" = "" ]
then
	echo "Configuring $NODE_NAME as a Consul master..."
	CONSUL_MASTER="\"server\": true, \n\"bootstrap\": true"
	IS_DC_PRIMARY=1
else
	echo "Configuring $NODE_NAME as a Consul slave..."
	CONSUL_MASTER="\"start_join\": [\"$CONSUL_MASTER\"]"
fi

if [ ! -d /etc/consul.d ]
then
sudo mkdir /etc/consul.d
sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
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

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL
source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

docker run -d --name $CONTAINER_NAME \\
    --net=host \\
    -v /etc/consul.d:/consul/config \\
    -v /opt/consul:/consul/data \\
    consul agent

EOL

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   C O N F L U E N T   P L A T F O R M
#
#====================================================================================================================

#TODO - !!! use some variables so this isn't a copy-and-paste-and-edit fest!!!

#TODO - implement an upgrade flag in these scripts so we can selectively upgrade instead of removing and recreating all the containers every time
#NOTE - these have been implemented as a bunch of different script files so they can be run individually for debugging etc


#====================================================================================================================
#
#                                   Z O O K E E P E R
#
#====================================================================================================================

COMPONENT_NAME="Zookeeper"
CONTAINER_NAME="zk"
DEPENDENCY=""

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

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL
source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

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

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   K A F K A
#
#====================================================================================================================

COMPONENT_NAME="Kafka"
CONTAINER_NAME="kafka"
DEPENDENCY="zk"

if [ ! -d /opt/kafka_data ]
then
    sudo mkdir /opt/kafka_data
    sudo chmod a+w /opt/kafka_data
    echo "/opt/kafka_data created"
else
    echo "/opt/kafka_data exists"
fi

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL

source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

docker run -d \\
    --name kafka \\
    -e KAFKA_ZOOKEEPER_CONNECT=$KAFKA_ZK \\
    -e KAFKA_BROKER_ID=$KAFKA_BROKER_ID \\
    -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://$IP:9092 \\
    -e KAFKA_DELETE_TOPIC_ENABLE=true \\
    -e KAFKA_DEFAULT_REPLICATION_FACTOR=3 \\
    -e KAFKA_NUM_PARTITIONS=3 \\
    -e KAFKA_METRIC_REPORTERS=io.confluent.metrics.reporter.ConfluentMetricsReporter \\
    -e KAFKA_CONFLUENT_METRICS_REPORTER_BOOTSTRAP_SERVERS=localhost:9092 \\
    -e KAFKA_CONFLUENT_METRICS_REPORTER_ZOOKEEPER_CONNECT=localhost:2181 \\
    -P \\
    --net=host \\
    -v /opt/kafka_data:/var/lib/kafka/data \\
    $CURRENT_DOCKER_REPO/$DOCKER_KAFKA_IMAGE:$CP_VERSION

EOL

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   S C H E M A   R E G I S T R Y
#
#
# TODO - use the Schema Registry + nginx + Kerberos version
#
# NOTE: Additional config parameters access.control.* are to enable CORS so that Landoop Schema Registry UI can work
#
#====================================================================================================================

COMPONENT_NAME="Schema Registry"
CONTAINER_NAME="schema-registry"
DEPENDENCY="kafka"

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL

source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

docker run -d \\
  --net=host \\
  --name=schema-registry \\
  -P \\
  -e SCHEMA_REGISTRY_KAFKASTORE_CONNECTION_URL=$IP:$ZK_PORT \\
  -e SCHEMA_REGISTRY_HOST_NAME=$NODE_NAME \\
  -e SCHEMA_REGISTRY_LISTENERS=http://0.0.0.0:$SCHEMA_REGISTRY_PORT \\
  -e SCHEMA_REGISTRY_DEBUG=true \\
  -e SCHEMA_REGISTRY_access.control.allow.methods=GET,POST,PUT,OPTIONS \\
  -e SCHEMA_REGISTRY_access.control.allow.origin=* \\
  $CURRENT_DOCKER_REPO/$DOCKER_SCHEMA_REGISTRY_IMAGE:$CP_VERSION

EOL

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   K A F K A   C O N N E C T  /  M D C   R E P L I C A T O R
#
#====================================================================================================================

COMPONENT_NAME="Kafka Connect"
CONTAINER_NAME="kafka-connect"
DEPENDENCY="kafka"

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL

source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

if [ ! -d /opt/kafka_connect_data ]
then
    sudo mkdir /opt/kafka_connect_data
    sudo chmod a+w /opt/kafka_connect_data
    echo "/opt/kafka_connect_data created"
else
    echo "/opt/kafka_connect_data exists"
fi

docker run -d \\
  --name=kafka-connect \\
  --net=host \\
  -e CONNECT_PRODUCER_INTERCEPTOR_CLASSES=io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor \\
  -e CONNECT_CONSUMER_INTERCEPTOR_CLASSES=io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor \\
  -e CONNECT_BOOTSTRAP_SERVERS=$KAFKA_BOOTSTRAP \\
  -e CONNECT_REST_PORT=$KAFKA_CONNECT_REST_PORT \\
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

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   C O N T R O L   C E N T E R
#
#====================================================================================================================

COMPONENT_NAME="Control Center"
CONTAINER_NAME="control-center"
DEPENDENCY="kafka"

if [ ! -d /tmp/control-center/data ]
then
mkdir -p /tmp/control-center/data
fi

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL

source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

docker run -d \\
  --name=control-center \\
  --net=host \\
  --ulimit nofile=16384:16384 \\
  -p $CONTROL_CENTER_PORT:9021 \\
  -v /tmp/control-center/data:/var/lib/confluent-control-center \\
  -e CONTROL_CENTER_ZOOKEEPER_CONNECT=$KAFKA_ZK \\
  -e CONTROL_CENTER_BOOTSTRAP_SERVERS=$KAFKA_BOOTSTRAP \\
  -e CONTROL_CENTER_REPLICATION_FACTOR=3 \\
  -e CONTROL_CENTER_MONITORING_INTERCEPTOR_TOPIC_PARTITIONS=1 \\
  -e CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS=1 \\
  -e CONTROL_CENTER_STREAMS_NUM_STREAM_THREADS=2 \\
  -e CONTROL_CENTER_CONNECT_CLUSTER=http://$IP:$CONTROL_CENTER_CLUSTER_PORT \\
  $CURRENT_DOCKER_REPO/$DOCKER_CONTROL_CENTER_IMAGE:$CP_VERSION

EOL

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   R E S T   A P I
#
# TODO
#
#====================================================================================================================

COMPONENT_NAME="Kafka REST"
CONTAINER_NAME="kafka-rest"
DEPENDENCY="kafka"

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL

source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

docker run -d \\
  --net=host \\
  --name=kafka-rest \\
  -P \\
  -e KAFKA_REST_ZOOKEEPER_CONNECT=$KAFKA_ZK \\
  -e KAFKA_REST_LISTENERS=http://0.0.0.0:$KAFKA_REST_PORT \\
  -e KAFKA_REST_SCHEMA_REGISTRY_URL=http://$DC_PRIMARY:$SCHEMA_REGISTRY_PORT \\
  -e KAFKA_REST_HOST_NAME=$NODE_NAME \\
  -e KAFKA_REST_ACCESS_CONROL_ALLOW_METHODS=GET,POST,PUT,OPTIONS \\
  -e KAFKA_REST_ACCESS_CONTROL_ALLOW_ORIGIN=* \\
  $CURRENT_DOCKER_REPO/$DOCKER_KAFKA_REST_IMAGE:$CP_VERSION

EOL

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   T O P I C   U I
#
#====================================================================================================================

COMPONENT_NAME="Kafka Topic UI"
CONTAINER_NAME="kafka-topics-ui"
DEPENDENCY="kafka-rest"

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL

source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

docker run -d -p $KAFKA_TOPIC_UI_PORT:8000 \\
    --name kafka-topics-ui \\
    -e "KAFKA_REST_PROXY_URL=http://$DC_PRIMARY:$KAFKA_REST_PORT" \\
    landoop/kafka-topics-ui

EOL

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"

#====================================================================================================================
#
#                                   S C H E M A   R E G I S T R Y   U I
#
#====================================================================================================================

COMPONENT_NAME="Schema Registry UI"
CONTAINER_NAME="schema-registry-ui"
DEPENDENCY="schema-registry"

sudo cat > /etc/kafka-env/${CONTAINER_NAME}.sh << EOL

source /etc/kafka-env/functions.sh

remove_container "$CONTAINER_NAME"

docker run -d -p $SCHEMA_REGISTRY_UI_PORT:8000 \\
    --name schema-registry-ui \\
    -e "SCHEMAREGISTRY_URL=http://$DC_PRIMARY:$SCHEMA_REGISTRY_PORT" \\
    landoop/schema-registry-ui

EOL

sudo chmod +x /etc/kafka-env/${CONTAINER_NAME}.sh
create_service "$COMPONENT_NAME" "$CONTAINER_NAME" "$DEPENDENCY"


#====================================================================================================================
#
#                                   OK, LET'S GO
#
#====================================================================================================================


if [ $UPGRADE = 1 ];
then
    echo Creating consul container
    /etc/kafka-env/consul.sh
    echo Creating zk container
    /etc/kafka-env/zk.sh
    sleep 10
    echo Creating kafka container
    /etc/kafka-env/kafka.sh

    # only install schema registry and control-center on one machine per DC
    if [ $IS_DC_PRIMARY = 1 ];
    then
        sleep 10
        echo Creating schema-registry container
        /etc/kafka-env/schema-registry.sh
        sleep 10
        echo Creating control-center container
        /etc/kafka-env/control-center.sh
        sleep 3
        echo Creating kafka-rest container
        /etc/kafka-env/kafka-rest.sh
        sleep 3
        echo Creating kafka-topics-ui container
        /etc/kafka-env/kafka-topics-ui.sh
        sleep 3
        echo Creating schema-registry-ui container
        /etc/kafka-env/schema-registry-ui.sh
        sleep 3
    fi

    # create the connect/MDC container in case we need it
    echo Creating kafka-connect container
    /etc/kafka-env/kafka-connect.sh
fi

# start our containers at boot

echo Enabling auto-start

systemctl enable docker-consul.service
systemctl enable docker-zk.service
systemctl enable docker-kafka.service

if [ $IS_DC_PRIMARY = 1 ];
then
    systemctl enable docker-kafka-rest.service
    systemctl enable docker-schema-registry.service
    #control center uses a bit of cpu and causes a bunch of replication etc, so best to only run manually when needed
    systemctl enable docker-control-center.service
    # unless testing distributed connect best to leave this off
    systemctl enable docker-kafka-connect.service
    systemctl enable docker-kafka-topics-ui.service
    systemctl enable docker-schema-registry-ui.service
fi

