#!/bin/bash
#
# backup.sh - Simple wrapper for backup load testing
#
# Usage:
#   ./backup.sh [MAX_DEVWORKSPACES] [BACKUP_MONITOR_DURATION] [LOAD_TEST_NAMESPACE] [DWO_NAMESPACE] [REGISTRY_PATH] [REGISTRY_SECRET] [DWOC_CONFIG_TYPE] [SEPARATE_NAMESPACE] [BACKUP_SCHEDULE] [VERIFY_RESTORE] [MAX_RESTORE_SAMPLES]
#
# Configuration:
#   Set QUAY_USERNAME environment variable to override the default quay.io username
#
# Examples:
#
#   # Basic usage (defaults: correct DWOC, single namespace, external registry, every 2 min schedule, restore enabled)
#   ./backup.sh 15 30
#
#   # External registry - Single namespace + correct DWOC
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false
#
#   # External registry - Single namespace + incorrect DWOC (for failure testing)
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret incorrect false
#
#   # External registry - Separate namespaces + correct DWOC
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct true
#
#   # OpenShift internal registry - Auto-detect registry route
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators "" "" openshift-internal true
#
#   # OpenShift internal registry - Custom registry path
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators "default-route-openshift-image-registry.apps-crc.testing" "" openshift-internal true
#
#   # OpenShift internal registry - Incorrect config (failure testing)
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators "incorrect-route-openshift-image-registry.apps-crc.testing" "" openshift-internal false
#
#   # Custom backup schedule - every 5 minutes
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false "*/5 * * * *"
#
#   # Disable cron during test (Feb 31st never occurs)
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false "0 0 31 2 *"
#
#   # Using custom quay username
#   QUAY_USERNAME=myuser ./backup.sh 50 30
#
#   # With restore verification enabled (default)
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false "*/2 * * * *" true 10
#
#   # Skip restore verification (backup only)
#   ./backup.sh 50 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false "*/2 * * * *" false
#
#   # Restore all backed up workspaces (not just sample)
#   ./backup.sh 20 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false "*/2 * * * *" true 20
#

set -euo pipefail

# Default configuration
QUAY_USERNAME=${QUAY_USERNAME:-rokumar}

# Parse arguments
MAX_DEVWORKSPACES=${1:-15}
BACKUP_MONITOR_DURATION=${2:-30}
LOAD_TEST_NAMESPACE=${3:-loadtest-devworkspaces}
DWO_NAMESPACE=${4:-openshift-operators}
DWOC_CONFIG_TYPE=${7:-correct}
SEPARATE_NAMESPACE=${8:-false}
BACKUP_SCHEDULE="${9:-*/2 * * * *}"
VERIFY_RESTORE="${10:-true}"
MAX_RESTORE_SAMPLES="${11:-10}"

# Set registry defaults based on config type
if [[ "$DWOC_CONFIG_TYPE" == "openshift-internal" ]]; then
  # For OpenShift internal registry, leave path empty to trigger auto-detection
  REGISTRY_PATH="${5:-}"
  REGISTRY_SECRET="${6:-}"
else
  # For external registry, use quay.io defaults
  REGISTRY_PATH=${5:-quay.io/${QUAY_USERNAME}}
  REGISTRY_SECRET=${6:-quay-push-secret}
fi

exec make test_backup \
  MAX_DEVWORKSPACES="${MAX_DEVWORKSPACES}" \
  BACKUP_MONITOR_DURATION="${BACKUP_MONITOR_DURATION}" \
  LOAD_TEST_NAMESPACE="${LOAD_TEST_NAMESPACE}" \
  DWO_NAMESPACE="${DWO_NAMESPACE}" \
  REGISTRY_PATH="${REGISTRY_PATH}" \
  REGISTRY_SECRET="${REGISTRY_SECRET}" \
  DWOC_CONFIG_TYPE="${DWOC_CONFIG_TYPE}" \
  SEPARATE_NAMESPACE="${SEPARATE_NAMESPACE}" \
  BACKUP_SCHEDULE="${BACKUP_SCHEDULE}" \
  VERIFY_RESTORE="${VERIFY_RESTORE}" \
  MAX_RESTORE_SAMPLES="${MAX_RESTORE_SAMPLES}"
