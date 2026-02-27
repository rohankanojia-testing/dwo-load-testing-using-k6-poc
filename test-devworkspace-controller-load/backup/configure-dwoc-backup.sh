#!/usr/bin/env bash
set -euo pipefail

log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }

# Configuration
DWO_CONFIG_NAME="${DWO_CONFIG_NAME:-devworkspace-operator-config}"
DWO_NAMESPACE="${DWO_NAMESPACE:-openshift-operators}"

# Apply correct DWOC configuration for backup testing
apply_correct_dwoc_config() {
  local registry_path="$1"
  local registry_secret="$2"

  log_info "Applying correct DWOC backup configuration..."
  log_info "Registry path: ${registry_path}"
  log_info "Registry secret: ${registry_secret}"

  if kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" >/dev/null 2>&1; then
    # Config exists, patch it
    log_info "DevWorkspaceOperatorConfig exists, patching..."
    kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type merge -p "
config:
  workspace:
    backupCronJob:
      enable: true
      schedule: '*/1 * * * *'
      registry:
        authSecret: ${registry_secret}
        path: ${registry_path}
"
  else
    # Config doesn't exist, create it
    log_info "DevWorkspaceOperatorConfig not found, creating..."
    kubectl apply -f - <<EOF
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: $DWO_CONFIG_NAME
  namespace: $DWO_NAMESPACE
config:
  workspace:
    backupCronJob:
      enable: true
      schedule: '*/1 * * * *'
      registry:
        authSecret: ${registry_secret}
        path: ${registry_path}
EOF
  fi

  log_success "Correct DWOC backup configuration applied"
}

# Apply incorrect DWOC configuration (with typo in registry path)
apply_incorrect_dwoc_config() {
  local registry_path="$1"
  local registry_secret="$2"

  # Introduce typo in registry path (remove a character)
  local incorrect_path
  incorrect_path=$(echo "$registry_path" | sed 's/quay\.io/quay.i/')

  log_info "Applying INCORRECT DWOC backup configuration (typo in registry path)..."
  log_info "Original registry path: ${registry_path}"
  log_info "Incorrect registry path: ${incorrect_path}"
  log_info "Registry secret: ${registry_secret}"

  if kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" >/dev/null 2>&1; then
    # Config exists, patch it
    log_info "DevWorkspaceOperatorConfig exists, patching with incorrect config..."
    kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type merge -p "
config:
  workspace:
    backupCronJob:
      enable: true
      schedule: '*/1 * * * *'
      registry:
        authSecret: ${registry_secret}
        path: ${incorrect_path}
"
  else
    # Config doesn't exist, create it
    log_info "DevWorkspaceOperatorConfig not found, creating with incorrect config..."
    kubectl apply -f - <<EOF
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: $DWO_CONFIG_NAME
  namespace: $DWO_NAMESPACE
config:
  workspace:
    backupCronJob:
      enable: true
      schedule: '*/1 * * * *'
      registry:
        authSecret: ${registry_secret}
        path: ${incorrect_path}
EOF
  fi

  log_success "Incorrect DWOC backup configuration applied (this will cause backup failures)"
}

# Reset DWOC configuration (disable backup)
reset_dwoc_config() {
  log_info "Resetting DWOC backup configuration..."

  if kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" >/dev/null 2>&1; then
    log_info "Disabling backup in DevWorkspaceOperatorConfig..."
    kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type merge -p '
config:
  workspace:
    backupCronJob:
      enable: false
'
    log_success "DWOC backup configuration disabled"
  else
    log_info "DevWorkspaceOperatorConfig does not exist, nothing to reset"
  fi
}

# Validate DWOC configuration was applied
validate_dwoc_applied() {
  log_info "Validating DWOC configuration..."

  if ! kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" >/dev/null 2>&1; then
    log_error "DevWorkspaceOperatorConfig not found"
    return 1
  fi

  local backup_enabled
  backup_enabled=$(kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" \
    -o jsonpath='{.config.workspace.backupCronJob.enable}' 2>/dev/null || echo "false")

  if [[ "$backup_enabled" == "true" ]]; then
    log_success "DWOC backup is enabled"

    local registry_path
    registry_path=$(kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" \
      -o jsonpath='{.config.workspace.backupCronJob.registry.path}' 2>/dev/null || echo "")

    local auth_secret
    auth_secret=$(kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" \
      -o jsonpath='{.config.workspace.backupCronJob.registry.authSecret}' 2>/dev/null || echo "")

    log_info "Registry path: ${registry_path:-<not set>}"
    log_info "Auth secret: ${auth_secret:-<not set>}"

    return 0
  else
    log_error "DWOC backup is NOT enabled"
    return 1
  fi
}

# Main configuration function - called from backup testing hook
configure_dwoc_for_backup() {
  local config_type="$1"  # "correct" or "incorrect"
  local registry_path="$2"
  local registry_secret="$3"

  case "$config_type" in
    correct)
      apply_correct_dwoc_config "$registry_path" "$registry_secret"
      ;;
    incorrect)
      apply_incorrect_dwoc_config "$registry_path" "$registry_secret"
      ;;
    *)
      log_error "Unknown config type: $config_type (must be 'correct' or 'incorrect')"
      return 1
      ;;
  esac

  validate_dwoc_applied
}

# If script is executed directly (not sourced), run with provided arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <correct|incorrect|reset|validate> [registry_path] [registry_secret]"
    echo ""
    echo "Commands:"
    echo "  correct  - Apply correct DWOC backup configuration"
    echo "  incorrect - Apply incorrect DWOC backup configuration (typo in registry)"
    echo "  reset - Disable backup in DWOC"
    echo "  validate - Validate DWOC backup configuration"
    echo ""
    echo "Examples:"
    echo "  $0 correct quay.io/username quay-push-secret"
    echo "  $0 incorrect quay.io/username quay-push-secret"
    echo "  $0 reset"
    echo "  $0 validate"
    exit 1
  fi

  command="$1"
  shift

  case "$command" in
    correct)
      if [[ $# -lt 2 ]]; then
        log_error "Missing arguments: registry_path and registry_secret required"
        exit 1
      fi
      apply_correct_dwoc_config "$1" "$2"
      validate_dwoc_applied
      ;;
    incorrect)
      if [[ $# -lt 2 ]]; then
        log_error "Missing arguments: registry_path and registry_secret required"
        exit 1
      fi
      apply_incorrect_dwoc_config "$1" "$2"
      validate_dwoc_applied
      ;;
    reset)
      reset_dwoc_config
      ;;
    validate)
      validate_dwoc_applied
      ;;
    *)
      log_error "Unknown command: $command"
      exit 1
      ;;
  esac
fi
