#!/bin/bash
#
# backup-load-test.sh
#
# Complete backup load testing workflow:
# 1. Configure DWOC for backup
# 2. Create DevWorkspaces (skip cleanup)
# 3. Run backup monitoring
# 4. Cleanup all resources
#
# Usage: ./backup-load-test.sh <max_devworkspaces> <backup_monitor_duration> <namespace> <dwo_namespace> <registry_path> <registry_secret> <dwoc_config_type> <separate_namespaces> [backup_schedule]
# Example: ./backup-load-test.sh 15 30 loadtest-devworkspaces openshift-operators quay.io/rokumar quay-push-secret correct false "*/2 * * * *"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration from arguments
MAX_DEVWORKSPACES=${1:-15}
BACKUP_MONITOR_DURATION=${2:-30}
LOAD_TEST_NAMESPACE=${3:-loadtest-devworkspaces}
DWO_NAMESPACE=${4:-openshift-operators}
REGISTRY_PATH=${5:-quay.io/rokumar}
REGISTRY_SECRET=${6:-quay-push-secret}
DWOC_CONFIG_TYPE=${7:-correct}
SEPARATE_NAMESPACE=${8:-false}
BACKUP_SCHEDULE="${9:-*/2 * * * *}"

echo "========================================"
echo "Backup Load Testing"
echo "========================================"
echo "Max DevWorkspaces: $MAX_DEVWORKSPACES"
echo "Backup Monitor Duration: ${BACKUP_MONITOR_DURATION} minutes"
echo "Namespace: $LOAD_TEST_NAMESPACE"
echo "DWO Namespace: $DWO_NAMESPACE"
echo "Registry Path: $REGISTRY_PATH"
echo "Registry Secret: $REGISTRY_SECRET"
echo "DWOC Config Type: $DWOC_CONFIG_TYPE"
echo "Separate Namespaces: $SEPARATE_NAMESPACE"
echo "Backup Schedule: $BACKUP_SCHEDULE"
echo "========================================"
echo ""

# ============================================================================
# PHASE 1: CONFIGURE DWOC FOR BACKUP
# ============================================================================
echo "Phase 1: Configuring DWOC for Backup"
echo "========================================"

source "${SCRIPT_DIR}/configure-dwoc-backup.sh"
configure_dwoc_for_backup "$DWOC_CONFIG_TYPE" "$REGISTRY_PATH" "$REGISTRY_SECRET" "$BACKUP_SCHEDULE"
echo ""

# ============================================================================
# PHASE 2: CREATE DEVWORKSPACES
# ============================================================================
echo "Phase 2: Creating DevWorkspaces"
echo "========================================"

kubectl create namespace "$LOAD_TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Calculate VUs: for small counts use same as devworkspaces, otherwise use 1/4
MAX_VUS=$(( MAX_DEVWORKSPACES < 10 ? MAX_DEVWORKSPACES : MAX_DEVWORKSPACES / 4 ))
[[ $MAX_VUS -lt 1 ]] && MAX_VUS=1

SKIP_CLEANUP=true bash "${SCRIPT_DIR}/../runk6.sh" \
  --dwo-namespace "${LOAD_TEST_NAMESPACE}" \
  --max-devworkspaces "${MAX_DEVWORKSPACES}" \
  --max-vus "${MAX_VUS}" \
  --separate-namespaces "${SEPARATE_NAMESPACE}" \
  --delete-devworkspace-after-ready false \
  --devworkspace-link "https://gist.githubusercontent.com/rohanKanojia/fa3c9a5524d47e5ec2e064a41b93592c/raw/435161c64e6c2886788e8f947c239d76902d2dd9/dw-minimal-custom-dwoc.json" || true

# Verify DevWorkspaces created
if [[ "$SEPARATE_NAMESPACE" == "true" ]]; then
  DW_COUNT=$(kubectl get dw --all-namespaces -l load-test=test-type --no-headers 2>/dev/null | wc -l || echo "0")
else
  DW_COUNT=$(kubectl get dw -n "$LOAD_TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
fi

if [[ $DW_COUNT -eq 0 ]]; then
  echo "❌ No DevWorkspaces found!"
  exit 1
fi
echo "✅ Phase 2 Complete: $DW_COUNT DevWorkspaces created"
echo ""

# ============================================================================
# PHASE 3: BACKUP MONITORING
# ============================================================================
echo "Phase 3: Backup Monitoring"
echo "========================================"
sleep 10

bash "${SCRIPT_DIR}/run-backup-load-test.sh" \
  --mode binary \
  --namespace "${LOAD_TEST_NAMESPACE}" \
  --separate-namespaces "${SEPARATE_NAMESPACE}" \
  --backup-monitor-duration "${BACKUP_MONITOR_DURATION}" \
  --dwo-namespace "${DWO_NAMESPACE}" \
  --dwoc-config-type "${DWOC_CONFIG_TYPE}"

BACKUP_EXIT_CODE=$?
echo ""

# ============================================================================
# PHASE 4: CLEANUP
# ============================================================================
echo "Phase 4: Cleanup"
echo "========================================"

# Reset DWOC configuration
echo "ℹ️  Resetting DWOC backup configuration..."
kubectl patch devworkspaceoperatorconfig devworkspace-operator-config -n "${DWO_NAMESPACE}" \
  --type=merge \
  --patch='{"config":{"workspace":{"backupCronJob":{"enable":false}}}}' 2>/dev/null || true
echo "✅ DWOC backup disabled"
echo ""

# Note: DevWorkspaces, backup jobs, and namespace are cleaned up by run-backup-load-test.sh

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "========================================"
echo "Complete!"
echo "========================================"

[[ $BACKUP_EXIT_CODE -eq 0 ]] && echo "✅ Success!" || echo "⚠️  Warnings (exit: $BACKUP_EXIT_CODE)"

echo ""
echo "📊 Reports: devworkspace-load-test-report.html, backup-load-test-report.html"
echo ""

exit $BACKUP_EXIT_CODE
