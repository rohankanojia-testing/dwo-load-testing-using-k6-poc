#!/usr/bin/env bash
set -euo pipefail

log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
log_warning() { echo -e "⚠️  $*" >&2; }

# Check if Eclipse Che is already installed
is_che_installed() {
  local che_count
  che_count=$(kubectl get checluster --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")

  if [[ "${che_count}" -gt 0 ]]; then
    return 0  # Che is installed
  else
    return 1  # Che is not installed
  fi
}

# Detect if running on CRC
is_crc_cluster() {
  # Check for CRC-specific indicators
  local console_url
  console_url=$(kubectl get console cluster -o jsonpath='{.status.consoleURL}' 2>/dev/null || echo "")

  if [[ "${console_url}" == *"crc.testing"* ]] || [[ "${console_url}" == *"apps-crc"* ]]; then
    return 0  # Is CRC
  fi

  # Check cluster domain
  local cluster_domain
  cluster_domain=$(kubectl get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")

  if [[ "${cluster_domain}" == *"crc.testing"* ]] || [[ "${cluster_domain}" == *"apps-crc"* ]]; then
    return 0  # Is CRC
  fi

  return 1  # Not CRC
}

# Detect if running on OpenShift
is_openshift_cluster() {
  if kubectl api-resources --api-group=route.openshift.io >/dev/null 2>&1; then
    return 0  # Is OpenShift
  else
    return 1  # Not OpenShift
  fi
}

# Detect platform for chectl deployment
detect_deployment_platform() {
  if is_openshift_cluster; then
    if is_crc_cluster; then
      echo "crc"
    else
      echo "openshift"
    fi
  else
    echo "k8s"
  fi
}

# Check if chectl is installed
check_chectl_installed() {
  if ! command -v chectl &>/dev/null; then
    log_error "chectl is not installed"
    log_info "Install chectl from: https://github.com/che-incubator/chectl"
    log_info ""
    log_info "Installation options:"
    log_info "  npm install -g chectl"
    log_info "  OR"
    log_info "  bash <(curl -sL https://che-incubator.github.io/chectl/install.sh)"
    return 1
  fi

  local chectl_version
  chectl_version=$(chectl --version 2>/dev/null || echo "unknown")
  log_info "Found chectl version: ${chectl_version}"
  return 0
}

# Install Eclipse Che using chectl
install_che() {
  local platform="$1"

  log_info "Installing Eclipse Che on platform: ${platform}"

  case "${platform}" in
    crc)
      log_info "Deploying Eclipse Che for CRC..."
      chectl server:deploy --platform crc --installer operator
      ;;
    openshift)
      log_info "Deploying Eclipse Che for OpenShift..."
      chectl server:deploy --platform openshift --installer operator
      ;;
    k8s)
      log_info "Deploying Eclipse Che for Kubernetes..."
      chectl server:deploy --platform k8s --installer operator
      ;;
    *)
      log_error "Unknown platform: ${platform}"
      return 1
      ;;
  esac

  log_success "Eclipse Che deployment initiated"
}

# Wait for Che to be ready
wait_for_che_ready() {
  log_info "Waiting for Eclipse Che to be ready..."

  local max_wait=600  # 10 minutes
  local elapsed=0
  local poll_interval=10

  while [[ ${elapsed} -lt ${max_wait} ]]; do
    local che_ready
    che_ready=$(kubectl get checluster --all-namespaces -o jsonpath='{.items[0].status.chePhase}' 2>/dev/null || echo "")

    if [[ "${che_ready}" == "Active" ]]; then
      log_success "Eclipse Che is ready"
      return 0
    fi

    log_info "Che status: ${che_ready:-Unknown}. Waiting... (${elapsed}s/${max_wait}s)"
    sleep ${poll_interval}
    elapsed=$((elapsed + poll_interval))
  done

  log_error "Eclipse Che did not become ready within ${max_wait} seconds"
  return 1
}

# Main function
install_che_if_needed() {
  log_info "Checking Eclipse Che installation status..."

  if is_che_installed; then
    local che_ns
    che_ns=$(kubectl get checluster --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "unknown")
    local che_name
    che_name=$(kubectl get checluster --all-namespaces -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "unknown")
    local che_phase
    che_phase=$(kubectl get checluster --all-namespaces -o jsonpath='{.items[0].status.chePhase}' 2>/dev/null || echo "unknown")

    log_success "Eclipse Che is already installed"
    log_info "  Namespace: ${che_ns}"
    log_info "  Name: ${che_name}"
    log_info "  Status: ${che_phase}"
    return 0
  fi

  log_warning "Eclipse Che is not installed. Installing..."

  # Check for chectl
  if ! check_chectl_installed; then
    return 1
  fi

  # Detect platform
  local platform
  platform=$(detect_deployment_platform)
  log_info "Detected platform: ${platform}"

  # Install Che
  if ! install_che "${platform}"; then
    log_error "Failed to install Eclipse Che"
    return 1
  fi

  # Wait for Che to be ready
  if ! wait_for_che_ready; then
    log_error "Eclipse Che installation failed or timed out"
    return 1
  fi

  log_success "Eclipse Che installation completed successfully"
  return 0
}

# If script is executed directly (not sourced), run main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_che_if_needed
fi
