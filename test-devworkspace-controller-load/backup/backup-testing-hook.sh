#!/usr/bin/env bash
set -euo pipefail

# Source required scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/configure-dwoc-backup.sh"
source "${SCRIPT_DIR}/monitor-backup-jobs.sh"

log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
log_warning() { echo -e "⚠️  $*" >&2; }

# Stop all workspaces for backup testing
stop_all_workspaces() {
  local namespace="$1"
  local separate_namespaces="${2:-false}"

  log_info "Stopping all workspaces for backup testing..."

  local workspace_count=0

  if [[ "$separate_namespaces" == "true" ]]; then
    # Stop workspaces across all labeled namespaces
    log_info "Stopping workspaces in separate namespaces (label: load-test=test-type)..."

    local namespaces
    namespaces=$(kubectl get ns -l load-test=test-type -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

    if [[ -z "$namespaces" ]]; then
      log_warning "No namespaces found with label load-test=test-type"
      return 0
    fi

    for ns in $namespaces; do
      local dws
      dws=$(kubectl get dw -n "$ns" -o name 2>/dev/null || true)

      if [[ -n "$dws" ]]; then
        while read -r dw; do
          if [[ -n "$dw" ]]; then
            kubectl patch "$dw" -n "$ns" --type merge -p '{"spec":{"started":false}}' 2>/dev/null || true
            workspace_count=$((workspace_count + 1))
          fi
        done <<< "$dws"
      fi
    done
  else
    # Stop workspaces in single namespace
    log_info "Stopping workspaces in namespace: $namespace..."

    local dws
    dws=$(kubectl get dw -n "$namespace" -o name 2>/dev/null || true)

    if [[ -n "$dws" ]]; then
      while read -r dw; do
        if [[ -n "$dw" ]]; then
          kubectl patch "$dw" -n "$namespace" --type merge -p '{"spec":{"started":false}}' 2>/dev/null || true
          workspace_count=$((workspace_count + 1))
        fi
      done <<< "$dws"
    fi
  fi

  log_success "Stopped $workspace_count workspaces"

  # Wait for workspaces to actually stop
  log_info "Waiting for workspaces to stop (30 seconds)..."
  sleep 30
  log_success "Workspaces should now be stopped"
}

# Wait for backup Jobs to be created
wait_for_backup_jobs() {
  local max_wait_minutes="${1:-10}"
  local poll_interval="${2:-10}"

  log_info "Waiting for backup Jobs to be created (max ${max_wait_minutes} minutes)..."

  local end_time=$((SECONDS + max_wait_minutes * 60))
  local jobs_found=false

  while [[ $SECONDS -lt $end_time ]]; do
    local job_count
    job_count=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ $job_count -gt 0 ]]; then
      log_success "Found $job_count backup Jobs"
      jobs_found=true
      break
    fi

    local remaining=$((end_time - SECONDS))
    log_info "No backup Jobs yet... waiting (${remaining}s remaining)"
    sleep "$poll_interval"
  done

  if [[ "$jobs_found" == "false" ]]; then
    log_error "No backup Jobs created within ${max_wait_minutes} minutes"
    return 1
  fi

  return 0
}

# Wait for backup Jobs to complete or fail
wait_for_backup_jobs_completion() {
  local max_wait_minutes="${1:-30}"
  local poll_interval="${2:-30}"

  log_info "Waiting for backup Jobs to complete (max ${max_wait_minutes} minutes)..."

  local end_time=$((SECONDS + max_wait_minutes * 60))

  while [[ $SECONDS -lt $end_time ]]; do
    local total
    total=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ $total -eq 0 ]]; then
      log_warning "No backup Jobs found"
      break
    fi

    local completed
    completed=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" \
      -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l || echo "0")

    local failed
    failed=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" \
      -o jsonpath='{range .items[?(@.status.failed>=1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l || echo "0")

    local finished=$((completed + failed))

    log_info "Backup Jobs: Total=$total, Completed=$completed, Failed=$failed, Pending=$((total - finished))"

    # Check if all Jobs are finished
    if [[ $finished -ge $total ]]; then
      log_success "All backup Jobs have completed or failed"
      break
    fi

    collect_backup_job_metrics

    local remaining=$((end_time - SECONDS))
    log_info "Waiting for Jobs to complete... (${remaining}s remaining)"
    sleep "$poll_interval"
  done

  log_success "Backup Job completion monitoring finished"
}

# Main backup testing hook function
# Note: This is called AFTER load test completes, so DWOC is already configured
run_backup_testing_hook() {
  local namespace="$1"
  local dwoc_config_type="$2"
  local registry_path="$3"
  local registry_secret="$4"
  local separate_namespaces="${5:-false}"
  local backup_wait_minutes="${6:-30}"

  log_info "========================================"
  log_info "Starting Backup Testing Hook"
  log_info "========================================"
  log_info "Namespace: $namespace"
  log_info "DWOC Config Type: $dwoc_config_type"
  log_info "Registry Path: $registry_path"
  log_info "Registry Secret: $registry_secret"
  log_info "Separate Namespaces: $separate_namespaces"
  log_info "Backup Wait Time: ${backup_wait_minutes} minutes"
  log_info "========================================"
  echo ""

  # Step 1: Stop all workspaces
  log_info "Step 1: Stopping all workspaces..."
  stop_all_workspaces "$namespace" "$separate_namespaces"
  echo ""

  # Step 2: Validate DWOC configuration (already configured before load test)
  log_info "Step 2: Validating DWOC configuration (configured before load test)..."
  validate_dwoc_applied
  echo ""

  # Step 3: Start backup Job monitoring
  log_info "Step 3: Starting backup Job monitoring..."
  watch_backup_jobs
  trap stop_backup_watchers EXIT
  echo ""

  # Step 4: Wait for backup Jobs to be created
  log_info "Step 4: Waiting for backup Jobs to be created..."
  if ! wait_for_backup_jobs 10 10; then
    log_error "Backup Jobs were not created - backup may not be configured correctly"
    log_warning "Continuing anyway to collect any available data..."
  fi
  echo ""

  # Step 5: Monitor and wait for backup Jobs to complete
  log_info "Step 5: Monitoring backup Jobs until completion..."
  wait_for_backup_jobs_completion "$backup_wait_minutes" 30
  echo ""

  # Step 6: Collect final metrics
  log_info "Step 6: Collecting final backup metrics..."
  generate_backup_report
  echo ""

  # Step 7: Reset DWOC configuration
  log_info "Step 7: Resetting DWOC configuration..."
  reset_dwoc_config
  echo ""

  # Step 8: Stop watchers
  log_info "Step 8: Stopping backup watchers..."
  stop_backup_watchers
  trap - EXIT
  echo ""

  log_success "========================================"
  log_success "Backup Testing Hook Completed"
  log_success "========================================"
  echo ""
}

# If script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <namespace> <dwoc-config-type> <registry-path> <registry-secret> [separate-namespaces] [backup-wait-minutes]"
    echo ""
    echo "Arguments:"
    echo "  namespace            - Test namespace (or base namespace if using separate-namespaces)"
    echo "  dwoc-config-type     - 'correct' or 'incorrect'"
    echo "  registry-path        - Registry path for backup images (e.g., quay.io/username)"
    echo "  registry-secret      - Secret name for registry authentication"
    echo "  separate-namespaces  - 'true' or 'false' (default: false)"
    echo "  backup-wait-minutes  - How long to wait for backups (default: 30)"
    echo ""
    echo "Example:"
    echo "  $0 loadtest-devworkspaces correct quay.io/username quay-push-secret true 30"
    exit 1
  fi

  run_backup_testing_hook "$@"
fi
