#!/bin/bash

# === Config ===
NAMESPACE="loadtest-devworkspaces"
DWO_NAMESPACE="openshift-operators"
SA_NAME="k6-devworkspace-tester"
CLUSTERROLE_NAME="k6-devworkspace-role"
ROLEBINDING_NAME="k6-devworkspace-binding"
DEVWORKSPACE_LINK="https://gist.githubusercontent.com/rohanKanojia/71fe35304009f036b6f6b8a8420fb67c/raw/c98c91c03cad77f759277104b860ce3ca52bf6c2/simple-ephemeral.json"
MAX_VUS="100"
DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS="1200"
SEPARATE_NAMESPACES="false"
CREATE_AUTOMOUNT_RESOURCES="false"
LOGS_DIR="logs"
TEST_DURATION_IN_MINUTES="25"
SCRIPT_FILE="devworkspace_load_test_in_cluster.js"
CONFIGMAP_NAME="k6-test-script"
K6_OPERATOR_VERSION="v0.0.22"
K6_CR_NAME="k6-test-run"
K6_CR_LABEL="k6_cr=${K6_CR_NAME}"

main() {
  parse_arguments "$@"
  install_k6_operator
  create_namespace
  create_rbac
  create_k6_configmap
  delete_existing_testruns
  start_background_watchers
  create_k6_test_run
  wait_for_test_pod_ready
  wait_for_test_completion
  fetch_test_logs
  stop_background_watchers
}

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

install_k6_operator() {
  echo "📦 Installing k6 operator..."
  curl -L "https://raw.githubusercontent.com/grafana/k6-operator/refs/tags/${K6_OPERATOR_VERSION}/bundle.yaml" | kubectl apply -f -
  echo "⏳ Waiting until k6 operator deployment is ready..."
  kubectl rollout status deployment/k6-operator-controller-manager -n k6-operator-system --timeout=300s
}

create_namespace() {
  echo "🔧 Creating namespace: $NAMESPACE"
  oc new-project "$NAMESPACE" || echo "Namespace $NAMESPACE already exists"
}

create_rbac() {
  echo "🔐 Creating ServiceAccount and RBAC resources..."
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
}

create_k6_configmap() {
  echo "🧩 Creating ConfigMap from script file: $SCRIPT_FILE"
  kubectl create configmap "$CONFIGMAP_NAME" \
    --from-file=script.js="$SCRIPT_FILE" \
    --namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
}

delete_existing_testruns() {
  echo "🧹 Deleting any existing K6 TestRun resources in namespace: $NAMESPACE"
  kubectl delete testrun --all -n "$NAMESPACE" || true
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

create_k6_test_run() {
  echo "🚀 Creating K6 TestRun custom resource..."
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
      value: '${CREATE_AUTOMOUNT_RESOURCES}'
    - name: DWO_NAMESPACE
      value: '${DWO_NAMESPACE}'
    - name: SEPARATE_NAMESPACES
      value: '${SEPARATE_NAMESPACES}'
    - name: DEVWORKSPACE_LINK
      value: '${DEVWORKSPACE_LINK}'
    - name: MAX_VUS
      value: '${MAX_VUS}'
    - name: TEST_DURATION_IN_MINUTES
      value: '${TEST_DURATION_IN_MINUTES}'
    - name: DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS
      value: '${DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS}'
EOF
}

wait_for_test_pod_ready() {
  echo "⏳ Waiting for K6 test pod to be ready..."
  kubectl wait --for=condition=Ready pod -l "$K6_CR_LABEL" -n "$NAMESPACE" --timeout=120s
}

wait_for_test_completion() {
  echo "⏳ Waiting for k6 TestRun to finish (timeout:${TEST_DURATION_IN_MINUTES}m)"

  TIMEOUT=$(((TEST_DURATION_IN_MINUTES+1) * 60 ))
  INTERVAL=5    # seconds

  end=$((SECONDS + TIMEOUT))

  while true; do
    stage=$(kubectl get testrun "$K6_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stage}' 2>/dev/null)

    if [[ "$stage" == "finished" ]]; then
        echo "TestRun $K6_CR_NAME is finished."
        break
    fi

    if (( SECONDS >= end )); then
        echo "Timeout waiting for TestRun $CR_NAME to finish."
        exit 1
    fi

    sleep "$INTERVAL"
  done
}

fetch_test_logs() {
  K6_TEST_POD=$(kubectl get pod -l k6_cr=$K6_CR_NAME,runner=true -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
  echo "📜 Fetching logs from completed K6 test pod: $K6_TEST_POD"
  kubectl logs "$K6_TEST_POD" -n "$NAMESPACE"
}

# Execute
main "$@"
