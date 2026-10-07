#!/usr/bin/env bash
# Runs on kmaster only: creates the cluster, installs Flannel, and writes
# kubeconfig (for your Mac) and join.sh (for the workers) to the project folder.
# Safe to re-run (vagrant provision kmaster): it also renews join.sh.
set -euo pipefail

: "${NODE_IP:?}" "${API_PORT:?}"
FLANNEL_VERSION="v0.28.9"
POD_CIDR="10.244.0.0/16"   # must match "Network" in the Flannel manifest
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "==> master: $(hostname) (${NODE_IP})"

if [ -f /etc/kubernetes/admin.conf ]; then
  echo "--> Cluster already initialized, skipping kubeadm init"
else
  # Same version as the kubeadm package, so kubeadm doesn't look it up online
  KUBE_VERSION=$(kubeadm version -o short)
  echo "--> kubeadm init ${KUBE_VERSION} (downloads the control plane images, a few minutes)"
  if ! kubeadm init \
      --kubernetes-version="${KUBE_VERSION}" \
      --apiserver-advertise-address="${NODE_IP}" \
      --apiserver-cert-extra-sans=127.0.0.1 \
      --pod-network-cidr="${POD_CIDR}"; then
    kubeadm reset -f > /dev/null 2>&1 || true
    echo "ERROR: kubeadm init failed. Fix the cause above, then run: vagrant provision kmaster" >&2
    exit 1
  fi
fi

echo "--> Waiting for the API server"
if ! timeout 300 bash -c 'until kubectl get --raw=/readyz > /dev/null 2>&1; do sleep 5; done'; then
  echo "ERROR: API server not ready after 5 minutes" >&2
  exit 1
fi

# CoreDNS sends outside names to the servers in the node's resolv.conf, which
# include the ones DHCP gave at boot. 10.0.2.3 always follows your Mac.
echo "--> CoreDNS: forward outside names to 10.0.2.3"
kubectl -n kube-system get configmap coredns -o yaml \
  | sed 's|forward \. /etc/resolv\.conf|forward . 10.0.2.3|' \
  | kubectl replace -f - > /dev/null

# Flannel picks the default-route interface (the NAT one) unless told otherwise
IFACE=$(ip -o -4 addr show | awk -v ip="${NODE_IP}" '$4 ~ "^"ip"/" { print $2; exit }')
if [ -z "${IFACE}" ]; then
  echo "ERROR: no network interface holds ${NODE_IP}" >&2
  exit 1
fi
echo "--> Flannel ${FLANNEL_VERSION} on ${IFACE}"
curl -fsSL "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" \
  | sed "s|^\( *\)- --kube-subnet-mgr$|&\n\1- --iface=${IFACE}|" \
  | kubectl apply -f -

echo "--> kubectl for the vagrant user (alias k, bash completion)"
install -d -o vagrant -g vagrant /home/vagrant/.kube
install -o vagrant -g vagrant -m 600 /etc/kubernetes/admin.conf /home/vagrant/.kube/config
if ! grep -q 'kubectl completion' /home/vagrant/.bashrc; then
  cat >> /home/vagrant/.bashrc <<'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
fi

echo "--> kubeconfig and join.sh in the project folder"
sed "s|server: https://.*|server: https://127.0.0.1:${API_PORT}|" /etc/kubernetes/admin.conf > /vagrant/kubeconfig
kubectl --kubeconfig /vagrant/kubeconfig config rename-context kubernetes-admin@kubernetes k8s-lab > /dev/null
JOIN_COMMAND=$(kubeadm token create --print-join-command)
echo "${JOIN_COMMAND}" > /vagrant/join.sh

echo "--> Waiting for $(hostname) to be Ready"
kubectl wait --for=condition=Ready "node/$(hostname)" --timeout=300s

echo "==> master: done"
