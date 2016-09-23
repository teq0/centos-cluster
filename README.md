# centos-cluster
This is a vagrant configuration for standing up different numbers of VMs with zookeeper and kafka configured as separate data centers.
## Usage
The Vagrantfile contains settings for both Parallels and Virtualbox (not quite finished)

## Description
An array contains a list of VMs aling with their configuration e.g. host name, IP address etc

Each VM (currently runs one zookeeper instance and one kafka instance, both from the confluentinc docker containers).

## Todo
* Multiple docker containers per node
* Add one or more nodes running zk-web, kafka-manager, Confluent REST API, Ops Centre and Schema Registry
* Add Storm
* Add Mesos
* Add weave or flannel or some OpenFlow thing for networking
* Add in Datastax Enterprise
* Tidy up extremely ugly code
* Lots more

## ./vendor
The scripts rely on some files to be in the ./vendor folder (from the project root).

I'll add a list of what they are Real Soon Now, and update the install scripts to optionally take different versions of things like the Java runtime
