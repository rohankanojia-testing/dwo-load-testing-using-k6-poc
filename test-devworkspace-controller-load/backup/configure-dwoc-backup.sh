#!/usr/bin/env bash
set -euo pipefail

log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
log_warning() { echo -e "⚠️  $*" >&2; }

# Configuration
DWO_CONFIG_NAME="${DWO_CONFIG_NAME:-devworkspace-operator-config}"
DWO_NAMESPACE="${DWO_NAMESPACE:-openshift-operators}"

# Source the setup-backup-secret.sh script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/setup-backup-secret.sh"

# Create registry secret in operator namespace if it doesn't exist
create_registry_secret_if_needed() {
  local registry_secret="$1"
  local registry_path="$2"

  # Extract registry server from path (e.g., quay.io from quay.io/username)
  local registry_server
  registry_server=$(echo "$registry_path" | cut -d'/' -f1)

  # Use the existing setup_backup_registry_secret function
  setup_backup_registry_secret "$registry_secret" "$DWO_NAMESPACE" "$registry_server"
}

# Apply correct DWOC configuration for backup testing (external registry)
apply_correct_dwoc_config() {
  local registry_path="$1"
  local registry_secret="$2"
  local backup_schedule="${3:-*/2 * * * *}"

  log_info "Applying correct DWOC backup configuration (external registry)..."
  log_info "Registry path: ${registry_path}"
  log_info "Registry secret: ${registry_secret}"
  log_info "Backup schedule: ${backup_schedule}"

  # Ensure registry secret exists in operator namespace
  create_registry_secret_if_needed "$registry_secret" "$registry_path"

  if kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" >/dev/null 2>&1; then
    # Config exists, patch it
    log_info "DevWorkspaceOperatorConfig exists, patching..."
    kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type merge --patch "$(cat <<EOF
{
  "config": {
    "workspace": {
      "backupCronJob": {
        "enable": true,
        "schedule": "${backup_schedule}",
        "registry": {
          "authSecret": "${registry_secret}",
          "path": "${registry_path}"
        }
      }
    }
  }
}
EOF
)"
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
      schedule: '${backup_schedule}'
      registry:
        authSecret: ${registry_secret}
        path: ${registry_path}
EOF
  fi

  log_success "Correct DWOC backup configuration applied (external registry)"
}

# Apply DWOC configuration for OpenShift internal registry
apply_openshift_internal_dwoc_config() {
  local registry_path="${1:-}"
  local backup_schedule="${2:-*/2 * * * *}"

  # Auto-detect OpenShift internal registry if not provided
  if [[ -z "$registry_path" ]]; then
    log_info "Auto-detecting OpenShift internal registry route..."

    # Try to get the external route first
    registry_path=$(kubectl get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)

    if [[ -z "$registry_path" ]]; then
      # Fall back to internal service
      log_info "External route not found, using internal service"
      registry_path="image-registry.openshift-image-registry.svc:5000"
    else
      log_info "Found external route: ${registry_path}"
    fi
  fi

  log_info "Applying DWOC backup configuration (OpenShift internal registry)..."
  log_info "Registry path: ${registry_path}"
  log_info "Backup schedule: ${backup_schedule}"
  log_info "Auth: Using service account token (no secret required)"

  if kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" >/dev/null 2>&1; then
    # Config exists, patch it
    log_info "DevWorkspaceOperatorConfig exists, patching..."
    kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type merge --patch "$(cat <<EOF
{
  "config": {
    "routing": {
      "defaultRoutingClass": "basic"
    },
    "workspace": {
      "backupCronJob": {
        "enable": true,
        "schedule": "${backup_schedule}",
        "oras": {
          "extraArgs": "--insecure"
        },
        "registry": {
          "authSecret": null,
          "path": "${registry_path}"
        }
      }
    }
  }
}
EOF
)"
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
  routing:
    defaultRoutingClass: basic
  workspace:
    backupCronJob:
      enable: true
      schedule: '${backup_schedule}'
      oras:
        extraArgs: --insecure
      registry:
        path: ${registry_path}
EOF
  fi

  log_success "DWOC backup configuration applied (OpenShift internal registry)"
}

# Apply incorrect DWOC configuration (with typo in registry path)
apply_incorrect_dwoc_config() {
  local registry_path="$1"
  local registry_secret="$2"
  local backup_schedule="${3:-*/2 * * * *}"

  # Introduce typo in registry path (remove a character)
  local incorrect_path
  incorrect_path=$(echo "$registry_path" | sed 's/quay\.io/quay.i/')

  log_info "Applying INCORRECT DWOC backup configuration (typo in registry path)..."
  log_info "Original registry path: ${registry_path}"
  log_info "Incorrect registry path: ${incorrect_path}"
  log_info "Registry secret: ${registry_secret}"
  log_info "Backup schedule: ${backup_schedule}"

  # Ensure registry secret exists in operator namespace (use original path for secret creation)
  create_registry_secret_if_needed "$registry_secret" "$registry_path"

  if kubectl get devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" >/dev/null 2>&1; then
    # Config exists, patch it
    log_info "DevWorkspaceOperatorConfig exists, patching with incorrect config..."
    kubectl patch devworkspaceoperatorconfig "$DWO_CONFIG_NAME" -n "$DWO_NAMESPACE" --type merge --patch "$(cat <<EOF
{
  "config": {
    "workspace": {
      "backupCronJob": {
        "enable": true,
        "schedule": "${backup_schedule}",
        "registry": {
          "authSecret": "${registry_secret}",
          "path": "${incorrect_path}"
        }
      }
    }
  }
}
EOF
)"
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
      schedule: '${backup_schedule}'
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
  local config_type="$1"  # "correct", "incorrect", or "openshift-internal"
  local registry_path="$2"
  local registry_secret="${3:-}"
  local backup_schedule="${4:-*/2 * * * *}"

  case "$config_type" in
    correct)
      apply_correct_dwoc_config "$registry_path" "$registry_secret" "$backup_schedule"
      ;;
    incorrect)
      apply_incorrect_dwoc_config "$registry_path" "$registry_secret" "$backup_schedule"
      ;;
    openshift-internal)
      apply_openshift_internal_dwoc_config "$registry_path" "$backup_schedule"
      ;;
    *)
      log_error "Unknown config type: $config_type (must be 'correct', 'incorrect', or 'openshift-internal')"
      return 1
      ;;
  esac

  validate_dwoc_applied
}

# If script is executed directly (not sourced), run with provided arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <correct|incorrect|openshift-internal|reset|validate> [registry_path] [registry_secret] [backup_schedule]"
    echo ""
    echo "Commands:"
    echo "  correct            - Apply correct DWOC backup configuration (external registry)"
    echo "  incorrect          - Apply incorrect DWOC backup configuration (typo in registry)"
    echo "  openshift-internal - Apply DWOC backup configuration for OpenShift internal registry"
    echo "  reset              - Disable backup in DWOC"
    echo "  validate           - Validate DWOC backup configuration"
    echo ""
    echo "Parameters:"
    echo "  registry_path      - Container registry path (auto-detected for openshift-internal if not provided)"
    echo "  registry_secret    - Kubernetes secret name for registry auth (not used for openshift-internal)"
    echo "  backup_schedule    - Cron schedule for backups (default: '*/2 * * * *' - every 2 minutes)"
    echo ""
    echo "Examples:"
    echo "  # External registry with default schedule (every 2 minutes)"
    echo "  $0 correct quay.io/username quay-push-secret"
    echo ""
    echo "  # External registry with custom schedule (every 5 minutes)"
    echo "  $0 correct quay.io/username quay-push-secret '*/5 * * * *'"
    echo ""
    echo "  # Incorrect config with custom schedule"
    echo "  $0 incorrect quay.io/username quay-push-secret '*/2 * * * *'"
    echo ""
    echo "  # OpenShift internal registry (auto-detects route, default schedule)"
    echo "  $0 openshift-internal"
    echo ""
    echo "  # OpenShift internal registry with custom path and schedule"
    echo "  $0 openshift-internal default-route-openshift-image-registry.apps-crc.testing '' '*/10 * * * *'"
    echo ""
    echo "  # Disable cron during test (use impossible date - Feb 31st)"
    echo "  $0 correct quay.io/username quay-push-secret '0 0 31 2 *'"
    echo ""
    echo "  # Utility commands"
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
      apply_correct_dwoc_config "$1" "$2" "${3:-*/2 * * * *}"
      validate_dwoc_applied
      ;;
    incorrect)
      if [[ $# -lt 2 ]]; then
        log_error "Missing arguments: registry_path and registry_secret required"
        exit 1
      fi
      apply_incorrect_dwoc_config "$1" "$2" "${3:-*/2 * * * *}"
      validate_dwoc_applied
      ;;
    openshift-internal)
      # Registry path and schedule are optional - will auto-detect/use default if not provided
      apply_openshift_internal_dwoc_config "${1:-}" "${2:-*/2 * * * *}"
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
