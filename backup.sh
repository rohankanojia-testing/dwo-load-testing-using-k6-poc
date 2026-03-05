#!/bin/bash
#
# backup.sh - Simple wrapper for backup load testing
#
# Usage:
#   ./backup.sh [MAX_DEVWORKSPACES] [BACKUP_MONITOR_DURATION] [LOAD_TEST_NAMESPACE] [DWO_NAMESPACE] [REGISTRY_PATH] [REGISTRY_SECRET]
#
# Examples:
#   ./backup.sh 15 30
#   ./backup.sh 20 45 loadtest-devworkspaces openshift-operators quay.io/myuser my-secret
#

set -euo pipefail

MAX_DEVWORKSPACES=${1:-15}
BACKUP_MONITOR_DURATION=${2:-30}
LOAD_TEST_NAMESPACE=${3:-loadtest-devworkspaces}
DWO_NAMESPACE=${4:-openshift-operators}
REGISTRY_PATH=${5:-quay.io/rokumar}
REGISTRY_SECRET=${6:-quay-push-secret}

exec make test_backup \
  MAX_DEVWORKSPACES="${MAX_DEVWORKSPACES}" \
  BACKUP_MONITOR_DURATION="${BACKUP_MONITOR_DURATION}" \
  LOAD_TEST_NAMESPACE="${LOAD_TEST_NAMESPACE}" \
  DWO_NAMESPACE="${DWO_NAMESPACE}" \
  REGISTRY_PATH="${REGISTRY_PATH}" \
  REGISTRY_SECRET="${REGISTRY_SECRET}"
