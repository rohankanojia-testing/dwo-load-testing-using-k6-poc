#!/usr/bin/env bash
set -euo pipefail

# ---- config ----
N_USERS="${N_USERS:-10}"
NS="${NS:-dw-webhook-loadtest}"
DW_API_GROUP="workspace.devfile.io"
DW_RESOURCE="devworkspaces"
CLUSTER_ROLE_NAME="k6-devworkspace-webhook-server-role"
TOKEN_TTL="15m"
K6_SCRIPT="${K6_SCRIPT:-test-devworkspace-webhook-server-load/loadtest.js}"
DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="600"
# ----------------

echo "🌐 Getting Kubernetes API server URL..."
KUBE_API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "Kubernetes API server: ${KUBE_API}"

echo "Creating namespace: ${NS}"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating RBAC..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE_NAME}
rules:
- apiGroups: ["${DW_API_GROUP}"]
  resources: ["${DW_RESOURCE}"]
  verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["get", "list", "create", "update", "patch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF

# Build JSON array in memory
TOKENS_JSON="["
for i in $(seq 1 "${N_USERS}"); do
  SA="user-${i}"

  # Create service account
  kubectl create serviceaccount "${SA}" -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

  # Bind clusterrole
  kubectl create clusterrolebinding "${SA}-rb" \
    --clusterrole=dw-user \
    --serviceaccount="${NS}:${SA}" \
    -n "${NS}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Get token
  TOKEN=$(kubectl create token "${SA}" -n "${NS}" --duration="${TOKEN_TTL}")

  # Append JSON object
  TOKENS_JSON+=$(cat <<EOF
{"user":"${SA}","namespace":"${NS}","token":"${TOKEN}"}
EOF
)

  # Add comma if not last
  if [ "$i" -lt "$N_USERS" ]; then
    TOKENS_JSON+=","
  fi
done
TOKENS_JSON+="]"

echo "Done."
echo "Created ${N_USERS} service accounts"
echo "Tokens JSON built in memory"

# ---- invoke k6 with environment variables ----
export K6_USERS_JSON="${TOKENS_JSON}"

echo "🚀 Running k6 load test..."
N_USERS="${N_USERS}" \
K6_USERS_JSON="${K6_USERS_JSON}" \
KUBE_API="${KUBE_API}" \
LOAD_TEST_NAMESPACE="${NS}" \
DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="${DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS}" \
k6 run "${K6_SCRIPT}"

exit_code=$?
if [ $exit_code -ne 0 ]; then
    echo "⚠️ k6 load test failed with exit code $exit_code. Proceeding to cleanup."
fi

oc delete ns $NS
