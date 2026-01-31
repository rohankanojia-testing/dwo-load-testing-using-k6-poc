#!/usr/bin/env bash
set -euo pipefail

# Parse k6 output and convert metrics to CSV
#
# Usage: cat k6-output.txt | ./k6-output-to-csv.sh --target 1000 --namespace Single
#        echo "$K6_OUTPUT" | ./k6-output-to-csv.sh --target 1500 --namespace Separate

# Parse arguments
TARGET=""
NAMESPACE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$TARGET" || -z "$NAMESPACE" ]]; then
    echo "Error: --target and --namespace are required" >&2
    echo "Usage: $0 --target <number> --namespace <Single|Separate>" >&2
    exit 1
fi

# Read input
INPUT=$(cat)

# Extract just the avg value from a metric
extract_avg() {
    local metric_name="$1"
    echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$metric_name" | awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^avg=/) {
                print substr($i, 5)
                exit
            }
        }
        print "0"
    }'
}

# Extract counter values
extract_counter() {
    local counter_name="$1"
    echo "$INPUT" | grep -E "^\s*✓?\s*✗?\s*$counter_name" | awk '{
        # Look for the count value (first number before rate)
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9.]+\/s$/) {
                print $i
                exit
            }
        }
        print "0"
    }'
}

# Check if CSV file exists, if not create header
CSV_FILE="load_test_results.csv"

if [ ! -f "$CSV_FILE" ]; then
    echo "DevWorkspaces Created,DevWorkspace Ready,Ready Failed (%),Average CPU (milliCPU),Average Memory (MiB),Create Duration (Avg ms),Ready Duration (Avg ms),CPU Violations,Memory Violations,Average Etcd CPU (milliCPU),Average Etcd Memory (MiB),Namespace" > "$CSV_FILE"
fi

# Extract all metrics
DW_CREATE_COUNT=$(extract_counter "devworkspace_create_count")
DW_READY_COUNT=$(extract_counter "devworkspace_ready")
DW_READY_FAILED=$(extract_counter "devworkspace_ready_failed")

# Calculate Ready Failed percentage
if [ "$DW_CREATE_COUNT" -gt 0 ]; then
    READY_FAILED_PCT=$(awk "BEGIN {printf \"%.2f%%\", ($DW_READY_FAILED / $DW_CREATE_COUNT) * 100}")
else
    READY_FAILED_PCT="0.00%"
fi

# Extract operator metrics (avg values)
AVG_OP_CPU=$(extract_avg "average_operator_cpu")
AVG_OP_MEM=$(extract_avg "average_operator_memory")

# Extract durations (avg values)
AVG_CREATE_DUR=$(extract_avg "devworkspace_create_duration")
AVG_READY_DUR=$(extract_avg "devworkspace_ready_duration")

# Extract violations
OP_CPU_VIOL=$(extract_counter "operator_cpu_violations")
OP_MEM_VIOL=$(extract_counter "operator_mem_violations")

# Extract ETCD metrics (avg values)
AVG_ETCD_CPU=$(extract_avg "average_etcd_cpu")
AVG_ETCD_MEM=$(extract_avg "average_etcd_memory")

# Build CSV row
CSV_ROW="$DW_CREATE_COUNT,$DW_READY_COUNT,$READY_FAILED_PCT,$AVG_OP_CPU,$AVG_OP_MEM,$AVG_CREATE_DUR,$AVG_READY_DUR,$OP_CPU_VIOL,$OP_MEM_VIOL,$AVG_ETCD_CPU,$AVG_ETCD_MEM,$NAMESPACE"

# Append to CSV
echo "$CSV_ROW" >> "$CSV_FILE"

echo "Results appended to $CSV_FILE"
echo ""
echo "Summary:"
echo "  Namespace: $NAMESPACE"
echo "  DevWorkspaces Created: $DW_CREATE_COUNT"
echo "  DevWorkspace Ready: $DW_READY_COUNT"
echo "  Ready Failed: $DW_READY_FAILED ($READY_FAILED_PCT)"
echo "  Average Operator CPU: $AVG_OP_CPU milliCPU"
echo "  Average Operator Memory: $AVG_OP_MEM MiB"
echo "  Create Duration: $AVG_CREATE_DUR ms"
echo "  Ready Duration: $AVG_READY_DUR ms"
echo "  CPU Violations: $OP_CPU_VIOL"
echo "  Memory Violations: $OP_MEM_VIOL"
echo "  Average Etcd CPU: $AVG_ETCD_CPU milliCPU"
echo "  Average Etcd Memory: $AVG_ETCD_MEM MiB"
echo ""
echo "----------------------------------------"
echo "Current CSV contents:"
echo "----------------------------------------"
cat "$CSV_FILE"
