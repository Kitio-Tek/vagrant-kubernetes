# Kubernetes lab with Vagrant and VirtualBox

A Kubernetes cluster on your Mac, built with kubeadm on Ubuntu 24.04 VMs.

| VM | Role | Node IP | IP from your Mac | CPUs | RAM |
|---|---|---|---|---|---|
| kmaster | control plane | 192.168.100.10 | 192.168.56.10 | 2 | 4 GB |
| knode1 | worker | 192.168.100.11 | 192.168.56.11 | 2 | 2 GB |
| knode2 | worker | 192.168.100.12 | 192.168.56.12 | 2 | 2 GB |

Kubernetes 1.37 with containerd and Flannel. Pods get IPs in 10.244.0.0/16 and Services in 10.96.0.0/12. The nodes talk to each other on 192.168.100.x, a VirtualBox internal network that your Mac and your VPN never see.

## 1. Check your Mac

```bash
uname -m                                               # arm64 on Apple Silicon
echo "$(( $(sysctl -n hw.memsize) / 1073741824 )) GB"  # the VMs use 8 GB
```

Steps 2 and 3 ask for your Mac password, so you need admin rights.

## 2. Install VirtualBox

```bash
brew install --cask virtualbox
VBoxManage --version   # 7.2.2 or later
```

## 3. Install Vagrant

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/hashicorp-vagrant
vagrant --version      # 2.4 or later
```

## 4. Choose the cluster size (optional)

The settings are at the top of the `Vagrantfile`:

```ruby
K8S_VERSION = "1.37"                 # Kubernetes minor version
WORKERS     = 2                      # number of worker VMs
MASTER = { cpus: 2, memory: 4096 }   # memory in MB
WORKER = { cpus: 2, memory: 2048 }
```

## 5. Create the control plane: 1 VM

```bash
cd vagrant-kubernetes-lab
vagrant up kmaster
```

It takes a few minutes, more the first time while the Ubuntu box downloads. `scripts/common.sh` prepares Ubuntu (swap off, containerd, kubeadm, kubelet, kubectl), then `scripts/master.sh` runs `kubeadm init`, installs Flannel and writes two files to this folder:

- `kubeconfig`: admin access for kubectl on your Mac
- `join.sh`: the command the workers run to join

Both grant access to the cluster. `.gitignore` keeps them out of Git.

## 6. Add the workers: 2 VMs

```bash
vagrant up knode1 knode2
```

Each worker runs `scripts/common.sh`, then `scripts/worker.sh`, which runs `join.sh`. With more workers, list every name, or run `vagrant up` to start all the VMs that aren't running yet.

A plain `vagrant up` does steps 5 and 6 in one go, master first.

## 7. Check the cluster from your Mac

You need kubectl on the Mac (`brew install kubectl`).

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

After a minute or so, expect 3 nodes `Ready`, with internal IPs 192.168.100.10 to .12.

## 8. Test the network

```bash
./scripts/check-cluster.sh
```

It checks node IPs, pod IPs, traffic between pods on different nodes, Services and DNS, then deletes its test pods. Run it again whenever something looks wrong.

## 9. SSH into the nodes

```bash
vagrant ssh kmaster    # kubectl works here too, with the alias k
vagrant ssh knode1
```

For a regular `ssh kmaster`, VS Code or scp, run `vagrant ssh-config >> ~/.ssh/config` once.

## VPN on or off

There is nothing to switch. The cluster runs the same either way, and the VMs use whatever DNS your Mac uses at the moment.

| From your Mac | VPN off | VPN on |
|---|---|---|
| kubectl, `vagrant ssh` | yes | yes |
| Apps through `kubectl port-forward` | yes | yes |
| ping, ssh or NodePorts on 192.168.56.x | yes | often blocked |
| Downloads inside the VMs (apt, images) | yes | depends on your company network |

To open an app:

```bash
kubectl create deployment web --image=nginx
kubectl expose deployment web --type=NodePort --port=80
kubectl get service web                    # VPN off: open http://192.168.56.11:<node port>
kubectl port-forward service/web 8080:80   # VPN on or off: open http://localhost:8080, Ctrl-C to stop
kubectl delete deployment,service web
```

## Everyday commands

| Command | What it does |
|---|---|
| `vagrant status` | shows the state of each VM |
| `vagrant halt` | stops the VMs; the cluster comes back with the next `vagrant up` |
| `vagrant up knode3` | adds a worker, after you raise `WORKERS` to 3 |
| `vagrant provision <vm>` | re-runs that VM's scripts (safe to repeat) |
| `vagrant destroy -f` | deletes the VMs and the cluster |

## Troubleshooting

| Problem | Fix |
|---|---|
| ping, ssh or a NodePort on 192.168.56.x times out | Your VPN takes over that range. Use kubectl, `kubectl port-forward` and `vagrant ssh`, or turn the VPN off. |
| Downloads fail during `vagrant up` with the VPN on | Your company network blocks them. Turn the VPN off, then run `vagrant up --provision`. |
| Downloads fail with certificate errors with the VPN on | Your VPN inspects HTTPS. Export its root certificate from Keychain Access in PEM format to `certs/company.crt`, then run `vagrant up --provision`. |
| A new worker fails to join | The join token lasts 24 h. Run `vagrant provision kmaster` to renew `join.sh`, then `vagrant provision <worker>`. |
| `vagrant up` says port 6443 is already in use | Set another `API_PORT` in the `Vagrantfile`, then run `vagrant reload kmaster --provision`. |
| `vagrant up` says a VM named kmaster already exists | An old VM has that name. Delete it in VirtualBox, or run `VBoxManage unregistervm kmaster --delete`. |
| `The IP address configured for the host-only network is not within the allowed ranges` | VirtualBox on macOS only accepts 192.168.56.0/21 for host-only networks. Keep `HOST_NET` in that range. |
