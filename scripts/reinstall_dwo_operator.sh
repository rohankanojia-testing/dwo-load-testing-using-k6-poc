#!/bin/bash

# ============================================================================
# DevWorkspace Operator Reinstallation Script
# ============================================================================
#
# This script reinstalls the DevWorkspace Operator (DWO) using the testing
# catalog source. It performs the following steps:
# 1. Uninstalls the current operator subscription
# 2. Applies/verifies the testing CatalogSource
# 3. Creates a new Subscription with manual approval
# 4. Waits for and approves the install plan
# 5. Waits for operator rollout
# 6. Verifies running workspaces
#
# USAGE:
#   ./scripts/reinstall_dwo_operator.sh
#
# ENVIRONMENT VARIABLES:
#   CATALOG_SOURCE_NAME     - Name of the catalog source (default: devworkspace-operator-testing-catalog)
#   CATALOG_NAMESPACE       - Namespace for catalog source (default: openshift-marketplace)
#   OPERATOR_NAMESPACE      - Namespace for operator (default: openshift-operators)
#   SUBSCRIPTION_CHANNEL    - Subscription channel (default: fast)
#   ROLLOUT_TIMEOUT         - Timeout for rollout in seconds (default: 90)
#
# ============================================================================

set -e
set -o pipefail

# --- Configuration ---
CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-devworkspace-operator-testing-catalog}"
CATALOG_NAMESPACE="${CATALOG_NAMESPACE:-openshift-marketplace}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"
SUBSCRIPTION_CHANNEL="${SUBSCRIPTION_CHANNEL:-fast}"
SUBSCRIPTION_NAME="devworkspace-operator"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-90}"
INSTALL_PLAN_WAIT_TIMEOUT=300  # 5 minutes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Wait for install plan to be created
wait_for_installplan() {
    local namespace="$1"
    local label="$2"
    local elapsed=0
    local poll_interval=5

    log_info "Waiting for install plan to be created..."

    while [ $elapsed -lt $INSTALL_PLAN_WAIT_TIMEOUT ]; do
        local install_plan_count=$(oc get installplan -l "$label" -n "$namespace" --no-headers 2>/dev/null | wc -l | xargs)

        if [ "$install_plan_count" -gt 0 ]; then
            log_success "Install plan created after ${elapsed}s"
            return 0
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
        echo "  Waiting... (${elapsed}s)"
    done

    log_error "Install plan was not created within ${INSTALL_PLAN_WAIT_TIMEOUT}s"
    return 1
}

# --- Main Script ---
echo "========================================================"
echo "DevWorkspace Operator Reinstallation"
echo "========================================================"
echo "Started at: $(date)"
echo "Catalog Source: $CATALOG_SOURCE_NAME"
echo "Operator Namespace: $OPERATOR_NAMESPACE"
echo "--------------------------------------------------------"
echo ""

# Step 1: Uninstall current operator subscription
log_info "Step 1: Uninstalling current operator subscription..."
if oc get subscription "$SUBSCRIPTION_NAME" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    oc delete subscription "$SUBSCRIPTION_NAME" -n "$OPERATOR_NAMESPACE" --ignore-not-found=true
    log_success "Existing subscription deleted"
else
    log_warning "No existing subscription found (skipping)"
fi

# Also delete the CSV (ClusterServiceVersion) to ensure clean reinstall
log_info "Deleting existing ClusterServiceVersion..."
CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | grep devworkspace-operator || true)
if [ -n "$CSV_NAME" ]; then
    oc delete "$CSV_NAME" -n "$OPERATOR_NAMESPACE" --ignore-not-found=true
    log_success "Existing CSV deleted"
else
    log_warning "No existing CSV found (skipping)"
fi

echo ""

# Step 2: Verify/apply the testing CatalogSource
log_info "Step 2: Verifying CatalogSource '$CATALOG_SOURCE_NAME'..."
if oc get catalogsource "$CATALOG_SOURCE_NAME" -n "$CATALOG_NAMESPACE" >/dev/null 2>&1; then
    log_success "CatalogSource already exists"
    oc get catalogsource "$CATALOG_SOURCE_NAME" -n "$CATALOG_NAMESPACE"
else
    log_warning "CatalogSource not found!"
    log_error "Please ensure CatalogSource '$CATALOG_SOURCE_NAME' exists in namespace '$CATALOG_NAMESPACE'"
    echo ""
    echo "Available CatalogSources:"
    oc get catalogsource -n "$CATALOG_NAMESPACE"
    exit 1
fi

echo ""

# Step 3: Create new subscription
log_info "Step 3: Creating new operator subscription..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $SUBSCRIPTION_NAME
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: $SUBSCRIPTION_CHANNEL
  installPlanApproval: Manual
  name: $SUBSCRIPTION_NAME
  source: $CATALOG_SOURCE_NAME
  sourceNamespace: $CATALOG_NAMESPACE
EOF

log_success "DWO subscription created/updated to testing catalog"
echo ""

# Step 4: Wait for and approve install plan
log_info "Step 4: Waiting for install plan..."
wait_for_installplan "$OPERATOR_NAMESPACE" "operators.coreos.com/$SUBSCRIPTION_NAME.$OPERATOR_NAMESPACE"

echo ""
log_info "Current install plans:"
oc get installplans -n "$OPERATOR_NAMESPACE"
echo ""

INSTALL_PLAN_NAME=$(oc get installplan \
    -l "operators.coreos.com/$SUBSCRIPTION_NAME.$OPERATOR_NAMESPACE" \
    -n "$OPERATOR_NAMESPACE" \
    -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)

if [ -z "$INSTALL_PLAN_NAME" ]; then
    log_error "Failed to get install plan name"
    exit 1
fi

log_info "Approving install plan: $INSTALL_PLAN_NAME"
oc patch installplan "$INSTALL_PLAN_NAME" -n "$OPERATOR_NAMESPACE" --type merge -p '{"spec":{"approved":true}}'
log_success "DWO upgrade install plan approved"

echo ""
log_info "Install plans after approval:"
oc get installplan -n "$OPERATOR_NAMESPACE"
echo ""

# Give OLM time to process the approval
log_info "Waiting 15 seconds for OLM to process approval..."
sleep 15

# Step 5: Wait for operator rollout
log_info "Step 5: Waiting for operator deployments to roll out..."
echo ""

log_info "Waiting for devworkspace-controller-manager..."
if oc rollout status deployment devworkspace-controller-manager -n "$OPERATOR_NAMESPACE" --timeout "${ROLLOUT_TIMEOUT}s"; then
    log_success "devworkspace-controller-manager is ready"
else
    log_error "devworkspace-controller-manager rollout failed"
    exit 1
fi

echo ""
log_info "Waiting for devworkspace-webhook-server..."
if oc rollout status deployment devworkspace-webhook-server -n "$OPERATOR_NAMESPACE" --timeout "${ROLLOUT_TIMEOUT}s"; then
    log_success "devworkspace-webhook-server is ready"
else
    log_error "devworkspace-webhook-server rollout failed"
    exit 1
fi

log_success "DWO controllers are running after upgrade"
echo ""

# Step 6: Verify workspaces
log_info "Step 6: Verifying DevWorkspaces..."
DW_COUNT=$(oc get dw -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | wc -l | xargs)
if [ "$DW_COUNT" -gt 0 ]; then
    log_success "Found $DW_COUNT DevWorkspace(s) still running"
    oc get dw -n "$OPERATOR_NAMESPACE"
else
    log_info "No DevWorkspaces currently running (this is expected if cleanup was performed)"
fi

echo ""
echo "========================================================"
log_success "DevWorkspace Operator reinstallation complete!"
echo "========================================================"
echo "Completed at: $(date)"
echo ""
