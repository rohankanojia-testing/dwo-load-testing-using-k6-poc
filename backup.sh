#!/bin/bash
#
# backup.sh - Simple wrapper for backup load testing
#
# Usage:
#   ./backup.sh [MAX_DEVWORKSPACES] [BACKUP_MONITOR_DURATION] [LOAD_TEST_NAMESPACE] [DWO_NAMESPACE] [REGISTRY_PATH] [REGISTRY_SECRET] [DWOC_CONFIG_TYPE] [SEPARATE_NAMESPACE]
#
# Configuration:
#   Set QUAY_USERNAME environment variable to override the default quay.io username
#
# Examples:
#
#   # Basic usage (defaults: incorrect DWOC, single namespace)
#   ./backup.sh 15 30
#
#   # Single namespace + correct DWOC
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false
#
#   # Single namespace + incorrect DWOC (default)
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret incorrect false
#
#   # Separate namespaces + correct DWOC
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct true
#
#   # Separate namespaces + incorrect DWOC
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret incorrect true
#
#   # Full parameter specification
#   ./backup.sh 100 45 my-loadtest my-operator-ns quay.io/rokumar quay-push-secret correct true
#
#   # Using custom quay username
#   QUAY_USERNAME=myuser ./backup.sh 50 30
#

set -euo pipefail

# Default configuration
QUAY_USERNAME=${QUAY_USERNAME:-rokumar}

# Parse arguments
MAX_DEVWORKSPACES=${1:-15}
BACKUP_MONITOR_DURATION=${2:-30}
LOAD_TEST_NAMESPACE=${3:-loadtest-devworkspaces}
DWO_NAMESPACE=${4:-openshift-operators}
REGISTRY_PATH=${5:-quay.io/${QUAY_USERNAME}}
REGISTRY_SECRET=${6:-quay-push-secret}
DWOC_CONFIG_TYPE=${7:-incorrect}
SEPARATE_NAMESPACE=${8:-false}

exec make test_backup \
  MAX_DEVWORKSPACES="${MAX_DEVWORKSPACES}" \
  BACKUP_MONITOR_DURATION="${BACKUP_MONITOR_DURATION}" \
  LOAD_TEST_NAMESPACE="${LOAD_TEST_NAMESPACE}" \
  DWO_NAMESPACE="${DWO_NAMESPACE}" \
  REGISTRY_PATH="${REGISTRY_PATH}" \
  REGISTRY_SECRET="${REGISTRY_SECRET}" \
  DWOC_CONFIG_TYPE="${DWOC_CONFIG_TYPE}" \
  SEPARATE_NAMESPACE="${SEPARATE_NAMESPACE}"
