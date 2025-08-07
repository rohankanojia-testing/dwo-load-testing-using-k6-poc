#!/bin/bash

# === Config ===
DWO_NAMESPACE="openshift-operators"
NAMESPACE="loadtest-devworkspaces"
SA_NAME="k6-devworkspace-tester"
CLUSTERROLE_NAME="k6-devworkspace-role"
ROLEBINDING_NAME="k6-devworkspace-binding"
SCRIPT_FILE="devworkspace_load_test_in_cluster.js"
CONFIGMAP_NAME="k6-test-script"
K6_CR_NAME="k6-test-run"
K6_CR_LABEL="k6_cr=${K6_CR_NAME}"

echo "Installing k6 operator"
curl -L https://raw.githubusercontent.com/grafana/k6-operator/refs/tags/${K6_OPERATOR_VERSION}/bundle.yaml | kubectl apply -f -
echo "Waiting Until k6 deployment is ready"
kubectl rollout status deployment/k6-operator-controller-manager -n k6-operator-system --timeout=300s

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
  - apiGroups: [""]
    resources: ["configmaps", "secrets", "namespaces"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods"]
    verbs: ["get", "list"]
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

echo "🧩 Creating ConfigMap from $SCRIPT_FILE ..."
kubectl create configmap $CONFIGMAP_NAME \
  --from-file=script.js=$SCRIPT_FILE \
  --namespace $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl delete testrun --all -n $NAMESPACE

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
    env:
    - name: CREATE_AUTOMOUNT_RESOURCES
      value: 'false'
EOF

# Wait for the pod to be created and become ready for completion check
echo "⏳ Waiting for K6 test pod to appear..."
kubectl wait --for=condition=Ready pod -l "${K6_CR_LABEL}" -n "${NAMESPACE}" --timeout=120s

# Get the pod name
K6_TEST_POD=$(kubectl get pod -l "${K6_CR_LABEL}" -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')

# Wait for the pod to complete
echo "⏳ Waiting for K6 test pod $POD to complete..."
kubectl wait --for=condition=complete pod/"$K6_TEST_POD" -n "$NAMESPACE" --timeout=1800s

# Show logs
echo "📜 Logs from completed K6 test pod: $K6_TEST_POD"
kubectl logs "$K6_TEST_POD" -n "$NAMESPACE"
