#!/usr/bin/env bash
set -euo pipefail

# Main entry point for backup/restore load testing
# This script orchestrates all backup testing functionality:
# 1. Sets up registry secret (from QUAY_USERNAME/QUAY_PASSWORD env vars)
# 2. Validates configuration
# 3. Runs backup testing hook
#
# Called by runk6.sh after load test completes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/setup-backup-secret.sh"
source "${SCRIPT_DIR}/backup-testing-hook.sh"

log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
log_warning() { echo -e "⚠️  $*" >&2; }

# Default values
DEFAULT_SECRET_NAME="quay-push-secret"
DEFAULT_DWO_NAMESPACE="openshift-operators"
DEFAULT_BACKUP_WAIT_MINUTES="30"

# Main function to run backup tests
# Usage: run_backup_tests <namespace> <registry-path> [options]
# Note: DWOC should be configured BEFORE calling this function
run_backup_tests() {
  local namespace="$1"
  local registry_path="$2"
  local dwoc_config_type="${3:-correct}"
  local separate_namespaces="${4:-false}"
  local registry_secret="${5:-$DEFAULT_SECRET_NAME}"
  local dwo_namespace="${6:-$DEFAULT_DWO_NAMESPACE}"
  local backup_wait_minutes="${7:-$DEFAULT_BACKUP_WAIT_MINUTES}"

  echo ""
  echo "========================================"
  echo "Backup/Restore Load Testing"
  echo "========================================"
  log_info "Test Namespace: $namespace"
  log_info "Registry Path: $registry_path"
  log_info "DWOC Config Type: $dwoc_config_type"
  log_info "Separate Namespaces: $separate_namespaces"
  log_info "Registry Secret: $registry_secret"
  log_info "DWO Namespace: $dwo_namespace"
  log_info "Backup Wait Time: ${backup_wait_minutes} minutes"
  echo "========================================"
  echo ""

  # Step 1: Validate registry path
  if [[ -z "$registry_path" ]]; then
    log_error "Registry path is required"
    log_info "Example: quay.io/username"
    return 1
  fi

  # Step 2: Setup registry secret
  log_info "Step 1: Setting up registry secret..."
  echo ""

  if ! setup_backup_registry_secret "$registry_secret" "$dwo_namespace"; then
    log_error "Failed to setup registry secret"
    log_info ""
    log_info "Please ensure QUAY_USERNAME and QUAY_PASSWORD environment variables are set:"
    log_info "  export QUAY_USERNAME=your-username"
    log_info "  export QUAY_PASSWORD=your-password"
    log_info ""
    log_info "Or create the secret manually and re-run."
    return 1
  fi

  echo ""
  log_success "Registry secret setup complete"
  echo ""

  # Step 3: Validate secret
  log_info "Step 2: Validating registry secret..."
  if ! validate_backup_registry_secret "$registry_secret" "$dwo_namespace"; then
    log_error "Registry secret validation failed"
    return 1
  fi
  echo ""

  # Step 4: Run backup testing hook
  log_info "Step 3: Running backup testing hook..."
  echo ""

  run_backup_testing_hook \
    "$namespace" \
    "$dwoc_config_type" \
    "$registry_path" \
    "$registry_secret" \
    "$separate_namespaces" \
    "$backup_wait_minutes"

  echo ""
  log_success "========================================"
  log_success "Backup/Restore Load Testing Completed"
  log_success "========================================"
  echo ""

  return 0
}

# If script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <namespace> <registry-path> [dwoc-config-type] [separate-namespaces] [registry-secret] [dwo-namespace] [backup-wait-minutes]"
    echo ""
    echo "Required Arguments:"
    echo "  namespace            - Test namespace (or base namespace if using separate-namespaces)"
    echo "  registry-path        - Registry path for backup images (e.g., quay.io/username)"
    echo ""
    echo "Optional Arguments:"
    echo "  dwoc-config-type     - DWOC configuration type: 'correct' or 'incorrect' (default: correct)"
    echo "  separate-namespaces  - 'true' or 'false' (default: false)"
    echo "  registry-secret      - Registry secret name (default: quay-push-secret)"
    echo "  dwo-namespace        - DevWorkspace Operator namespace (default: openshift-operators)"
    echo "  backup-wait-minutes  - How long to wait for backups (default: 30)"
    echo ""
    echo "Environment Variables (required if secret doesn't exist):"
    echo "  QUAY_USERNAME - Registry username"
    echo "  QUAY_PASSWORD - Registry password"
    echo ""
    echo "Examples:"
    echo "  # Basic usage (with environment variables set)"
    echo "  export QUAY_USERNAME=myuser"
    echo "  export QUAY_PASSWORD=mypass"
    echo "  $0 loadtest-devworkspaces quay.io/myuser"
    echo ""
    echo "  # With all options"
    echo "  $0 loadtest-devworkspaces quay.io/myuser correct true quay-push-secret openshift-operators 30"
    echo ""
    echo "  # Test failure scenario"
    echo "  $0 loadtest-devworkspaces quay.io/myuser incorrect true"
    exit 1
  fi

  run_backup_tests "$@"
fi
