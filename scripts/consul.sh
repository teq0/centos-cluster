if [ ! -d /opt/consul ]
then
sudo mkdir -p /opt/consul
sudo chmod a+w /opt/consul
fi

docker run --name consul --net=host -v /etc/consul.d:/consul/config -v /opt/consul:/consul/data consul agent -server
