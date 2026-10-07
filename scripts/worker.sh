#!/usr/bin/env bash
# Runs on each knodeN: joins the cluster with the join.sh written by kmaster.
set -euo pipefail

echo "==> worker: $(hostname)"

if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "--> Already in the cluster, nothing to do"
  exit 0
fi

if [ ! -s /vagrant/join.sh ]; then
  echo "ERROR: join.sh is missing. Create the master first: vagrant up kmaster" >&2
  exit 1
fi

echo "--> kubeadm join"
if ! bash /vagrant/join.sh; then
  kubeadm reset -f > /dev/null 2>&1 || true
  echo "ERROR: join failed. If kmaster is more than 24 h old, its join token has expired:" >&2
  echo "       vagrant provision kmaster && vagrant provision $(hostname)" >&2
  exit 1
fi

echo "==> worker: done"
