#!/usr/bin/env bash

#global vars

IP=
NODE_NAME=
DC=
MASTER=
ZK_ID=
ZK_SERVERS=
KAFKA_BROKER_ID=
KAFKA_ZK=
UPGRADE=1

# docker repos
# [0] is the internet
# [1] is a repo on the host system
# [2] is CBA artefactory (TODO - get the URLs for the CBA Artifactory repos

DOCKER_REPO_ID=0

DOCKER_REPO[0]="confluentinc"
DOCKER_REPO[1]="10.0.2.2:5000/confluentinc"
DOCKER_REPO[2]="no idea"

CURRENT_DOCKER_REPO=${DOCKER_REPO[$DOCKER_REPO_ID]}

# local docker registry not currently working either

echo Current docker repo is $CURRENT_DOCKER_REPO

# parse our arguments

while [[ $# -gt 1 ]]
do
key="$1"

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
    -m|--master)
    MASTER="$2"
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

if [ "$MASTER" = "" ]
then
	echo "Configuring $NODE_NAME as a master..."
	MASTER="\"server\": true, \"bootstrap\": true"
else
	echo "Configuring $NODE_NAME as a slave..."
	MASTER="\"start_join\": [\"$MASTER\"]"
fi

echo Installing dependencies...
#sudo apt-get update
#sudo apt-get install -y unzip curl

#echo Fetching Consul...
#cd /tmp/
#wget https://releases.hashicorp.com/consul/0.6.1/consul_0.6.1_linux_amd64.zip -O consul.zip
#echo Installing Consul...
#unzip consul.zip

#sudo chmod +x consul
#sudo mv consul /usr/bin/consul
#sudo mkdir /etc/consul.d
#sudo chmod a+w /etc/consul.d

# install java jre 1.8

# NOTE: Confluent include Zulu OpenJDK in their images so this isn't necessary unless we start running other Java stuff.

if ! type java >/dev/null 2>&1
then
    JAVA_VER=0
else
    JAVA_VER=$(java -version 2>&1 | sed 's/java version "\(.*\)\.\(.*\)\..*"/\1\2/; 1q')
fi

echo "Java version is $JAVA_VER"

if [ $JAVA_VER -lt 18 ]
then
    sudo rpm -Uvh /vagrant/vendor/jre-8u102-linux-x64.rpm
fi

#if [ "$MASTER" = "" ]
#then
    #echo "Installing mesos..."
#    sudo rpm -Uvh /vagrant/vendor/mesos-1.0.1-2.0.93.centos701406.x86_64.rpm
#else
    #echo "Mesos already installed"
#fi

#Docker

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

# confluent stuff

if [ ! -d /etc/cba-kafka ]
then
    sudo mkdir /etc/cba-kafka
    sudo chmod a+w /etc/cba-kafka
    echo "/etc/cba-kafka created"
fi

#ls /usr/bin/consul
#echo Finished installing and chmoding...


#TODO - implement an upgrade flag in these scripts so we can selectively upgrade instead of removing and recreating the containers every time

# some utility functions we will need in various places

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
     $CURRENT_DOCKER_REPO/cp-zookeeper:3.0.1
EOL

sudo chmod +x /etc/cba-kafka/zk.sh

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

if [ ! -d /opt/kafka_data ]
then
    sudo mkdir /opt/kafka_data
    sudo chmod a+w /opt/kafka_data
    echo "/opt/kafka_data created"
else
    echo "/opt/kafka_data exists"
fi

docker run -d \\
    --name kafka \\
    -e KAFKA_ZOOKEEPER_CONNECT=$KAFKA_ZK \\
    -e KAFKA_BROKER_ID=$KAFKA_BROKER_ID \\
    -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://$IP:9092 \\
    -P \\
    --net=host \\
    -v /opt/kakfa_data:/var/lib/kafka/data \\
    $CURRENT_DOCKER_REPO/cp-kafka:3.0.1
EOL

sudo chmod +x /etc/cba-kafka/kafka.sh

sudo cat > /etc/cba-kafka/schema-registry.sh << EOL

source /etc/cba-kafka/functions.sh

if docker_container_running schema-registry;
then
    echo Stopping old schema-registry container...
    systemctl disable docker-schema-registry.service
    docker stop schema-registry >/dev/null
fi

if docker_container_exists schema-regisry;
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
  confluentinc/cp-schema-registry:3.0.1

EOL

sudo chmod +x /etc/cba-kafka/schema-registry.sh

if [ $UPGRADE = 1 ];
then
    echo Creating zk container
    /etc/cba-kafka/zk.sh
    sleep 10
    echo Creating kafka container
    /etc/cba-kafka/kafka.sh
    sleep 10
    echo Creating schema-registry container
    /etc/cba-kafka/schema-registry.sh
else
    echo Starting zk...
    docker start zk 2> /dev/null
    sleep 8
    echo Starting kafka...
    docker start kafka 2> /dev/null
    sleep 8
    echo Starting schema-registry...
    docker start schema-registry 2> /dev/null
fi

# start our containers at boot

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

echo Enabling auto-start

systemctl enable docker-zk.service
systemctl enable docker-kafka.service
systemctl enable docker-schema-registry.service

# this is consul stuff, maybe add in later

sudo cat > /etc/cba-kafka/test-config.json << EOL
{
  "datacenter": "$DC",
  "data_dir": "/var/cache/consul",
  "log_level": "INFO",
  "node_name": "$NODE_NAME",
  "bind_addr": "0.0.0.0",
  "advertise_addr": "$IP",
  "domain": "consul.",
  "recursor": "8.8.8.8",
  "encrypt": "p4T1eTQtKji/Df3VrMMLzg==",
  $MASTER
}
EOL
