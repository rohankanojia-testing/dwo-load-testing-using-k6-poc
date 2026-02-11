#!/bin/bash

# ============================================================================
# DevWorkspace Webhook Server Load Testing Suite Runner
# ============================================================================
#
# This script runs multiple webhook server load tests sequentially with
# automated cleanup between tests and generates comprehensive reports.
#
# USAGE:
#   ./scripts/run_all_webhook_loadtests.sh
#
# ENVIRONMENT VARIABLES:
#   OUTPUT_DIR                - Base directory for outputs (default: outputs/)
#   SKIP_CLEANUP              - Skip cleanup steps (default: false)
#   TEST_TIMEOUT              - Max time per test in seconds (default: 3600 = 1h)
#   CLEANUP_MAX_WAIT          - Max time for cleanup in seconds (default: 1800 = 30m)
#
# EXAMPLES:
#   # Run with custom output directory
#   OUTPUT_DIR=./my-results ./scripts/run_all_webhook_loadtests.sh
#
#   # Run without cleanup (for debugging)
#   SKIP_CLEANUP=true ./scripts/run_all_webhook_loadtests.sh
#
#   # Run with shorter test timeout
#   TEST_TIMEOUT=1800 ./scripts/run_all_webhook_loadtests.sh
#
# OUTPUT:
#   All results are saved in OUTPUT_DIR/webhook_run_TIMESTAMP/:
#   - summary.txt           - Text summary of results
#   - logs/                 - Individual test logs and metrics
#
# ============================================================================

set -o pipefail

# --- Configuration ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-outputs}"
RUN_DIR="$OUTPUT_DIR/webhook_run_$TIMESTAMP"
LOG_DIR="$RUN_DIR/logs"
MAKE_COMMAND="make test_webhook_load"
POLL_INTERVAL=10
CLEANUP_MAX_WAIT=1800   # 30 minutes for cleanup
TEST_TIMEOUT=3600       # 1 hour per test
SKIP_CLEANUP="${SKIP_CLEANUP:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test tracking
declare -a TEST_RESULTS
declare -a TEST_PLAN
TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0
PLANNING_MODE=true

echo "========================================================"
echo "Starting webhook load test suite at $(date)"
echo "========================================================"
mkdir -p "$LOG_DIR"
mkdir -p "$OUTPUT_DIR"

# Create README in output directory
cat > "$OUTPUT_DIR/README.md" <<'EOREADME'
# Webhook Load Test Results

This directory contains the results of webhook load test runs.

## Directory Structure

Each run is stored in a `webhook_run_YYYYMMDD_HHMMSS/` directory containing:
- `summary.txt` - Text summary of all test results
- `logs/` - Directory containing individual test logs
  - `<test_name>.log` - Full test output
  - `<test_name>_metrics.txt` - Extracted metrics and summary

## Viewing Results

1. View the text summary:
   ```bash
   cat webhook_run_YYYYMMDD_HHMMSS/summary.txt
   ```

2. Check individual test logs:
   ```bash
   cat webhook_run_YYYYMMDD_HHMMSS/logs/<test_name>.log
   ```

3. Check extracted metrics:
   ```bash
   cat webhook_run_YYYYMMDD_HHMMSS/logs/<test_name>_metrics.txt
   ```

## Test Status

- **PASSED**: Test completed successfully
- **FAILED**: Test failed with errors
- **TIMEOUT**: Test exceeded maximum time limit
- **CLEANUP_FAILED**: Pre-test cleanup failed
EOREADME

echo "Output directory: $RUN_DIR"
echo "Logs directory: $LOG_DIR"
echo "Skip cleanup: $SKIP_CLEANUP"
echo "Test timeout: ${TEST_TIMEOUT}s"
echo "Cleanup timeout: ${CLEANUP_MAX_WAIT}s"
echo "--------------------------------------------------------"

# Trap to handle interruption
trap 'handle_interrupt' INT TERM

handle_interrupt() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Test suite interrupted!${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo "Generating partial results..."
    generate_summary_report
    echo ""
    echo "Partial results saved in: $RUN_DIR"
    exit 130
}


########################################
# WAIT FOR COMPLETE CLEANUP CONDITIONS #
########################################
wait_for_cleanup() {
    if [ "$SKIP_CLEANUP" == "true" ]; then
        echo -e "${YELLOW}Skipping cleanup (SKIP_CLEANUP=true)${NC}"
        return 0
    fi

    echo -e "${BLUE}Waiting for environment cleanup...${NC}"
    echo "Conditions:"
    echo "  1) Namespace 'dw-webhook-loadtest' absent"
    echo "  2) All webhook loadtest ClusterRoleBindings deleted"
    echo "--------------------------------------------------------"

    local start_time=$(date +%s)
    local cleanup_attempt=0

    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        cleanup_attempt=$((cleanup_attempt + 1))

        if [ $elapsed -gt $CLEANUP_MAX_WAIT ]; then
            echo -e "${RED}ERROR: Cleanup did not finish within $CLEANUP_MAX_WAIT seconds${NC}"
            return 1
        fi

        # --- Delete webhook loadtest namespace if exists ---
        local ns_exists=0
        if oc get ns dw-webhook-loadtest --no-headers 2>/dev/null | grep -q dw-webhook-loadtest; then
            ns_exists=1
            echo -e "${YELLOW}Found dw-webhook-loadtest namespace. Deleting...${NC}"
            oc delete ns dw-webhook-loadtest --wait=false 2>/dev/null || true
        fi

        # --- Delete leftover ClusterRoleBindings ---
        local crb_list
        crb_list=$(oc get clusterrolebinding -l app=devworkspace-webhook-server-loadtest --no-headers 2>/dev/null || true)
        local crb_count=0
        if [[ -n "$crb_list" ]]; then
            crb_count=$(echo "$crb_list" | wc -l)
            echo -e "${YELLOW}Found $crb_count leftover ClusterRoleBindings. Deleting...${NC}"
            oc delete clusterrolebinding -l app=devworkspace-webhook-server-loadtest --ignore-not-found 2>/dev/null || true
        fi

        # --- Delete leftover ClusterRoles ---
        local cr_list
        cr_list=$(oc get clusterrole -l app=devworkspace-webhook-server-loadtest --no-headers 2>/dev/null || true)
        local cr_count=0
        if [[ -n "$cr_list" ]]; then
            cr_count=$(echo "$cr_list" | wc -l)
            echo -e "${YELLOW}Found $cr_count leftover ClusterRoles. Deleting...${NC}"
            oc delete clusterrole -l app=devworkspace-webhook-server-loadtest --ignore-not-found 2>/dev/null || true
        fi

        # --- All conditions satisfied ---
        if [ "$ns_exists" -eq 0 ] && [ "$crb_count" -eq 0 ] && [ "$cr_count" -eq 0 ]; then
            echo -e "${GREEN}Cleanup complete after ${elapsed}s (${cleanup_attempt} attempts)${NC}"
            echo "--------------------------------------------------------"
            return 0
        fi

        # --- Status output ---
        echo "Cleanup attempt #${cleanup_attempt} (elapsed ${elapsed}s):"
        echo "  - dw-webhook-loadtest ns: $ns_exists"
        echo "  - ClusterRoleBindings: $crb_count"
        echo "  - ClusterRoles: $cr_count"

        echo "Retrying in ${POLL_INTERVAL}s..."
        sleep $POLL_INTERVAL
    done
}


#############################################
# EXTRACT METRICS FROM LOG FILE            #
#############################################
extract_metrics() {
    local LOG_FILE="$1"
    local METRICS_FILE="${LOG_FILE%.log}_metrics.txt"

    if [ ! -f "$LOG_FILE" ]; then
        return
    fi

    {
        echo "=== Test Metrics ==="
        echo ""

        # Extract k6 summary if present
        if grep -q "checks\.\+:" "$LOG_FILE"; then
            echo "--- K6 Summary ---"
            grep -A 50 "checks\.\+:" "$LOG_FILE" | head -30 || true
            echo ""
        fi

        # Extract webhook-specific stats
        if grep -q "http_reqs" "$LOG_FILE"; then
            echo "--- HTTP Request Stats ---"
            grep "http_reqs\|http_req_duration\|iterations" "$LOG_FILE" | tail -20 || true
            echo ""
        fi

        # Extract any errors
        echo "--- Errors ---"
        grep -i "error\|failed\|timeout" "$LOG_FILE" | tail -10 || echo "No errors found"

    } > "$METRICS_FILE"
}

#############################################
# RUN TEST WITH AUTO-GENERATED NAME + ARGS  #
#############################################
run_test() {
    local TEST_NAME="$1"
    local ARGS="$2"
    local TEST_LOG="$LOG_DIR/$TEST_NAME.log"

    TEST_COUNT=$((TEST_COUNT + 1))

    echo ""
    echo "========================================================"
    echo -e "${BLUE}Test #$TEST_COUNT: $TEST_NAME${NC}"
    echo "========================================================"
    echo "Started at: $(date)"
    echo "Arguments: $ARGS"
    echo "Log file: $TEST_LOG"
    echo ""

    # Cleanup before test
    if ! wait_for_cleanup; then
        echo -e "${RED}FAILED: Pre-test cleanup failed for $TEST_NAME${NC}"
        TEST_RESULTS+=("$TEST_NAME|CLEANUP_FAILED|N/A")
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi

    # Run test with timeout
    local test_start=$(date +%s)
    local test_status="RUNNING"

    echo -e "${BLUE}Starting test execution...${NC}"

    # Run test in background to allow timeout
    timeout $TEST_TIMEOUT $MAKE_COMMAND ARGS="$ARGS" > "$TEST_LOG" 2>&1
    local exit_code=$?

    local test_end=$(date +%s)
    local duration=$((test_end - test_start))
    local duration_min=$((duration / 60))

    echo ""
    echo "Test finished at: $(date)"
    echo "Duration: ${duration}s (${duration_min} minutes)"

    # Determine test status
    if [ $exit_code -eq 124 ]; then
        test_status="TIMEOUT"
        echo -e "${RED}TEST TIMEOUT after ${TEST_TIMEOUT}s${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    elif [ $exit_code -ne 0 ]; then
        test_status="FAILED"
        echo -e "${RED}TEST FAILED with exit code $exit_code${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        test_status="PASSED"
        echo -e "${GREEN}TEST PASSED${NC}"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    fi

    # Extract metrics from log
    extract_metrics "$TEST_LOG"

    # Store result
    TEST_RESULTS+=("$TEST_NAME|$test_status|${duration_min}m")

    echo "Log saved: $TEST_LOG"
    echo "--------------------------------------------------------"

    # Cleanup after test
    echo ""
    echo -e "${BLUE}Running post-test cleanup...${NC}"
    if ! wait_for_cleanup; then
        echo -e "${YELLOW}WARNING: Post-test cleanup failed, but continuing...${NC}"
    fi

    return $exit_code
}


#############################################
# GENERATE SUMMARY REPORT                  #
#############################################
generate_summary_report() {
    local SUMMARY_FILE="$RUN_DIR/summary.txt"

    echo ""
    echo "========================================================"
    echo "Generating summary report..."
    echo "========================================================"

    # Generate text summary
    {
        echo "========================================================"
        echo "Webhook Load Test Suite Summary"
        echo "========================================================"
        echo "Started: $(head -1 "$RUN_DIR/test_suite.log" 2>/dev/null || echo 'N/A')"
        echo "Completed: $(date)"
        echo "Output Directory: $RUN_DIR"
        echo ""
        echo "Test Results:"
        echo "  Total: $TEST_COUNT"
        echo "  Passed: $PASSED_COUNT"
        echo "  Failed: $FAILED_COUNT"
        echo ""
        echo "--------------------------------------------------------"
        echo "Individual Test Results:"
        echo "--------------------------------------------------------"
        printf "%-40s %-15s %-10s\n" "Test Name" "Status" "Duration"
        echo "--------------------------------------------------------"

        for result in "${TEST_RESULTS[@]}"; do
            IFS='|' read -r name status duration <<< "$result"
            printf "%-40s %-15s %-10s\n" "$name" "$status" "$duration"
        done

        echo "--------------------------------------------------------"
        echo ""
        echo "Log Files:"
        ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "No log files found"
        echo ""
        echo "========================================================"

    } | tee "$SUMMARY_FILE"

    echo ""
    echo -e "${GREEN}Summary report saved to: $SUMMARY_FILE${NC}"
}

#############################################
#         SIMPLE: ADD TESTS HERE            #
#############################################
# add_webhook_test <test-name> <number-of-users> [extra-args]
add_webhook_test() {
    local TEST_NAME="$1"
    local NUM_USERS="$2"
    local EXTRA_ARGS="${3:-}"

    # In planning mode, just add to plan
    if [ "$PLANNING_MODE" == "true" ]; then
        TEST_PLAN+=("$TEST_NAME|$NUM_USERS users|Default timeout")
        return 0
    fi

    # Construct ARGS automatically
    local ARGS="--number-of-users $NUM_USERS \
                $EXTRA_ARGS"

    run_test "$TEST_NAME" "$ARGS"
}

# For advanced test configurations, you can use add_custom_test
# add_custom_test <test-name> <full-args>
add_custom_test() {
    local TEST_NAME="$1"
    local ARGS="$2"

    # In planning mode, just add to plan
    if [ "$PLANNING_MODE" == "true" ]; then
        TEST_PLAN+=("$TEST_NAME|Custom configuration|N/A")
        return 0
    fi

    run_test "$TEST_NAME" "$ARGS"
}


#############################################
#           DEFINE TEST SUITE HERE          #
#############################################

# Show test plan before starting
show_test_plan() {
    echo ""
    echo "========================================================"
    echo "TEST PLAN"
    echo "========================================================"
    echo "The following webhook tests will be executed:"
    echo ""
    printf "%-30s %-20s %-20s\n" "Test Name" "Configuration" "Timeout"
    echo "--------------------------------------------------------"

    for plan in "${TEST_PLAN[@]}"; do
        IFS='|' read -r name config timeout <<< "$plan"
        printf "%-30s %-20s %-20s\n" "$name" "$config" "$timeout"
    done

    echo "--------------------------------------------------------"
    echo "Total tests planned: ${#TEST_PLAN[@]}"
    echo ""
}

# Save suite start time
SUITE_START=$(date +%s)
echo "$(date)" > "$RUN_DIR/test_suite.log"

#############################################
# CONFIGURE YOUR TESTS HERE                 #
#############################################
# Add your webhook tests here - each test will run sequentially with cleanup between tests
# Format: add_webhook_test <test-name> <number-of-users> [extra-args]
#
# Examples:
#   add_webhook_test "10users" 10
#   add_webhook_test "50users" 50
#   add_webhook_test "100users" 100
#
# For completely custom tests:
#   add_custom_test "my-test" "--number-of-users 20 --dev-workspace-ready-timeout-in-seconds 800"
#
# NOTE: Define your tests ONCE in the run_tests() function below.
#       They will be collected for the plan preview, then executed.

# Function to define all tests
run_tests() {
    add_webhook_test "100users" 100
    add_webhook_test "200users" 200
    add_webhook_test "300users" 300
    add_webhook_test "400users" 400
    add_webhook_test "500users" 500
}

# First pass: collect test plan
PLANNING_MODE=true
run_tests

# Show test plan
show_test_plan

# Wait 10 seconds before starting (gives time to cancel if needed)
echo -e "${YELLOW}Tests will begin in 10 seconds... (Press Ctrl+C to cancel)${NC}"
for i in {10..1}; do
    echo -n "$i... "
    sleep 1
done
echo ""
echo ""

# Second pass: execute tests
PLANNING_MODE=false
run_tests

# Calculate total suite duration
SUITE_END=$(date +%s)
SUITE_DURATION=$((SUITE_END - SUITE_START))
SUITE_DURATION_MIN=$((SUITE_DURATION / 60))
SUITE_DURATION_HOUR=$((SUITE_DURATION / 3600))

echo ""
echo "========================================================"
echo -e "${GREEN}Webhook load test suite COMPLETE${NC}"
echo "========================================================"
echo "Completed at: $(date)"
echo "Total duration: ${SUITE_DURATION}s (${SUITE_DURATION_MIN} minutes / ${SUITE_DURATION_HOUR} hours)"
echo ""

# Generate summary report
generate_summary_report

echo ""
echo "========================================================"
echo "All outputs saved in: $RUN_DIR"
echo "========================================================"
echo "View the summary:"
echo "  cat $RUN_DIR/summary.txt"
echo ""
