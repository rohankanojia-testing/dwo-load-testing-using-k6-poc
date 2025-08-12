#!/bin/bash

set -euo pipefail

NAMESPACE="loadtest-devworkspaces"
DWO_NAMESPACE="openshift-operators"
SA_NAME="k6-devworkspace-tester"
CLUSTERROLE_NAME="k6-devworkspace-role"
ROLEBINDING_NAME="k6-devworkspace-binding"
DWO_METRICS_READER_ROLEBINDING_NAME="dwo-metrics-reader-binding"
K6_SCRIPT="devworkspace_load_test.js"
DEVWORKSPACE_LINK="https://gist.githubusercontent.com/rohanKanojia/71fe35304009f036b6f6b8a8420fb67c/raw/c98c91c03cad77f759277104b860ce3ca52bf6c2/simple-ephemeral.json"
MAX_VUS="100"
DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="1200"
SEPARATE_NAMESPACES="false"
CREATE_AUTOMOUNT_RESOURCES="false"
LOGS_DIR="logs"
TEST_DURATION_IN_MINUTES="25"

# ----------- Main Execution Flow -----------
main() {
  parse_arguments "$@"
  create_namespace
  create_service_account_and_rbac
  generate_token_and_api_url
  start_background_watchers
  run_k6_test
  stop_background_watchers
}

# ----------- Helper Functions -----------
print_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --max-vus <int>                             Number of virtual users for k6 (default: 100)
  --separate-namespaces <true|false>          Use separate namespaces for workspaces (default: false)
  --devworkspace-ready-timeout-seconds <int>  Timeout in seconds for workspace to become ready (default: 1200)
  --devworkspace-link <string>                DevWorkspace link (default: empty, opinionated DevWorkspace is created)
  --create-automount-resources <true|false>   Whether to create automount resources (default: false)
  --dwo-namespace <string>                    DevWorkspace Operator namespace (default: loadtest-devworkspaces)
  --logs-dir <string>                         Directory name where DevWorkspace and event logs would be dumped
  --test-duration-minutes <int>               Duration in minutes for which to run load tests (default: 25 minutes)
  -h, --help                                  Show this help message
EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-vus)
        MAX_VUS="$2"; shift 2;;
      --separate-namespaces)
        SEPARATE_NAMESPACES="$2"; shift 2;;
      --devworkspace-ready-timeout-seconds)
        DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="$2"; shift 2;;
      --devworkspace-link)
        DEVWORKSPACE_LINK="$2"; shift 2;;
      --create-automount-resources)
        CREATE_AUTOMOUNT_RESOURCES="$2"; shift 2;;
      --dwo-namespace)
        NAMESPACE="$2"; shift 2;;
      --logs-dir)
        LOGS_DIR="$2"; shift 2;;
      --test-duration-minutes)
        TEST_DURATION_IN_MINUTES="$2"; shift 2;;
      -h|--help)
        print_help; exit 0;;
      *)
        echo "❌ Unknown option: $1"
        print_help; exit 1;;
    esac
  done
}

create_namespace() {
  echo "🔧 Creating Namespace: $NAMESPACE"
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF
}

create_service_account_and_rbac() {
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
    verbs: ["create", "get", "list", "watch", "delete", "deletecollection"]
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
}

generate_token_and_api_url() {
  echo "🔐 Generating token..."
  KUBE_TOKEN=$(kubectl create token "${SA_NAME}" -n "${NAMESPACE}")

  echo "🌐 Getting Kubernetes API server URL..."
  KUBE_API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
}

start_background_watchers() {
  echo "📁 Creating logs dir ..."
  mkdir -p ${LOGS_DIR}

  echo "🔍 Starting background watchers..."
  kubectl get events --field-selector involvedObject.kind=Pod --watch --all-namespaces \
    >> "${LOGS_DIR}/$(date +%Y-%m-%d)_events.log" 2>&1 &
  PID_EVENTS_WATCH=$!

  kubectl get dw --watch --all-namespaces \
    >> "${LOGS_DIR}/$(date +%Y-%m-%d)_dw_watch.log" 2>&1 &
  PID_DW_WATCH=$!
}

stop_background_watchers() {
  echo "🛑 Stopping background watchers..."
  kill "$PID_EVENTS_WATCH" "$PID_DW_WATCH" 2>/dev/null || true
}

run_k6_test() {
  echo "🚀 Running k6 load test..."
  KUBE_TOKEN="${KUBE_TOKEN}" \
  KUBE_API="${KUBE_API}" \
  DWO_NAMESPACE="openshift-operators" \
  CREATE_AUTOMOUNT_RESOURCES="${CREATE_AUTOMOUNT_RESOURCES}" \
  SEPARATE_NAMESPACES="${SEPARATE_NAMESPACES}" \
  DEVWORKSPACE_LINK="${DEVWORKSPACE_LINK}" \
  MAX_VUS="${MAX_VUS}" \
  TEST_DURATION_IN_MINUTES="${TEST_DURATION_IN_MINUTES}" \
  DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="${DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS}" \
  k6 run "${K6_SCRIPT}"
}

main "$@"
# Start port-forward in background
#kubectl -n devworkspace-controller port-forward svc/devworkspace-controller-metrics 8443:8443 >/dev/null 2>&1 &
#PORT_FORWARD_PID=$!
#
## Ensure the port-forward is cleaned up when the script exits
#trap "kill $PORT_FORWARD_PID" EXIT
#
## Wait until port is available
#echo "Waiting for port-forward to be ready..."
#for i in {1..10}; do
#  if nc -z localhost 8443; then
#    echo "Port-forward is ready"
#    break
#  fi
#  sleep 1
#done
#
## Now it's safe to call curl
#echo "Fetching metrics..."
#curl -k -H "Authorization: Bearer ${KUBE_TOKEN}" https://localhost:8443/metrics
#
## Explicitly kill it (trap will also do this)
#kill $PORT_FORWARD_PID
#echo "Killed port-forward with PID: $PORT_FORWARD_PID"
