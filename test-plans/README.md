# Load Test Plans

This directory contains test plan configuration files that define which load tests to run.

## Quick Start

Run tests using the default hardcoded test plan:
```bash
./scripts/run_all_loadtests.sh
```

Run tests using a JSON test plan:
```bash
./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json
```

## Test Plan Format

Test plans are defined in JSON format with two types of tests:

### 1. Standard Tests

These are the most common test configurations with simple parameters:

```json
{
  "description": "My Test Plan",
  "tests": [
    {
      "max_devworkspaces": 1500,
      "mode": "single",
      "duration_minutes": 40,
      "enabled": true,
      "description": "1500 DevWorkspaces in single namespace"
    },
    {
      "max_devworkspaces": 1500,
      "mode": "separate",
      "duration_minutes": 60,
      "enabled": true,
      "description": "1500 DevWorkspaces in separate namespaces"
    }
  ]
}
```

**Parameters:**
- `max_devworkspaces` - Number of DevWorkspaces to create
- `mode` - Either `"single"` (all in one namespace) or `"separate"` (each in its own namespace)
- `duration_minutes` - How long the test should run
- `enabled` - Set to `true` to run this test, `false` to skip it
- `description` - Human-readable description (optional)

### 2. Custom Tests

For advanced configurations that need specific arguments:

```json
{
  "custom_tests": [
    {
      "name": "custom_vus_test",
      "args": "--mode binary --max-vus 500 --max-devworkspaces 500 --separate-namespaces false --test-duration-minutes 40",
      "enabled": true,
      "description": "Custom test with 500 VUs"
    }
  ]
}
```

**Parameters:**
- `name` - Test name (used in logs and reports)
- `args` - Full command-line arguments to pass to the test
- `enabled` - Set to `true` to run this test, `false` to skip it
- `description` - Human-readable description (optional)

## Example Use Cases

### Run only two specific tests

Edit `controller-test-plan.json` and set `enabled: true` for only the tests you want:

```json
{
  "tests": [
    {
      "max_devworkspaces": 1500,
      "mode": "single",
      "duration_minutes": 40,
      "enabled": true
    },
    {
      "max_devworkspaces": 1500,
      "mode": "separate",
      "duration_minutes": 60,
      "enabled": true
    },
    {
      "max_devworkspaces": 2000,
      "mode": "single",
      "duration_minutes": 40,
      "enabled": false
    }
  ]
}
```

### Create a custom test plan

Copy the default plan and modify it:

```bash
cp test-plans/controller-test-plan.json test-plans/my-plan.json
# Edit my-plan.json with your tests
./scripts/run_all_loadtests.sh test-plans/my-plan.json
```

### Quick smoke test

Create a minimal test plan for quick validation:

```json
{
  "description": "Smoke Test Plan",
  "tests": [
    {
      "max_devworkspaces": 100,
      "mode": "single",
      "duration_minutes": 10,
      "enabled": true,
      "description": "Quick smoke test"
    }
  ]
}
```

## Available Test Plans

### 1. `minimal-test-plan.json` - Smoke Test
Quick validation to verify everything is working:
- 20 DevWorkspaces in single namespace (15 min)

**Usage:**
```bash
./scripts/run_all_loadtests.sh test-plans/minimal-test-plan.json
```

### 2. `devspaces-prerelease-test-plan.json` - Pre-Release Testing
Standard pre-release load testing configuration:
- 1500 DevWorkspaces in single namespace (40 min)
- 1500 DevWorkspaces in separate namespaces (60 min)

**Usage:**
```bash
./scripts/run_all_loadtests.sh test-plans/devspaces-prerelease-test-plan.json
```

### 3. `controller-test-plan.json` - Full Scale Options
Comprehensive test plan with multiple scale options (all disabled by default):
- 1000, 1500, 2000, 2500 DevWorkspaces in both single and separate namespace modes
- Enable specific tests as needed

**Usage:**
```bash
# Edit to enable desired tests first
./scripts/run_all_loadtests.sh test-plans/controller-test-plan.json
```

## Environment Variables

The script respects the same environment variables:

```bash
# Custom output directory
OUTPUT_DIR=./my-results ./scripts/run_all_loadtests.sh test-plans/my-plan.json

# Skip cleanup (for debugging)
SKIP_CLEANUP=true ./scripts/run_all_loadtests.sh test-plans/my-plan.json

# Disable operator restart between tests
RESTART_OPERATOR=false ./scripts/run_all_loadtests.sh test-plans/my-plan.json

# Custom timeouts
TEST_TIMEOUT=7200 CLEANUP_MAX_WAIT=3600 ./scripts/run_all_loadtests.sh test-plans/my-plan.json
```

## How It Works

The `run_all_loadtests.sh` script supports two modes:

1. **Default mode** (no arguments): Uses the hardcoded test plan defined in the `run_tests()` function within the script
2. **JSON mode** (with argument): Reads test configuration from a JSON file

This provides flexibility - you can quickly run standard tests or use JSON files for complex/varying test scenarios.

## Validation

When using JSON mode, the script validates:
- Test plan file exists
- JSON is valid
- At least one test is enabled
- `jq` is installed (required for JSON parsing)

If validation fails, you'll see a clear error message.
