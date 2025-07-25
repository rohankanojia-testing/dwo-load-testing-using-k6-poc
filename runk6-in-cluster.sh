#!/bin/bash

# === Config ===
NAMESPACE="loadtest-devworkspaces"
SA_NAME="k6-devworkspace-tester"
CLUSTERROLE_NAME="k6-devworkspace-role"
ROLEBINDING_NAME="k6-devworkspace-binding"
SCRIPT_FILE="devworkspace_load_test_in_cluster.js"
CONFIGMAP_NAME="k6-test-script"
K6_CR_NAME="k6-test-run"

echo "🔧 Creating Namespace"
oc new-project $NAMESPACE

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
EOF

echo "🔐 Generating token..."
KUBE_TOKEN=$(kubectl create token ${SA_NAME} -n ${NAMESPACE})

echo "🌐 Getting Kubernetes API server URL..."
KUBE_API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

echo "🚀 Running k6 load test..."
KUBE_TOKEN="${KUBE_TOKEN}" KUBE_API="${KUBE_API}" k6 run "${K6_SCRIPT}"

echo "🧩 Creating ConfigMap from $SCRIPT_FILE ..."
kubectl create configmap $CONFIGMAP_NAME \
  --from-file=script.js=$SCRIPT_FILE \
  --namespace $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

echo "🚀 Creating K6 custom resource ..."
cat <<EOF | kubectl apply -f -
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: $K6_CR_NAME
  namespace: $NAMESPACE
spec:
  parallelism: 1
  script:
    configMap:
      name: $CONFIGMAP_NAME
      file: script.js
  runner:
    serviceAccountName: $SA_NAME
EOF

echo "📦 K6 test launched. Watch pods with:"
echo "    kubectl get pods -n $NAMESPACE -l k6_cr=$K6_CR_NAME"
kubectl get pods -n $NAMESPACE -l k6_cr=$K6_CR_NAME
