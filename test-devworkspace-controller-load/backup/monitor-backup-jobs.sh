#!/usr/bin/env bash
set -euo pipefail

log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
log_warning() { echo -e "⚠️  $*" >&2; }

# Configuration
BACKUP_JOB_LABEL="controller.devfile.io/backup-job=true"
LOGS_DIR="${LOGS_DIR:-logs}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Background watcher process IDs
PID_BACKUP_WATCH=""

# Start watching backup Jobs across all namespaces
watch_backup_jobs() {
  local log_file="${LOGS_DIR}/${TIMESTAMP}_backup_jobs_watch.log"

  log_info "Starting backup Job watcher (logging to ${log_file})..."

  kubectl get jobs --watch --all-namespaces \
    -l "$BACKUP_JOB_LABEL" \
    >> "$log_file" 2>&1 &
  PID_BACKUP_WATCH=$!

  log_success "Backup Job watcher started (PID: $PID_BACKUP_WATCH)"
}

# Stop backup Job watchers
stop_backup_watchers() {
  if [[ -n "${PID_BACKUP_WATCH:-}" ]] && kill -0 "$PID_BACKUP_WATCH" 2>/dev/null; then
    log_info "Stopping backup Job watcher (PID: $PID_BACKUP_WATCH)..."
    kill "$PID_BACKUP_WATCH" 2>/dev/null || true
    wait "$PID_BACKUP_WATCH" 2>/dev/null || true
    log_success "Backup Job watcher stopped"
  fi
}

# Collect backup Job metrics (count by status)
collect_backup_job_metrics() {
  local report_file="${LOGS_DIR}/${TIMESTAMP}_backup_jobs_metrics.txt"

  log_info "Collecting backup Job metrics..."

  local total
  total=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" --no-headers 2>/dev/null | wc -l || echo "0")

  local succeeded
  succeeded=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" \
    -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l || echo "0")

  local failed
  failed=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" \
    -o jsonpath='{range .items[?(@.status.failed>=1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l || echo "0")

  local running
  running=$((total - succeeded - failed))

  # Write metrics to report file
  {
    echo "===================================="
    echo "Backup Job Metrics"
    echo "Timestamp: $(date)"
    echo "===================================="
    echo ""
    echo "Total backup Jobs: $total"
    echo "Succeeded: $succeeded"
    echo "Failed: $failed"
    echo "Running/Pending: $running"
    echo ""
    if [[ $total -gt 0 ]]; then
      echo "Success rate: $(awk "BEGIN {printf \"%.2f%%\", ($succeeded/$total)*100}")"
      echo "Failure rate: $(awk "BEGIN {printf \"%.2f%%\", ($failed/$total)*100}")"
    fi
    echo ""
  } | tee "$report_file"

  log_success "Backup Job metrics collected: Total=$total, Succeeded=$succeeded, Failed=$failed"
}

# Get resource usage of backup Job pods
get_backup_job_resource_usage() {
  log_info "Collecting backup Job pod resource usage..."

  # Get all backup Job pods (pods created by backup Jobs)
  local pods
  pods=$(kubectl get pods -A -l "job-name" --no-headers 2>/dev/null | \
    awk '{print $2 " " $1}' || true)

  if [[ -z "$pods" ]]; then
    log_warning "No backup Job pods found for resource usage collection"
    return 0
  fi

  local cpu_total=0
  local memory_total=0
  local pod_count=0

  while read -r pod_name namespace; do
    # Check if this pod belongs to a backup Job
    local job_name
    job_name=$(kubectl get pod "$pod_name" -n "$namespace" \
      -o jsonpath='{.metadata.labels.job-name}' 2>/dev/null || true)

    if [[ -z "$job_name" ]]; then
      continue
    fi

    # Check if the Job has backup label
    local is_backup_job
    is_backup_job=$(kubectl get job "$job_name" -n "$namespace" \
      -l "$BACKUP_JOB_LABEL" --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "$is_backup_job" == "0" ]]; then
      continue
    fi

    # Get pod metrics
    local cpu
    cpu=$(kubectl top pod "$pod_name" -n "$namespace" --no-headers 2>/dev/null | \
      awk '{print $2}' | sed 's/m//g' || echo "0")

    local memory
    memory=$(kubectl top pod "$pod_name" -n "$namespace" --no-headers 2>/dev/null | \
      awk '{print $3}' | sed 's/Mi//g' || echo "0")

    if [[ "$cpu" =~ ^[0-9]+$ ]] && [[ "$memory" =~ ^[0-9]+$ ]]; then
      cpu_total=$((cpu_total + cpu))
      memory_total=$((memory_total + memory))
      pod_count=$((pod_count + 1))
    fi
  done <<< "$pods"

  if [[ $pod_count -gt 0 ]]; then
    local avg_cpu
    avg_cpu=$((cpu_total / pod_count))
    local avg_memory
    avg_memory=$((memory_total / pod_count))

    log_info "Backup Job pods resource usage: $pod_count pods, Avg CPU: ${avg_cpu}m, Avg Memory: ${avg_memory}Mi"
  else
    log_warning "No backup Job pod metrics available"
  fi
}

# Log failed backup Jobs with details
log_backup_failures() {
  local failure_log="${LOGS_DIR}/${TIMESTAMP}_backup_jobs_failures.log"

  log_info "Logging failed backup Jobs..."

  local failed_jobs
  failed_jobs=$(kubectl get jobs -A -l "$BACKUP_JOB_LABEL" \
    -o jsonpath='{range .items[?(@.status.failed>=1)]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  if [[ -z "$failed_jobs" ]]; then
    log_info "No failed backup Jobs found"
    echo "No failed backup Jobs" > "$failure_log"
    return 0
  fi

  {
    echo "===================================="
    echo "Failed Backup Jobs"
    echo "Timestamp: $(date)"
    echo "===================================="
    echo ""
  } > "$failure_log"

  while read -r namespace job_name; do
    if [[ -z "$job_name" ]]; then
      continue
    fi

    echo "Job: $job_name (namespace: $namespace)" >> "$failure_log"

    # Get Job status
    kubectl get job "$job_name" -n "$namespace" -o yaml >> "$failure_log" 2>&1 || true

    # Get pod logs from failed Job
    local pod_name
    pod_name=$(kubectl get pods -n "$namespace" -l "job-name=$job_name" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$pod_name" ]]; then
      echo "" >> "$failure_log"
      echo "Pod logs for $pod_name:" >> "$failure_log"
      kubectl logs "$pod_name" -n "$namespace" --tail=50 >> "$failure_log" 2>&1 || true
    fi

    echo "" >> "$failure_log"
    echo "-----------------------------------" >> "$failure_log"
    echo "" >> "$failure_log"
  done <<< "$failed_jobs"

  local failure_count
  failure_count=$(echo "$failed_jobs" | grep -c . || echo "0")

  log_error "Found $failure_count failed backup Jobs (details in $failure_log)"
}

# Generate comprehensive backup report
generate_backup_report() {
  local report_file="${LOGS_DIR}/${TIMESTAMP}_backup_summary.txt"

  log_info "Generating comprehensive backup report..."

  {
    echo "========================================"
    echo "Backup Load Test Summary Report"
    echo "Timestamp: $(date)"
    echo "========================================"
    echo ""

    # Job counts
    collect_backup_job_metrics

    echo ""
    echo "========================================"
    echo "Resource Usage"
    echo "========================================"
    echo ""
    get_backup_job_resource_usage

    echo ""
    echo "========================================"
    echo "Failed Jobs Details"
    echo "========================================"
    echo ""
    log_backup_failures

    echo ""
    echo "========================================"
    echo "Detailed logs available in:"
    echo "  - ${LOGS_DIR}/${TIMESTAMP}_backup_jobs_watch.log"
    echo "  - ${LOGS_DIR}/${TIMESTAMP}_backup_jobs_metrics.txt"
    echo "  - ${LOGS_DIR}/${TIMESTAMP}_backup_jobs_failures.log"
    echo "========================================"
  } | tee "$report_file"

  log_success "Backup report generated: $report_file"
}

# Monitor backup Jobs for a specified duration
monitor_backup_jobs_for_duration() {
  local duration_minutes="${1:-30}"
  local poll_interval="${2:-30}"

  log_info "Monitoring backup Jobs for ${duration_minutes} minutes (polling every ${poll_interval}s)..."

  local end_time=$((SECONDS + duration_minutes * 60))

  while [[ $SECONDS -lt $end_time ]]; do
    collect_backup_job_metrics
    echo ""

    local remaining=$((end_time - SECONDS))
    log_info "Monitoring... ${remaining}s remaining"

    sleep "$poll_interval"
  done

  log_success "Monitoring period completed"
}

# If script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  watch        - Start background watcher for backup Jobs"
    echo "  stop         - Stop background watchers"
    echo "  metrics      - Collect current backup Job metrics"
    echo "  failures     - Log failed backup Jobs"
    echo "  resources    - Get resource usage of backup Job pods"
    echo "  report       - Generate comprehensive backup report"
    echo "  monitor <minutes> [interval] - Monitor for duration"
    echo ""
    echo "Examples:"
    echo "  $0 watch"
    echo "  $0 metrics"
    echo "  $0 monitor 30 60"
    exit 1
  fi

  command="$1"
  shift

  case "$command" in
    watch)
      watch_backup_jobs
      ;;
    stop)
      stop_backup_watchers
      ;;
    metrics)
      collect_backup_job_metrics
      ;;
    failures)
      log_backup_failures
      ;;
    resources)
      get_backup_job_resource_usage
      ;;
    report)
      generate_backup_report
      ;;
    monitor)
      duration="${1:-30}"
      interval="${2:-30}"
      watch_backup_jobs
      trap stop_backup_watchers EXIT
      monitor_backup_jobs_for_duration "$duration" "$interval"
      generate_backup_report
      ;;
    *)
      log_error "Unknown command: $command"
      exit 1
      ;;
  esac
fi
