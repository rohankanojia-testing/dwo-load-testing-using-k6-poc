# Claude AI Assistant Guide

This file provides guidance for AI assistants working with the DevWorkspace Operator Load Tests repository.

## Project Overview

This repository contains load testing tools for the DevWorkspace Operator using k6. The project consists of two main test modules:

1. **DevWorkspace Controller Load Tests** (`test-devworkspace-controller-load/`) - Tests the controller's ability to create and manage multiple DevWorkspaces concurrently
2. **Webhook Server Load Tests** (`test-devworkspace-webhook-server-load/`) - Tests webhook server admission control, identity immutability validation, and exec permission enforcement

## Commit Requirements

**CRITICAL**: All commits MUST be signed off using the `-s` or `--signoff` flag:

```bash
git commit -s -m "commit message"
```

This adds a "Signed-off-by" line to the commit message, which is required for this project.

### Commit Message Format

Use conventional commit format:

- `feat:` - New features
- `fix:` - Bug fixes
- `chore:` - Maintenance tasks (dependencies, build, etc.)
- `docs:` - Documentation changes
- `refactor:` - Code refactoring without changing functionality
- `test:` - Test additions or modifications
- `perf:` - Performance improvements

Example:
```
feat: add platform auto-detection for DevSpaces/Che

Add automatic detection for DevSpaces vs Eclipse Che platform and
auto-discovery of CheCluster name and namespace.

Signed-off-by: Your Name <your.email@example.com>
```

## Code Organization

### Directory Structure

- `test-devworkspace-controller-load/` - Controller load test scripts and k6 test files
- `test-devworkspace-webhook-server-load/` - Webhook server load test scripts and k6 test files
- `scripts/` - Utility scripts for running tests, data processing, and operator management
- `test-plans/` - JSON-based test plan configurations
- `images/` - Documentation diagrams and flow charts
- `outputs/` - Test outputs and logs (git-ignored)

### Key Files

- `runk6.sh` - Main entry point for controller load tests
- `create-users-and-runk6.sh` - Main entry point for webhook server load tests
- `install-che-if-needed.sh` - Automatic Eclipse Che installation and platform detection
- `che-cert-bundle-utils.sh` - Utilities for Eclipse Che certificate management
- `provision-che-workspace-namespace.sh` - Namespace provisioning for Che workspaces
- `run_all_loadtests.sh` - Suite runner for multiple controller test configurations
- `run_all_webhook_loadtests.sh` - Suite runner for webhook server tests

## Working with This Codebase

### Shell Scripts

- All shell scripts use bash (`#!/bin/bash`)
- Use consistent logging functions: `log_info()`, `log_success()`, `log_error()`
- Validate required arguments and provide helpful error messages
- Use double quotes around variables to prevent word splitting
- Prefer `[[` over `[` for conditionals
- Always check command exit codes for critical operations

### Platform Compatibility

The tests support multiple platforms:
- **OpenShift** with DevWorkspace Operator
- **Kubernetes** with DevWorkspace Operator
- **Eclipse Che** / **Red Hat Dev Spaces**

When adding features:
- Auto-detect platform/environment when possible (see `detect_platform()` in `che-cert-bundle-utils.sh`)
- Don't hardcode namespace names or resource names
- Use `kubectl` commands that work across both Kubernetes and OpenShift
- Use `oc` commands only when OpenShift-specific functionality is required

### Eclipse Che/Dev Spaces Integration

When working with Che/DevSpaces-related code:
- Eclipse Che is automatically installed if `--run-with-eclipse-che true` is set and Che is not present
- Platform detection determines deployment target: CRC, OpenShift, or Kubernetes
- Auto-discover CheCluster name and namespace (see `get_checluster_name()`)
- Handle both deployment names: `che` and `devspaces`
- Certificate bundle management (750 certs ~1MiB) is automatically provisioned when `--run-with-eclipse-che true`
- Requires `chectl` CLI only if Che needs to be installed

### K6 Load Test Scripts

- K6 scripts are written in JavaScript (ES6 modules)
- Use custom k6 metrics for tracking specific behaviors
- Follow k6 best practices for VU (Virtual User) management
- Include proper error handling and logging

## Testing Guidelines

### Before Submitting Changes

1. **Test locally** - Run the affected test suite to ensure it works
2. **Check for regressions** - Ensure existing functionality still works
3. **Validate on target platform** - Test on Kubernetes/OpenShift if platform-specific
4. **Review error handling** - Ensure scripts fail gracefully with clear error messages

### Common Test Scenarios

- Controller tests with Eclipse Che: `make test_load ARGS="--run-with-eclipse-che true"`
- Controller tests standalone: `make test_load`
- Webhook server tests: `make test_webhook_load`
- Test suite execution: `./scripts/run_all_loadtests.sh <test-plan.json>`

## Important Considerations

### Resource Management

- Be mindful of cluster resource limits when modifying VU counts or concurrent operations
- Clean up resources properly in all code paths (including error paths)
- Use background watchers for monitoring, and ensure they're stopped on exit

### Security

- Validate user inputs, especially when used in `kubectl` commands
- Don't log sensitive information (tokens, credentials)
- Use ServiceAccounts with minimal required permissions
- Respect RBAC constraints

### Performance

- Avoid polling loops where watchers can be used
- Use parallel operations where safe (kubectl apply, independent checks)
- Consider timeout values carefully - they should be configurable

### Error Handling

- Provide actionable error messages with context
- Validate prerequisites (kubectl version, k6 installation, cluster access)
- Don't suppress errors silently - log and handle appropriately
- Return non-zero exit codes on failure

## Code Style

### Shell Scripts

- Use 2-space indentation
- Function names use snake_case
- Constants use UPPER_CASE
- Local variables use lowercase with `local` keyword
- Add comments for complex logic, but prefer self-documenting code

### Variable Quoting

```bash
# Good
local namespace="${1}"
kubectl get pods -n "${namespace}"

# Avoid
local namespace=$1
kubectl get pods -n $namespace
```

### Error Checking

```bash
# Good
if ! kubectl apply -f resource.yaml; then
  log_error "Failed to apply resource"
  return 1
fi

# Also good for critical commands
kubectl delete pod "${pod_name}" || {
  log_error "Failed to delete pod ${pod_name}"
  exit 1
}
```

## Common Patterns

### Auto-Detection

When possible, auto-detect configuration rather than requiring user input:

```bash
detect_che_namespace() {
  if [[ -z "$CHE_NAMESPACE" ]]; then
    local checluster_ns
    checluster_ns=$(kubectl get checluster --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)

    if [[ -n "$checluster_ns" ]]; then
      CHE_NAMESPACE="$checluster_ns"
      echo "✅ Found CheCluster in namespace: $CHE_NAMESPACE"
    fi
  fi
}
```

### Logging

Use consistent emoji-based logging for better visibility:

```bash
log_info()    { echo -e "ℹ️  $*" >&2; }
log_success() { echo -e "✅ $*" >&2; }
log_error()   { echo -e "❌ $*" >&2; }
```

### Background Process Management

Always track and clean up background processes:

```bash
# Start background watcher
watch_events &
PID_EVENTS_WATCH=$!

# Clean up on exit
stop_background_watchers() {
  local pids=()
  [[ -n "${PID_EVENTS_WATCH:-}" ]] && pids+=("$PID_EVENTS_WATCH")

  if [[ ${#pids[@]} -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
  fi
}

trap stop_background_watchers EXIT
```

## Getting Help

- Review existing code for patterns and conventions
- Check README.md files in each directory for module-specific documentation
- Test changes in a development cluster before submitting
- When in doubt, ask the repository maintainers

## Additional Notes

- The `outputs/` directory is git-ignored and used for test results
- Test plans in `test-plans/` use JSON format for configuration
- Metrics collection focuses on controller/webhook performance and DevWorkspace lifecycle
- The project uses Make targets as the primary entry point for common operations
