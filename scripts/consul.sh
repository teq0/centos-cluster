#!/bin/bash

ip=$1
node=$2
dc=$3
master=$4

if [ "$master" = "" ]
then
	echo "Configuring $node as a master..."
	master="\"server\": true, \"bootstrap\": true"
else
	echo "Configuring $node as a slave..."
	master="\"start_join\": [\"$master\"]"
fi

echo Installing dependencies...
sudo apt-get update
sudo apt-get install -y unzip curl
echo Fetching Consul...
cd /tmp/
wget https://releases.hashicorp.com/consul/0.6.1/consul_0.6.1_linux_amd64.zip -O consul.zip
echo Installing Consul...
unzip consul.zip

sudo chmod +x consul
sudo mv consul /usr/bin/consul
sudo mkdir /etc/consul.d
sudo chmod a+w /etc/consul.d

ls /usr/bin/consul
echo Finished installing and chmoding...

sudo cat > /etc/consul.d/test-config.json << EOL
{
  "datacenter": "$dc",
  "data_dir": "/var/cache/consul",
  "log_level": "INFO",
  "node_name": "$node",
  "bind_addr": "0.0.0.0",
  "advertise_addr": "$ip",
  "domain": "consul.",
  "recursor": "8.8.8.8",
  "encrypt": "p4T1eTQtKji/Df3VrMMLzg==",
  $master
}
EOL

sudo nohup /usr/bin/consul agent -config-dir /etc/consul.d &
