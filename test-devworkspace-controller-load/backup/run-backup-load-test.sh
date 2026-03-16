#!/bin/bash
#
# run-backup-load-test.sh
#
# Runs backup load testing with k6 to monitor backup jobs, stop workspaces,
# and measure etcd/operator memory usage during backup operations.
#
# Prerequisites:
# 1. DevWorkspaces must already exist (run a load test first)
# 2. DWOC must be configured for backup (run configure-dwoc-backup.sh first)
# 3. Registry secret must be configured
#
# Usage:
#   ./run-backup-load-test.sh [options]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default configuration
MODE="binary"  # or 'operator'
LOAD_TEST_NAMESPACE="loadtest-devworkspaces"
DWO_NAMESPACE="openshift-operators"
DWOC_CONFIG_TYPE="correct"  # "correct", "incorrect", or "openshift-internal"
SA_NAME="k6-backup-tester"
CLUSTERROLE_NAME="k6-backup-role"
ROLEBINDING_NAME="k6-backup-binding"
K6_SCRIPT="test-devworkspace-controller-load/backup/backup_load_test.js"
SEPARATE_NAMESPACES="false"
BACKUP_MONITOR_DURATION_MINUTES="30"
MIN_KUBECTL_VERSION="1.24.0"
MIN_K6_VERSION="1.1.0"

# Logging functions
log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
log_warning() { echo -e "⚠️  $*" >&2; }

# ----------- Helper Functions -----------

print_help() {
  cat <<EOF
Usage: $0 [options]

This script runs k6-based backup load testing to monitor backup jobs,
stop workspaces, and measure system metrics during backup operations.

Prerequisites:
  1. DevWorkspaces must already exist (run a load test first)
  2. DWOC must be configured for backup (see configure-dwoc-backup.sh)
  3. Registry secret must be configured

Options:
  --mode <operator|binary>                Mode to run the script (default: binary)
  --namespace <string>                    Namespace where DevWorkspaces exist (default: loadtest-devworkspaces)
  --dwo-namespace <string>                DevWorkspace Operator namespace (default: openshift-operators)
  --dwoc-config-type <string>             DWOC config type: correct, incorrect, or openshift-internal (default: correct)
  --separate-namespaces <true|false>      DevWorkspaces in separate namespaces (default: false)
  --backup-monitor-duration <minutes>     How long to monitor backups (default: 30)
  -h, --help                              Show this help message

Examples:
  # Basic usage (monitor backups for 30 minutes)
  $0

  # Monitor for 60 minutes
  $0 --backup-monitor-duration 60

  # Monitor workspaces in separate namespaces
  $0 --separate-namespaces true --backup-monitor-duration 45

Environment Variables:
  KUBE_API      - Kubernetes API server URL (auto-detected if not set)
  KUBE_TOKEN    - Kubernetes authentication token (auto-generated if not set)

EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="$2"; shift 2;;
      --namespace)
        LOAD_TEST_NAMESPACE="$2"; shift 2;;
      --dwo-namespace)
        DWO_NAMESPACE="$2"; shift 2;;
      --dwoc-config-type)
        DWOC_CONFIG_TYPE="$2"; shift 2;;
      --separate-namespaces)
        SEPARATE_NAMESPACES="$2"; shift 2;;
      --backup-monitor-duration)
        BACKUP_MONITOR_DURATION_MINUTES="$2"; shift 2;;
      -h|--help)
        print_help; exit 0;;
      *)
        log_error "Unknown option: $1"
        print_help; exit 1;;
    esac
  done
}

check_prerequisites() {
  log_info "Checking prerequisites..."

  check_command "kubectl" "$MIN_KUBECTL_VERSION"

  if [[ "$MODE" == "binary" ]]; then
    check_command "k6" "$MIN_K6_VERSION"
  fi

  # Check if namespace exists
  if ! kubectl get namespace "$LOAD_TEST_NAMESPACE" >/dev/null 2>&1; then
    log_error "Namespace '$LOAD_TEST_NAMESPACE' not found"
    log_info "Please run a load test first to create DevWorkspaces"
    exit 1
  fi

  # Check if DevWorkspaces exist
  local dw_count
  if [[ "$SEPARATE_NAMESPACES" == "true" ]]; then
    dw_count=$(kubectl get dw --all-namespaces -l load-test=test-type --no-headers 2>/dev/null | wc -l || echo "0")
  else
    dw_count=$(kubectl get dw -n "$LOAD_TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
  fi

  if [[ "$dw_count" -eq 0 ]]; then
    log_error "No DevWorkspaces found"
    log_info "Please run a load test first to create DevWorkspaces"
    exit 1
  fi

  log_success "Found $dw_count DevWorkspaces"
}

check_command() {
  local cmd="$1"
  local min_version="$2"
  local version

  if ! command -v "$cmd" &>/dev/null; then
    log_error "Required command '$cmd' not found in PATH."
    exit 1
  fi

  case "$cmd" in
    kubectl)
      version=$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion' | sed 's/^v//')
      ;;
    k6)
      version=$($cmd version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    *)
      version="0.0.0"
      ;;
  esac

  if ! version_gte "$version" "$min_version"; then
    log_error "$cmd version $version is less than required $min_version"
    exit 1
  else
    log_success "$cmd version $version (>= $min_version)"
  fi
}

version_gte() {
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

create_rbac() {
  log_info "Creating ServiceAccount and RBAC..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${LOAD_TEST_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTERROLE_NAME}
rules:
  - apiGroups: ["workspace.devfile.io"]
    resources: ["devworkspaces"]
    verbs: ["get", "list", "watch", "patch"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: ["image.openshift.io"]
    resources: ["imagestreams", "imagestreamtags"]
    verbs: ["get", "list", "watch"]
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
    namespace: ${LOAD_TEST_NAMESPACE}
EOF
}

cleanup_rbac() {
  log_info "Cleaning up RBAC resources..."
  kubectl delete clusterrolebinding "${ROLEBINDING_NAME}" --ignore-not-found
  kubectl delete clusterrole "${CLUSTERROLE_NAME}" --ignore-not-found
  kubectl delete serviceaccount "${SA_NAME}" -n "${LOAD_TEST_NAMESPACE}" --ignore-not-found
}

cleanup_devworkspaces() {
  log_info "Cleaning up DevWorkspaces..."

  if [[ "$SEPARATE_NAMESPACES" == "true" ]]; then
    # Get all DevWorkspaces across all namespaces with load-test label
    local dw_count
    dw_count=$(kubectl get dw --all-namespaces -l load-test=test-type --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "$dw_count" -gt 0 ]]; then
      log_info "Deleting ${dw_count} DevWorkspaces across separate namespaces..."
      kubectl delete dw --all-namespaces -l load-test=test-type --ignore-not-found --wait=false
    else
      log_info "No DevWorkspaces found to delete"
    fi
  else
    # Delete all DevWorkspaces in the load test namespace
    local dw_count
    dw_count=$(kubectl get dw -n "$LOAD_TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "$dw_count" -gt 0 ]]; then
      kubectl delete dw --all -n "${LOAD_TEST_NAMESPACE}" --ignore-not-found --wait=false
    else
      log_info "No DevWorkspaces found to delete"
    fi
  fi
}

delete_namespace() {
  log_info "Deleting namespace: ${LOAD_TEST_NAMESPACE}"
  kubectl delete namespace "${LOAD_TEST_NAMESPACE}" --ignore-not-found --wait=false
}

generate_token_and_api_url() {
  log_info "Generating token..."
  KUBE_TOKEN=$(kubectl create token "${SA_NAME}" -n "${LOAD_TEST_NAMESPACE}")

  log_info "Getting Kubernetes API server URL..."
  KUBE_API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
}

start_background_watchers() {
  # Background watchers removed - k6 handles all monitoring and metrics
  log_info "Monitoring will be handled by k6 metrics"
}

stop_background_watchers() {
  # Background watchers removed - k6 handles all monitoring and metrics
  return 0
}

run_k6_binary_test() {
  log_info "Running k6 backup load test..."

  if IN_CLUSTER='false' \
    KUBE_TOKEN="${KUBE_TOKEN}" \
    KUBE_API="${KUBE_API}" \
    DWO_NAMESPACE="${DWO_NAMESPACE}" \
    DWOC_CONFIG_TYPE="${DWOC_CONFIG_TYPE}" \
    SEPARATE_NAMESPACES="${SEPARATE_NAMESPACES}" \
    LOAD_TEST_NAMESPACE="${LOAD_TEST_NAMESPACE}" \
    BACKUP_MONITOR_DURATION_MINUTES="${BACKUP_MONITOR_DURATION_MINUTES}" \
    k6 run "${K6_SCRIPT}"; then
    log_success "k6 backup load test completed successfully"
    return 0
  else
    log_error "k6 backup load test failed (exit code $?)"
    return 1
  fi
}

# ----------- Main Execution Flow -----------

main() {
  parse_arguments "$@"
  check_prerequisites

  log_info "========================================"
  log_info "Backup Load Test Configuration"
  log_info "========================================"
  log_info "Mode: $MODE"
  log_info "Namespace: $LOAD_TEST_NAMESPACE"
  log_info "Operator Namespace: $DWO_NAMESPACE"
  log_info "DWOC Config Type: $DWOC_CONFIG_TYPE"
  log_info "Separate Namespaces: $SEPARATE_NAMESPACES"
  log_info "Monitor Duration: $BACKUP_MONITOR_DURATION_MINUTES minutes"
  log_info "========================================"
  echo ""

  create_rbac
  start_background_watchers

  local test_exit_code=0
  if [[ "$MODE" == "binary" ]]; then
    generate_token_and_api_url
    run_k6_binary_test || test_exit_code=$?
  else
    log_error "Operator mode not yet implemented for backup load testing"
    exit 1
  fi

  stop_background_watchers

  log_info "========================================"
  log_info "Cleanup"
  log_info "========================================"
  cleanup_devworkspaces
  delete_namespace
  cleanup_rbac
  log_success "Cleanup completed"
  echo ""

  # Exit with the test exit code (0 if successful, non-zero if failed)
  exit $test_exit_code
}

main "$@"
