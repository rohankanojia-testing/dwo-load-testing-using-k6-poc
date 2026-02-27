#!/usr/bin/env bash
set -euo pipefail

log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
log_warning() { echo -e "⚠️  $*" >&2; }

# Default values
DEFAULT_SECRET_NAME="quay-push-secret"
DEFAULT_OPERATOR_NAMESPACE="openshift-operators"
DEFAULT_REGISTRY_SERVER="quay.io"

# Create or update registry secret for backup testing
# Uses environment variables: QUAY_USERNAME, QUAY_PASSWORD
setup_backup_registry_secret() {
  local secret_name="${1:-$DEFAULT_SECRET_NAME}"
  local namespace="${2:-$DEFAULT_OPERATOR_NAMESPACE}"
  local registry_server="${3:-$DEFAULT_REGISTRY_SERVER}"

  log_info "Setting up registry secret for backup testing..."
  log_info "Secret name: ${secret_name}"
  log_info "Namespace: ${namespace}"
  log_info "Registry server: ${registry_server}"

  # Check if secret already exists
  if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    log_info "Secret '${secret_name}' already exists in namespace '${namespace}'"

    # Verify it has the required label
    local has_label
    has_label=$(kubectl get secret "$secret_name" -n "$namespace" \
      -o jsonpath='{.metadata.labels.controller\.devfile\.io/watch-secret}' 2>/dev/null || echo "")

    if [[ "$has_label" != "true" ]]; then
      log_info "Adding required label to existing secret..."
      kubectl label secret "$secret_name" \
        controller.devfile.io/watch-secret=true \
        -n "$namespace" --overwrite
      log_success "Label added to existing secret"
    else
      log_success "Secret already has required label"
    fi

    return 0
  fi

  # Secret doesn't exist - check for environment variables
  if [[ -z "${QUAY_USERNAME:-}" ]] || [[ -z "${QUAY_PASSWORD:-}" ]]; then
    log_error "Secret '${secret_name}' does not exist and QUAY_USERNAME/QUAY_PASSWORD environment variables are not set"
    log_info ""
    log_info "To create the secret, either:"
    log_info "  1. Set environment variables:"
    log_info "     export QUAY_USERNAME=your-username"
    log_info "     export QUAY_PASSWORD=your-password"
    log_info ""
    log_info "  2. Or create the secret manually:"
    log_info "     kubectl create secret docker-registry ${secret_name} \\"
    log_info "       --docker-server=${registry_server} \\"
    log_info "       --docker-username=<your-username> \\"
    log_info "       --docker-password=<your-password> \\"
    log_info "       -n ${namespace}"
    log_info ""
    log_info "     kubectl label secret ${secret_name} \\"
    log_info "       controller.devfile.io/watch-secret=true \\"
    log_info "       -n ${namespace}"
    return 1
  fi

  # Create the secret from environment variables
  log_info "Creating registry secret from environment variables..."

  if ! kubectl create secret docker-registry "$secret_name" \
    --docker-server="$registry_server" \
    --docker-username="$QUAY_USERNAME" \
    --docker-password="$QUAY_PASSWORD" \
    -n "$namespace"; then
    log_error "Failed to create secret"
    return 1
  fi

  log_success "Secret created successfully"

  # Add the required label
  log_info "Adding required label to secret..."
  if ! kubectl label secret "$secret_name" \
    controller.devfile.io/watch-secret=true \
    -n "$namespace"; then
    log_error "Failed to label secret"
    return 1
  fi

  log_success "Secret labeled successfully"
  log_success "Registry secret setup complete!"

  return 0
}

# Validate that the secret exists and is properly configured
validate_backup_registry_secret() {
  local secret_name="${1:-$DEFAULT_SECRET_NAME}"
  local namespace="${2:-$DEFAULT_OPERATOR_NAMESPACE}"

  log_info "Validating registry secret..."

  # Check if secret exists
  if ! kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    log_error "Secret '${secret_name}' does not exist in namespace '${namespace}'"
    return 1
  fi

  # Check if secret has the required label
  local has_label
  has_label=$(kubectl get secret "$secret_name" -n "$namespace" \
    -o jsonpath='{.metadata.labels.controller\.devfile\.io/watch-secret}' 2>/dev/null || echo "")

  if [[ "$has_label" != "true" ]]; then
    log_error "Secret '${secret_name}' is missing required label: controller.devfile.io/watch-secret=true"
    return 1
  fi

  # Check if secret is a docker-registry type
  local secret_type
  secret_type=$(kubectl get secret "$secret_name" -n "$namespace" \
    -o jsonpath='{.type}' 2>/dev/null || echo "")

  if [[ "$secret_type" != "kubernetes.io/dockerconfigjson" ]]; then
    log_warning "Secret type is '${secret_type}', expected 'kubernetes.io/dockerconfigjson'"
  fi

  log_success "Registry secret validation passed"
  return 0
}

# Delete the registry secret (for cleanup)
delete_backup_registry_secret() {
  local secret_name="${1:-$DEFAULT_SECRET_NAME}"
  local namespace="${2:-$DEFAULT_OPERATOR_NAMESPACE}"

  log_info "Deleting registry secret..."

  if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    kubectl delete secret "$secret_name" -n "$namespace"
    log_success "Secret deleted"
  else
    log_info "Secret does not exist, nothing to delete"
  fi
}

# If script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <setup|validate|delete> [secret-name] [namespace] [registry-server]"
    echo ""
    echo "Commands:"
    echo "  setup    - Create or update registry secret (reads QUAY_USERNAME and QUAY_PASSWORD from env)"
    echo "  validate - Validate that secret exists and is properly configured"
    echo "  delete   - Delete the registry secret"
    echo ""
    echo "Environment Variables (for 'setup' command):"
    echo "  QUAY_USERNAME - Registry username (required if secret doesn't exist)"
    echo "  QUAY_PASSWORD - Registry password (required if secret doesn't exist)"
    echo ""
    echo "Examples:"
    echo "  # Setup with default values (quay-push-secret in openshift-operators)"
    echo "  export QUAY_USERNAME=myuser"
    echo "  export QUAY_PASSWORD=mypass"
    echo "  $0 setup"
    echo ""
    echo "  # Setup with custom values"
    echo "  $0 setup my-secret my-namespace docker.io"
    echo ""
    echo "  # Validate secret"
    echo "  $0 validate quay-push-secret openshift-operators"
    echo ""
    echo "  # Delete secret"
    echo "  $0 delete quay-push-secret openshift-operators"
    exit 1
  fi

  command="$1"
  shift

  case "$command" in
    setup)
      setup_backup_registry_secret "$@"
      ;;
    validate)
      validate_backup_registry_secret "$@"
      ;;
    delete)
      delete_backup_registry_secret "$@"
      ;;
    *)
      log_error "Unknown command: $command"
      exit 1
      ;;
  esac
fi
