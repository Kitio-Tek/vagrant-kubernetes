#!/usr/bin/env bash
# Checks the cluster network from your Mac: node IPs, pod IPs, pod-to-pod
# traffic between nodes, Services and DNS. Deletes its test pods at the end.
# Works with the bash that ships with macOS.
set -euo pipefail

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig}"
NS=lab-check
IMAGE=registry.k8s.io/e2e-test-images/agnhost:2.66.1
FAILED=0

ok()   { echo "  ok    $*"; }
warn() { echo "  warn  $*"; }
fail() { echo "  FAIL  $*"; FAILED=1; }

# probe POD HOST:PORT opens a TCP connection from inside the pod.
# On failure it prints the first error line: DNS, TIMEOUT, REFUSED or OTHER.
probe() {
  local out
  if out=$(kubectl -n "${NS}" exec "$1" -- /agnhost connect "$2" --timeout=5s < /dev/null 2>&1); then
    return 0
  fi
  printf '%s\n' "${out}" | head -n 1
  return 1
}

if ! kubectl get --raw=/readyz > /dev/null 2>&1; then
  echo "Can't reach the API server with ${KUBECONFIG}. Is kmaster running? (vagrant status)" >&2
  exit 1
fi

echo "Nodes"
NODE_CIDRS=""
while IFS='|' read -r name ip cidr flannel ready; do
  line="${name}  ${ip}  pods ${cidr:-none}"
  if [ "${ready}" != "True" ]; then
    fail "${line}: not Ready"
  elif [ -z "${ip}" ] || [ "${ip#10.0.2.}" != "${ip}" ]; then
    fail "${line}: the node uses the NAT address, check --node-ip in /etc/default/kubelet"
  elif [ -z "${cidr}" ]; then
    fail "${line}: no pod range, check --pod-network-cidr"
  elif [ "${flannel}" != "${ip}" ]; then
    fail "${line}: Flannel uses ${flannel:-no address}, expected ${ip}"
  else
    ok "${line}"
  fi
  NODE_CIDRS="${NODE_CIDRS}${name}|${cidr}
"
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.addresses[?(@.type=="InternalIP")].address}{"|"}{.spec.podCIDR}{"|"}{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')

echo "Test pods, one per node (the first run downloads ${IMAGE})"
kubectl delete namespace "${NS}" --ignore-not-found > /dev/null
kubectl create namespace "${NS}" > /dev/null
trap 'kubectl delete namespace "${NS}" --wait=false > /dev/null 2>&1 || true' EXIT
kubectl -n "${NS}" apply -f - > /dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: netcheck
spec:
  selector:
    matchLabels: {app: netcheck}
  template:
    metadata:
      labels: {app: netcheck}
    spec:
      tolerations: [{operator: Exists}]   # runs on kmaster too
      terminationGracePeriodSeconds: 1
      containers:
      - name: agnhost
        image: ${IMAGE}
        args: ["netexec", "--http-port=8080"]
---
apiVersion: v1
kind: Service
metadata:
  name: netcheck
spec:
  selector: {app: netcheck}
  ports: [{port: 80, targetPort: 8080}]
EOF
if ! kubectl -n "${NS}" rollout status daemonset/netcheck --timeout=300s > /dev/null; then
  fail "test pods not ready after 5 minutes"
  kubectl -n "${NS}" get pods -o wide
  exit 1
fi
PODS=$(kubectl -n "${NS}" get pods -l app=netcheck -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{.status.podIP}{"\n"}{end}')
if [ -z "${PODS}" ]; then
  fail "no test pod was scheduled"
  exit 1
fi

while IFS='|' read -r pod node pod_ip; do
  cidr=$(printf '%s' "${NODE_CIDRS}" | awk -F'|' -v n="${node}" '$1 == n { print $2 }')
  if [ -n "${cidr}" ] && [ "${pod_ip%.*}" = "${cidr%.*}" ]; then
    ok "${node}  pod ${pod_ip} is in ${cidr}"
  else
    fail "${node}  pod ${pod_ip} is outside the node range ${cidr:-(none)}"
  fi
done <<< "${PODS}"

echo "Pod to pod, between nodes"
while IFS='|' read -r pod node _; do
  while IFS='|' read -r _ peer peer_ip; do
    if [ "${peer}" = "${node}" ]; then continue; fi
    if msg=$(probe "${pod}" "${peer_ip}:8080"); then
      ok "${node} -> ${peer}  ${peer_ip}"
    else
      fail "${node} -> ${peer}  ${peer_ip}: ${msg}"
    fi
  done <<< "${PODS}"
done <<< "${PODS}"

echo "Services and DNS, from each node"
while IFS='|' read -r pod node _; do
  for target in kubernetes.default:443 netcheck:80; do
    if msg=$(probe "${pod}" "${target}"); then
      ok "${node} -> ${target}"
    else
      fail "${node} -> ${target}: ${msg}"
    fi
  done
  if msg=$(probe "${pod}" registry.k8s.io:443); then
    ok "${node} -> registry.k8s.io:443 (internet)"
  elif [ "${msg#DNS}" != "${msg}" ]; then
    fail "${node} -> registry.k8s.io:443: ${msg}"
  else
    warn "${node} -> registry.k8s.io:443: ${msg} (DNS works, your network blocks the connection)"
  fi
done <<< "${PODS}"

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks failed." >&2
  exit 1
fi
