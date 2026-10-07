#!/usr/bin/env bash
# Runs on every VM: prepares Ubuntu 24.04 to run Kubernetes.
# Safe to re-run (vagrant provision): packages are installed only once.
set -euo pipefail

: "${NODE_IP:?}" "${K8S_VERSION:?}" "${HOSTS:?}"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

apt_update() {
  # Retries while another apt run holds the lock or the network hiccups.
  # Without --error-on=any, apt-get update ignores download errors.
  for _ in 1 2 3 4 5 6; do
    apt-get -qq update --error-on=any && return 0
    echo "    apt-get update failed, retrying in 10 s"
    sleep 10
  done
  echo "ERROR: apt-get update keeps failing. VPN on? See Troubleshooting in the README." >&2
  return 1
}

apt_install() {
  apt-get -qq -o DPkg::Lock::Timeout=300 install -y "$@" > /dev/null
}

echo "==> common: $(hostname) (${NODE_IP}), Kubernetes ${K8S_VERSION}"

echo "--> /etc/hosts: one line per node"
IFS=',' read -ra entries <<< "${HOSTS}"
for entry in "${entries[@]}"; do
  grep -qxF "${entry}" /etc/hosts || echo "${entry}" >> /etc/hosts
done

# DHCP gives the VM the DNS servers your Mac had at boot, and they go stale
# when the VPN goes on or off. VirtualBox answers on 10.0.2.3 with whatever
# DNS your Mac uses at that moment.
echo "--> DNS: use 10.0.2.3, which follows your Mac (VPN on or off)"
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=10.0.2.3\nDomains=~.\n' > /etc/systemd/resolved.conf.d/vbox-nat.conf
systemctl restart systemd-resolved

# For VPNs that inspect HTTPS: their root certificate, in PEM format
if compgen -G "/vagrant/certs/*.crt" > /dev/null; then
  echo "--> CA certificates from certs/"
  cp /vagrant/certs/*.crt /usr/local/share/ca-certificates/
  update-ca-certificates > /dev/null
  systemctl try-restart containerd 2> /dev/null || true
fi

echo "--> Swap off (the kubelet won't start with swap on)"
swapoff -a
sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab

echo "--> Kernel modules and sysctl for pod networking"
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null

if ! command -v kubeadm > /dev/null; then
  # Ubuntu's daily apt jobs start at first boot and lock apt. They also
  # upgrade packages unattended, which a lab cluster doesn't need.
  echo "--> Stop automatic apt updates"
  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2> /dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2> /dev/null || true

  echo "--> containerd (Ubuntu package)"
  apt_update
  apt_install containerd ca-certificates curl gpg bash-completion

  echo "--> kubelet, kubeadm, kubectl, crictl ${K8S_VERSION} (pkgs.k8s.io)"
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt_update
  apt_install kubelet kubeadm kubectl cri-tools
  apt-mark hold kubelet kubeadm kubectl > /dev/null
fi

if ! grep -qs 'SystemdCgroup = true' /etc/containerd/config.toml; then
  echo "--> containerd config: systemd cgroup driver, same pause image as kubeadm"
  PAUSE_IMAGE=$(kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" 2> /dev/null | grep '/pause:' || true)
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
  if [ -n "${PAUSE_IMAGE}" ]; then
    sed -i "s|^\( *sandbox\(_image\)\? = \).*|\1'${PAUSE_IMAGE}'|" /etc/containerd/config.toml
  fi
  systemctl restart containerd
  printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\n' > /etc/crictl.yaml
fi

# Without this, every node registers with the NAT address 10.0.2.15
echo "--> kubelet: use ${NODE_IP}, not the NAT address"
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
systemctl enable kubelet > /dev/null 2>&1
systemctl restart kubelet

echo "==> common: done"
