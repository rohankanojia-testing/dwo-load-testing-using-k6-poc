#!/bin/bash

# ============================================================================
# DevWorkspace Load Testing Suite Runner
# ============================================================================
#
# This script runs multiple load tests sequentially with automated cleanup
# between tests and generates comprehensive reports.
#
# USAGE:
#   ./scripts/run_all_loadtests.sh [TEST_PLAN_FILE]
#
# ARGUMENTS:
#   TEST_PLAN_FILE            - Optional JSON test plan file
#                               If not provided, uses default test plan defined in script
#
# ENVIRONMENT VARIABLES:
#   OUTPUT_DIR                - Base directory for outputs (default: outputs/)
#   SKIP_CLEANUP              - Skip cleanup steps (default: false)
#   RESTART_OPERATOR          - Restart DWO operator after cleanup (default: true)
#   TEST_TIMEOUT              - Max time per test in seconds (default: 14400 = 4h)
#   CLEANUP_MAX_WAIT          - Max time for cleanup in seconds (default: 7200 = 2h)
#
# EXAMPLES:
#   # Run with default test plan (defined in script)
#   ./scripts/run_all_loadtests.sh
#
#   # Run with custom test plan from JSON file
#   ./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json
#
#   # Run with custom output directory
#   OUTPUT_DIR=./my-results ./scripts/run_all_loadtests.sh
#
#   # Run without cleanup (for debugging)
#   SKIP_CLEANUP=true ./scripts/run_all_loadtests.sh
#
#   # Run without operator restart (restart is enabled by default)
#   RESTART_OPERATOR=false ./scripts/run_all_loadtests.sh
#
#   # Run with shorter test timeout
#   TEST_TIMEOUT=3600 ./scripts/run_all_loadtests.sh
#
# OUTPUT:
#   All results are saved in OUTPUT_DIR/run_TIMESTAMP/:
#   - summary.txt           - Text summary of results
#   - logs/                 - Individual test logs and metrics
#
# ============================================================================

set -o pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-outputs}"
RUN_DIR="$OUTPUT_DIR/run_$TIMESTAMP"
LOG_DIR="$RUN_DIR/logs"
MAKE_COMMAND="make test_load"
POLL_INTERVAL=30
CLEANUP_MAX_WAIT=7200   # 2 hours for cleanup
TEST_TIMEOUT=14400      # 4 hours per test
SKIP_CLEANUP="${SKIP_CLEANUP:-false}"
RESTART_OPERATOR="${RESTART_OPERATOR:-true}"

# Test plan file (optional)
TEST_PLAN_FILE="${1:-}"
USE_JSON_PLAN=false

# Check if JSON plan file is provided
if [ -n "$TEST_PLAN_FILE" ]; then
    USE_JSON_PLAN=true

    # Check for jq
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required for JSON test plans but not installed."
        echo "Install it with: brew install jq (macOS) or apt-get install jq (Linux)"
        echo ""
        echo "Alternatively, run without arguments to use the default hardcoded test plan:"
        echo "  ./scripts/run_all_loadtests.sh"
        exit 1
    fi

    # Validate test plan file exists
    if [ ! -f "$TEST_PLAN_FILE" ]; then
        echo "ERROR: Test plan file not found: $TEST_PLAN_FILE"
        exit 1
    fi

    # Validate JSON
    if ! jq empty "$TEST_PLAN_FILE" 2>/dev/null; then
        echo "ERROR: Invalid JSON in test plan file: $TEST_PLAN_FILE"
        exit 1
    fi
fi

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
echo "Starting load test suite at $(date)"
echo "========================================================"

if [ "$USE_JSON_PLAN" == "true" ]; then
    echo "Mode: JSON test plan"
    echo "Test plan file: $TEST_PLAN_FILE"
else
    echo "Mode: Default hardcoded test plan"
fi

mkdir -p "$LOG_DIR"
mkdir -p "$OUTPUT_DIR"

# Create README in output directory
cat > "$OUTPUT_DIR/README.md" <<'EOREADME'
# Load Test Results

This directory contains the results of load test runs.

## Directory Structure

Each run is stored in a `run_YYYYMMDD_HHMMSS/` directory containing:
- `summary.txt` - Text summary of all test results
- `logs/` - Directory containing individual test logs
  - `<test_name>.log` - Full test output
  - `<test_name>_metrics.txt` - Extracted metrics and summary
  - `<test_name>_failure_report.csv` - Failed DevWorkspaces details (if any)

## Viewing Results

1. View the text summary:
   ```bash
   cat run_YYYYMMDD_HHMMSS/summary.txt
   ```

2. Check individual test logs:
   ```bash
   cat run_YYYYMMDD_HHMMSS/logs/<test_name>.log
   ```

3. Check extracted metrics:
   ```bash
   cat run_YYYYMMDD_HHMMSS/logs/<test_name>_metrics.txt
   ```

4. Check failed DevWorkspaces (if any):
   ```bash
   cat run_YYYYMMDD_HHMMSS/logs/<test_name>_failure_report.csv
   ```

## Test Status

- **PASSED**: Test completed successfully
- **FAILED**: Test failed with errors
- **TIMEOUT**: Test exceeded maximum time limit
- **CLEANUP_FAILED**: Pre-test cleanup failed

## Failure Report Format

The `*_failure_report.csv` files contain details about failed DevWorkspaces:
- Namespace
- DevWorkspace name
- Status
- Error message
EOREADME

echo "Output directory: $RUN_DIR"
echo "Logs directory: $LOG_DIR"
echo "Skip cleanup: $SKIP_CLEANUP"
echo "Restart operator: $RESTART_OPERATOR"
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
    echo "  1) No DevWorkspaces anywhere (we'll delete leftovers)"
    echo "  2) Namespace 'loadtest-devworkspaces' absent"
    echo "  3) No namespace with label load-test=test-type (we'll delete leftovers)"
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

        # --- Delete leftover DevWorkspaces ---
        local dw_list
        dw_list=$(oc get dw --all-namespaces --no-headers 2>/dev/null || true)

        local dw_count=0
        if [[ -n "$dw_list" ]] && ! echo "$dw_list" | grep -qi "No resources found"; then
            dw_count=$(echo "$dw_list" | wc -l)
            echo -e "${YELLOW}Found $dw_count leftover DevWorkspaces. Deleting...${NC}"
            echo "$dw_list" | awk '{print $2, $1}' | while read dw ns; do
                if [[ -n "$dw" && -n "$ns" ]]; then
                    echo "  Deleting DevWorkspace $dw in namespace $ns..."
                    oc delete dw "$dw" -n "$ns" --wait=false 2>/dev/null || true
                fi
            done
        fi

        # --- Delete leftover labeled namespaces ---
        local labeled_ns_list
        labeled_ns_list=$(oc get ns -l load-test=test-type --no-headers 2>/dev/null || true)
        local labeled_ns_count=0
        if [[ -n "$labeled_ns_list" ]]; then
            labeled_ns_count=$(echo "$labeled_ns_list" | wc -l)
            echo -e "${YELLOW}Found $labeled_ns_count leftover labeled namespaces. Deleting...${NC}"
            echo "$labeled_ns_list" | awk '{print $1}' | while read ns; do
                if [[ -n "$ns" ]]; then
                    echo "  Deleting namespace $ns..."
                    oc delete ns "$ns" --wait=false 2>/dev/null || true
                fi
            done
        fi

        # --- Delete specific test namespace if exists ---
        local ns_exists=0
        if oc get ns loadtest-devworkspaces --no-headers 2>/dev/null | grep -q loadtest-devworkspaces; then
            ns_exists=1
            echo -e "${YELLOW}Found loadtest-devworkspaces namespace. Deleting...${NC}"
            oc delete ns loadtest-devworkspaces --wait=false 2>/dev/null || true
        fi

        # --- All conditions satisfied ---
        if [ "$dw_count" -eq 0 ] && [ "$ns_exists" -eq 0 ] && [ "$labeled_ns_count" -eq 0 ]; then
            echo -e "${GREEN}Cleanup complete after ${elapsed}s (${cleanup_attempt} attempts)${NC}"
            echo "--------------------------------------------------------"

            # Restart operator if requested
            if [ "$RESTART_OPERATOR" == "true" ]; then
                echo ""
                echo -e "${BLUE}Restarting DevWorkspace Operator...${NC}"
                if bash "$(dirname "$0")/restart_dwo_operator.sh"; then
                    echo -e "${GREEN}Operator restart successful${NC}"
                else
                    echo -e "${RED}ERROR: Operator restart failed${NC}"
                    return 1
                fi
                echo "--------------------------------------------------------"
            fi

            return 0
        fi

        # --- Status output ---
        echo "Cleanup attempt #${cleanup_attempt} (elapsed ${elapsed}s):"
        echo "  - DevWorkspaces: $dw_count"
        echo "  - loadtest-devworkspaces ns: $ns_exists"
        echo "  - labeled namespaces: $labeled_ns_count"

        if [ "$labeled_ns_count" -gt 0 ]; then
            oc get ns -l load-test=test-type --no-headers 2>/dev/null || true
        fi

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

        # Extract DevWorkspace creation stats
        if grep -q "DevWorkspaces created" "$LOG_FILE"; then
            echo "--- DevWorkspace Stats ---"
            grep "DevWorkspaces created\|DevWorkspaces ready\|Failed\|Error" "$LOG_FILE" | tail -20 || true
            echo ""
        fi

        # Extract any errors
        echo "--- Errors ---"
        grep -i "error\|failed\|timeout" "$LOG_FILE" | tail -10 || echo "No errors found"

        # Check for failure report
        local FAILURE_REPORT="${LOG_FILE%.log}_failure_report.csv"
        if [ -f "$FAILURE_REPORT" ]; then
            echo ""
            echo "--- Failed DevWorkspaces ---"
            local failure_count=$(wc -l < "$FAILURE_REPORT" | xargs)
            echo "Total failures: $failure_count"
            echo ""
            echo "First 5 failures:"
            head -5 "$FAILURE_REPORT" || true
            echo ""
            echo "See full report: $FAILURE_REPORT"
        fi

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

    # Copy failure report if it exists
    if [ -f "logs/dw_failure_report.csv" ]; then
        local FAILURE_REPORT="$LOG_DIR/${TEST_NAME}_failure_report.csv"
        cp "logs/dw_failure_report.csv" "$FAILURE_REPORT"
        echo "Failure report saved: $FAILURE_REPORT"

        # Show failure count
        local failure_count=$(wc -l < "logs/dw_failure_report.csv" | xargs)
        if [ "$failure_count" -gt 0 ]; then
            echo -e "${YELLOW}Found $failure_count failed DevWorkspaces${NC}"
        fi
    fi

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
        echo "Load Test Suite Summary"
        echo "========================================================"
        if [ "$USE_JSON_PLAN" == "true" ]; then
            echo "Test Plan: $TEST_PLAN_FILE"
        else
            echo "Test Plan: Default (hardcoded)"
        fi
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
# add_test <max-devworkspaces> <single|separate> <duration-minutes> [extra-args]
add_test() {
    local MAX=$1
    local MODE=$2
    local DURATION=$3
    local EXTRA_ARGS="${4:-}"

    # Map mode to separate-namespaces flag
    if [ "$MODE" == "single" ]; then
        local SEPARATE="false"
        local MODE_NAME="single_ns"
    elif [ "$MODE" == "separate" ]; then
        local SEPARATE="true"
        local MODE_NAME="separate_ns"
    else
        echo -e "${RED}ERROR: invalid mode '$MODE'. Use: single | separate${NC}"
        exit 1
    fi

    # Auto-generate test name
    local TEST_NAME="${MAX}_${MODE_NAME}_${DURATION}m"

    # In planning mode, just add to plan
    if [ "$PLANNING_MODE" == "true" ]; then
        TEST_PLAN+=("$TEST_NAME|$MAX DevWorkspaces|$MODE namespace|${DURATION} minutes")
        return 0
    fi

    # Construct ARGS automatically
    local TIMEOUT_SECONDS=$((DURATION * 60))
    local ARGS="--mode binary \
                --max-vus 300 \
                --create-automount-resources true \
                --max-devworkspaces $MAX \
                --delete-devworkspace-after-ready false \
                --separate-namespaces $SEPARATE \
                --devworkspace-ready-timeout-seconds $TIMEOUT_SECONDS \
                --test-duration-minutes $DURATION \
                $EXTRA_ARGS"

    run_test "$TEST_NAME" "$ARGS"
}

# For advanced test configurations, you can use add_custom_test
# add_custom_test <test-name> <full-args>
add_custom_test() {
    local TEST_NAME="$1"
    local ARGS="$2"

    run_test "$TEST_NAME" "$ARGS"
}


#############################################
#    LOAD TEST PLAN FROM JSON FILE         #
#############################################

# Load tests from JSON file and populate TEST_PLAN array
load_test_plan_from_json() {
    if [ "$USE_JSON_PLAN" != "true" ]; then
        return
    fi

    echo "Loading test plan from: $TEST_PLAN_FILE"

    # Load standard tests
    local test_count=$(jq '.tests | length' "$TEST_PLAN_FILE")
    echo "Found $test_count standard tests in plan"

    for ((i=0; i<test_count; i++)); do
        local enabled=$(jq -r ".tests[$i].enabled" "$TEST_PLAN_FILE")

        if [ "$enabled" != "true" ]; then
            continue
        fi

        local max=$(jq -r ".tests[$i].max_devworkspaces" "$TEST_PLAN_FILE")
        local mode=$(jq -r ".tests[$i].mode" "$TEST_PLAN_FILE")
        local duration=$(jq -r ".tests[$i].duration_minutes" "$TEST_PLAN_FILE")

        # Add to plan
        TEST_PLAN+=("${max}_${mode}_${duration}m|$max DevWorkspaces|$mode namespace|${duration} minutes")
    done

    # Load custom tests
    local custom_count=$(jq '.custom_tests | length' "$TEST_PLAN_FILE" 2>/dev/null || echo "0")
    if [ "$custom_count" -gt 0 ]; then
        echo "Found $custom_count custom tests in plan"

        for ((i=0; i<custom_count; i++)); do
            local enabled=$(jq -r ".custom_tests[$i].enabled" "$TEST_PLAN_FILE")

            if [ "$enabled" != "true" ]; then
                continue
            fi

            local name=$(jq -r ".custom_tests[$i].name" "$TEST_PLAN_FILE")

            # Add to plan
            TEST_PLAN+=("$name|Custom|Custom|Custom")
        done
    fi

    if [ ${#TEST_PLAN[@]} -eq 0 ]; then
        echo "WARNING: No enabled tests found in test plan"
        echo "Please enable at least one test in $TEST_PLAN_FILE"
        exit 1
    fi

    echo "Loaded ${#TEST_PLAN[@]} enabled tests"
}

# Execute tests from JSON file
execute_tests_from_json() {
    if [ "$USE_JSON_PLAN" != "true" ]; then
        return
    fi

    # Execute standard tests
    local test_count=$(jq '.tests | length' "$TEST_PLAN_FILE")

    for ((i=0; i<test_count; i++)); do
        local enabled=$(jq -r ".tests[$i].enabled" "$TEST_PLAN_FILE")

        if [ "$enabled" != "true" ]; then
            continue
        fi

        local max=$(jq -r ".tests[$i].max_devworkspaces" "$TEST_PLAN_FILE")
        local mode=$(jq -r ".tests[$i].mode" "$TEST_PLAN_FILE")
        local duration=$(jq -r ".tests[$i].duration_minutes" "$TEST_PLAN_FILE")

        # Map mode to separate-namespaces flag
        local separate
        local mode_name
        if [ "$mode" == "single" ]; then
            separate="false"
            mode_name="single_ns"
        else
            separate="true"
            mode_name="separate_ns"
        fi

        # Generate test name
        local test_name="${max}_${mode_name}_${duration}m"

        # Construct ARGS
        local timeout_seconds=$((duration * 60))
        local args="--mode binary \
                    --max-vus 300 \
                    --create-automount-resources true \
                    --max-devworkspaces $max \
                    --delete-devworkspace-after-ready false \
                    --separate-namespaces $separate \
                    --devworkspace-ready-timeout-seconds $timeout_seconds \
                    --test-duration-minutes $duration"

        run_test "$test_name" "$args"
    done

    # Execute custom tests
    local custom_count=$(jq '.custom_tests | length' "$TEST_PLAN_FILE" 2>/dev/null || echo "0")

    for ((i=0; i<custom_count; i++)); do
        local enabled=$(jq -r ".custom_tests[$i].enabled" "$TEST_PLAN_FILE")

        if [ "$enabled" != "true" ]; then
            continue
        fi

        local name=$(jq -r ".custom_tests[$i].name" "$TEST_PLAN_FILE")
        local args=$(jq -r ".custom_tests[$i].args" "$TEST_PLAN_FILE")

        run_test "$name" "$args"
    done
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
    echo "The following tests will be executed:"
    echo ""
    printf "%-30s %-20s %-20s %-15s\n" "Test Name" "Max DevWorkspaces" "Namespace Mode" "Duration"
    echo "--------------------------------------------------------"

    for plan in "${TEST_PLAN[@]}"; do
        IFS='|' read -r name max mode duration <<< "$plan"
        printf "%-30s %-20s %-20s %-15s\n" "$name" "$max" "$mode" "$duration"
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
# Add your tests here - each test will run sequentially with cleanup between tests
# Format: add_test <max-devworkspaces> <single|separate> <duration-minutes> [extra-args]
#
# Examples:
#   add_test 1000 single 40                      # 1000 DWs, single namespace, 40 min
#   add_test 2000 separate 60                    # 2000 DWs, separate namespaces, 60 min
#   add_test 500 single 30 "--max-vus 500"       # Custom VUs
#
# For completely custom tests:
#   add_custom_test "my-test" "--mode binary --max-vus 100 --max-devworkspaces 500"
#
# NOTE: Define your tests ONCE in the run_tests() function below.
#       They will be collected for the plan preview, then executed.
#
# To use a JSON test plan instead, run:
#   ./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json

# Function to define all tests (DEFAULT TEST PLAN - used when no JSON file is provided)
run_tests() {
    add_test 1500 single 40
    add_test 1500 separate 60
}

#############################################
#              MAIN EXECUTION               #
#############################################

if [ "$USE_JSON_PLAN" == "true" ]; then
    # JSON-based test plan
    load_test_plan_from_json
    show_test_plan

    # Wait 10 seconds before starting
    echo -e "${YELLOW}Tests will begin in 10 seconds... (Press Ctrl+C to cancel)${NC}"
    for i in {10..1}; do
        echo -n "$i... "
        sleep 1
    done
    echo ""
    echo ""

    # Execute tests from JSON
    execute_tests_from_json
else
    # Hardcoded test plan (backward compatibility)
    # First pass: collect test plan
    PLANNING_MODE=true
    run_tests

    # Show test plan
    show_test_plan

    # Wait 10 seconds before starting
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
fi

# Calculate total suite duration
SUITE_END=$(date +%s)
SUITE_DURATION=$((SUITE_END - SUITE_START))
SUITE_DURATION_MIN=$((SUITE_DURATION / 60))
SUITE_DURATION_HOUR=$((SUITE_DURATION / 3600))

echo ""
echo "========================================================"
echo -e "${GREEN}Load test suite COMPLETE${NC}"
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

