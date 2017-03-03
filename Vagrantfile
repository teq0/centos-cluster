# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrantfile API/syntax version. Don't touch unless you know what you're doing!
VAGRANTFILE_API_VERSION = "2"

nodes = [
  { :nodename => 'dc1n01', :ip => '10.42.1.11', :dc => 'dc1', :master => '', :zk_id => 1, :kafka_broker_id => 1},
  { :nodename => 'dc1n02', :ip => '10.42.1.12', :dc => 'dc1', :master => '10.42.1.11', :zk_id => 2, :kafka_broker_id => 2 },
  { :nodename => 'dc1n03', :ip => '10.42.1.13', :dc => 'dc1', :master => '10.42.1.11', :zk_id => 3, :kafka_broker_id => 3 }
  #{ :nodename => 'dc2n01', :ip => '10.43.1.11', :dc => 'dc2', :master => '', :zk_id => 1, :kafka_broker_id => 1 },
  #{ :nodename => 'dc2n02', :ip => '10.43.1.12', :dc => 'dc2', :master => '10.43.1.11', :zk_id => 2, :kafka_broker_id => 2 },
  #{ :nodename => 'dc2n03', :ip => '10.43.1.13', :dc => 'dc2', :master => '10.43.1.11', :zk_id => 3, :kafka_broker_id => 3 }
]

zk_servers = { "dc1" => "", "dc2" => "" }
kafka_servers = { "dc1" => "", "dc2" => "" }
kafka_bootstrap = { "dc1" => "", "dc2" => "" }
comma = { "dc1" => "", "dc2" => "" }
semicolon = { "dc1" => "", "dc2" => "" }

nodes.each do |node|
    zk_servers[node[:dc]] << "#{semicolon[node[:dc]]}#{node[:ip]}:2888:3888"
    kafka_servers[node[:dc]] << "#{comma[node[:dc]]}#{node[:ip]}:2181"
    kafka_bootstrap[node[:dc]] << "#{comma[node[:dc]]}#{node[:ip]}:9092"
    comma[node[:dc]] = ","
    semicolon[node[:dc]] = ";"
end


Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  #config.vm.provider = "parallels"
  #config.vm.provider = "virtualbox"

  config.vm.box = "bento/centos-7.2"

  nodes.each do |node|
    config.vm.define node[:nodename] do |nodeconfig|
      nodeconfig.vm.hostname = node[:nodename]
      nodeconfig.vm.network :private_network, ip: node[:ip]

      nodeconfig.vm.provider "parallels" do |prl|
        prl.name = node[:nodename]
        prl.memory = 1576
        prl.cpus = 1
        # uncomment if you want to update the parallels tools
        # prl.update_guest_tools = true
        prl.customize ["set", :id, "--time-sync", "on"]
      end

      nodeconfig.vm.provider "virtualbox" do |v|
        v.name = node[:nodename]
        v.memory = 1576
        v.cpus = 1
      end

      nodeconfig.vm.provision "shell" do |s|
         s.path = "scripts/install.sh"
         s.args = [
                    "-i", node[:ip],
                    "-n", node[:nodename],
                    "-dc", node[:dc],
                    "-cm", node[:master],
                    "-zk_id", node[:zk_id],
                    "-zk_servers", zk_servers[node[:dc]],
                    "-kafka_id", node[:kafka_broker_id],
                    "-kafka_zk", kafka_servers[node[:dc]],
                    "-kafka_bootstrap", kafka_bootstrap[node[:dc]],
                    "-v"
                  ]
      end
    end
  end
end
