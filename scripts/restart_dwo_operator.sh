#!/bin/bash

# ============================================================================
# DevWorkspace Operator Restart Script
# ============================================================================
#
# This script restarts the DevWorkspace Operator (DWO) deployments without
# reinstalling the subscription. This is useful for getting a fresh operator
# state between tests without changing the operator version.
#
# USAGE:
#   ./scripts/restart_dwo_operator.sh
#
# ENVIRONMENT VARIABLES:
#   OPERATOR_NAMESPACE      - Namespace for operator (default: openshift-operators)
#   ROLLOUT_TIMEOUT         - Timeout for rollout in seconds (default: 90)
#
# ============================================================================

set -e
set -o pipefail

# --- Configuration ---
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-90}"

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

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# --- Main Script ---
echo "========================================================"
echo "DevWorkspace Operator Restart"
echo "========================================================"
echo "Started at: $(date)"
echo "Operator Namespace: $OPERATOR_NAMESPACE"
echo "--------------------------------------------------------"
echo ""

# Step 1: Restart devworkspace-controller-manager
log_info "Restarting devworkspace-controller-manager..."
if oc rollout restart deployment devworkspace-controller-manager -n "$OPERATOR_NAMESPACE"; then
    log_success "Rollout restart triggered for devworkspace-controller-manager"
else
    log_error "Failed to restart devworkspace-controller-manager"
    exit 1
fi

echo ""

# Step 2: Restart devworkspace-webhook-server
log_info "Restarting devworkspace-webhook-server..."
if oc rollout restart deployment devworkspace-webhook-server -n "$OPERATOR_NAMESPACE"; then
    log_success "Rollout restart triggered for devworkspace-webhook-server"
else
    log_error "Failed to restart devworkspace-webhook-server"
    exit 1
fi

echo ""

# Step 3: Wait for rollouts to complete
log_info "Waiting for rollouts to complete..."
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

log_success "DWO controllers restarted successfully"
echo ""

# Step 4: Show deployment status
log_info "Current deployment status:"
oc get deployment -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/part-of=devworkspace-operator

echo ""
echo "========================================================"
log_success "DevWorkspace Operator restart complete!"
echo "========================================================"
echo "Completed at: $(date)"
echo ""
