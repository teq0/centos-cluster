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
    docker stop zk
fi

if docker_container_exists zk;
then
    echo Removing old zk container...
    docker rm zk
fi

docker run -d \
    --name zk \
    -e ZOOKEEPER_SERVER_ID=$ZK_ID \
    -e ZOOKEEPER_SERVERS="$ZK_SERVERS" \
    -e ZOOKEEPER_CLIENT_PORT=2181 \
    -e ZOOKEEPER_TICK_TIME=2000 \
    -e ZOOKEEPER_INIT_LIMIT=5 \
    -e ZOOKEEPER_SYNC_LIMIT=2 \
    -p 2181:2181 \
    -p 2888:2888 \
    -p 3888:3888 \
    --net=host \
    confluentinc/cp-zookeeper
EOL

sudo chmod +x /etc/cba-kafka/zk.sh

sudo cat > /etc/cba-kafka/kafka.sh << EOL

source /etc/cba-kafka/functions.sh

if docker_container_running kafka;
then
    echo Stopping old kafka container...
    docker stop kafka 2> /dev/null
fi

if docker_container_exists kafka;
then
    echo Removing old kafka container...
    docker rm kafka 2> /dev/null
fi

docker run -d \
    --name kafka \
    -e KAFKA_ZOOKEEPER_CONNECT=$KAFKA_ZK \
    -e KAFKA_BROKER_ID=$KAFKA_BROKER_ID \
    -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://:9092 \
    -p 9092:9092 \
    --net=host \
    confluentinc/cp-kafka
EOL

sudo chmod +x /etc/cba-kafka/kafka.sh

if [ $UPGRADE = 1 ];
then
    echo Creating zk container
    /etc/cba-kafka/zk.sh
    sleep 10
    echo Creating kafka container
    /etc/cba-kafka/kafka.sh
else
    echo Starting zk...
    docker start zk 2> /dev/null
    sleep 10
    echo Starting kafka...
    docker start kafka 2> /dev/null
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

echo Enabling auto-start

systemctl enable docker-zk.service
systemctl enable docker-kafka.service

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