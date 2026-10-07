# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Kubernetes lab: 1 control plane (kmaster) + N workers (knode1..knodeN).
# Ubuntu 24.04 VMs on VirtualBox, built for Apple Silicon Macs.

K8S_VERSION = "1.37"   # Kubernetes minor version, from pkgs.k8s.io
WORKERS     = 2        # number of worker VMs

BOX      = "bento/ubuntu-24.04"
BOX_ARCH = "arm64"     # Apple Silicon. Use "amd64" on an Intel Mac.

MASTER = { cpus: 2, memory: 4096 }   # memory in MB
WORKER = { cpus: 2, memory: 2048 }

# Each VM has three network cards:
#   eth0  NAT, set up by Vagrant: internet access, vagrant ssh, kubectl port
#   eth1  host-only: your Mac reaches the VMs here while the VPN is off.
#         VirtualBox on macOS only accepts 192.168.56.0/21 for this network.
#   eth2  internal: the nodes talk to each other here. Your Mac and its VPN
#         never see this network, so the cluster works with the VPN on or off.
HOST_NET = "192.168.56"
NODE_NET = "192.168.100"
API_PORT = 6443        # port on your Mac that forwards to the API server

# octet: last part of both IPs (kmaster: 192.168.56.10 and 192.168.100.10)
NODES = [{ name: "kmaster", role: "master", octet: 10 }.merge(MASTER)] +
        (1..WORKERS).map { |i| { name: "knode#{i}", role: "worker", octet: 10 + i }.merge(WORKER) }

# Before it starts a VM, Vagrant checks that each forwarded port is free on
# your Mac by connecting to it. On some company Macs (seen with Cisco Secure
# Client installed, VPN on or off), macOS reports that connection as a success
# even when nothing listens, so every port looks taken and `vagrant up` stops
# with "The forwarded port to 6443 is already in use". This check reads the
# real result of the connection instead.
require "vagrant/util/is_port_open"
module Vagrant::Util::IsPortOpen
  def is_port_open?(host, port)
    TCPSocket.new(host, port, connect_timeout: 1).close
    true
  rescue SystemCallError, IOError   # refused, unreachable or timed out: the port is free
    false
  end
end

Vagrant.configure("2") do |config|
  config.vm.box              = BOX
  config.vm.box_architecture = BOX_ARCH
  config.vm.synced_folder ".", "/vagrant", SharedFoldersEnableSymlinksCreate: false

  hosts = NODES.map { |n| "#{NODE_NET}.#{n[:octet]} #{n[:name]}" }.join(",")

  NODES.each do |node|
    node_ip = "#{NODE_NET}.#{node[:octet]}"

    config.vm.define node[:name] do |machine|
      machine.vm.hostname = node[:name]
      machine.vm.network "private_network", ip: "#{HOST_NET}.#{node[:octet]}"
      machine.vm.network "private_network", ip: node_ip, virtualbox__intnet: "k8s-lab"

      machine.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.cpus   = node[:cpus]
        vb.memory = node[:memory]
      end

      env = {
        "NODE_IP"     => node_ip,
        "K8S_VERSION" => K8S_VERSION,
        "HOSTS"       => hosts,
        "API_PORT"    => API_PORT.to_s,
      }
      machine.vm.provision "shell", path: "scripts/common.sh", env: env

      if node[:role] == "master"
        # kubectl on your Mac goes through localhost, so it works with the VPN on or off
        machine.vm.network "forwarded_port", guest: 6443, host: API_PORT, host_ip: "127.0.0.1"
        machine.vm.provision "shell", path: "scripts/master.sh", env: env
      else
        machine.vm.provision "shell", path: "scripts/worker.sh", env: env
      end
    end
  end
end
