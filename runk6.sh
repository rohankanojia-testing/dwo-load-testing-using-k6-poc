#!/bin/bash

set -euo pipefail

NAMESPACE="loadtest-devworkspaces"
DWO_NAMESPACE="devworkspace-controller"
SA_NAME="k6-devworkspace-tester"
CLUSTERROLE_NAME="k6-devworkspace-role"
ROLEBINDING_NAME="k6-devworkspace-binding"
DWO_METRICS_READER_ROLEBINDING_NAME="dwo-metrics-reader-binding"
K6_SCRIPT="devworkspace_load_test.js"

echo "🔧 Creating Namespace"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF

echo "🔧 Creating ServiceAccount and RBAC..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTERROLE_NAME}
rules:
  - apiGroups: ["workspace.devfile.io"]
    resources: ["devworkspaces"]
    verbs: ["create", "get", "list", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${ROLEBINDING_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CLUSTERROLE_NAME}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $DWO_METRICS_READER_ROLEBINDING_NAME
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: devworkspace-controller-metrics-reader
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${NAMESPACE}
EOF

echo "🔐 Generating token..."
KUBE_TOKEN=$(kubectl create token ${SA_NAME} -n ${NAMESPACE})

echo "🌐 Getting Kubernetes API server URL..."
KUBE_API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

echo "🚀 Running k6 load test..."
KUBE_TOKEN="${KUBE_TOKEN}" KUBE_API="${KUBE_API}" k6 run "${K6_SCRIPT}"

# Start port-forward in background
kubectl -n devworkspace-controller port-forward svc/devworkspace-controller-metrics 8443:8443 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Ensure the port-forward is cleaned up when the script exits
trap "kill $PORT_FORWARD_PID" EXIT

# Wait until port is available
echo "Waiting for port-forward to be ready..."
for i in {1..10}; do
  if nc -z localhost 8443; then
    echo "Port-forward is ready"
    break
  fi
  sleep 1
done

# Now it's safe to call curl
echo "Fetching metrics..."
curl -k -H "Authorization: Bearer ${KUBE_TOKEN}" https://localhost:8443/metrics

# Explicitly kill it (trap will also do this)
kill $PORT_FORWARD_PID
echo "Killed port-forward with PID: $PORT_FORWARD_PID"
