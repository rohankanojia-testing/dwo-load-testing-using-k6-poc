# DevWorkspace Backup Load Tests

This directory contains load tests for DevWorkspace backup functionality, which allows workspaces to be backed up to a container registry when stopped.

## Overview

The backup load tests verify:
- Backup job creation when DevWorkspaces are stopped
- Backup success rate and reliability
- System performance during backup operations
- Operator and etcd resource usage

## Test Modes

### Namespace Modes

- **Single Namespace** (`--separate-namespaces false`): All DevWorkspaces created in one namespace
- **Separate Namespaces** (`--separate-namespaces true`): Each DevWorkspace in its own namespace

### DWOC Configuration Modes

- **Correct Mode** (`correct`): DWOC properly configured with backup enabled, registry path, and auth secret (external registry like quay.io)
  - Pushes to external registry as OCI artifacts
  - Requires registry credentials (secret)
  - Backup schedule: every 2 hours (`0 */2 * * *`)

- **Incorrect Mode** (`incorrect`): DWOC misconfigured (for testing failure scenarios)
  - Intentionally broken registry path to test failure handling
  - Jobs will retry failed pods up to backOffLimit (typically 6 retries)
  - Test waits until jobs permanently fail or monitoring duration expires
  - Useful for testing operator behavior under failure conditions and retry logic
  - Backup schedule: every 2 hours (`0 */2 * * *`) - prevents new jobs during test

- **OpenShift Internal Mode** (`openshift-internal`): DWOC configured to use OpenShift's internal image registry
  - Pushes to ImageStreamTags in the workspace namespace
  - Uses service account token for authentication (no secret required)
  - Auto-detects the registry route or uses internal service
  - Includes `--insecure` flag for ORAS to handle self-signed certificates
  - Backup schedule: every 2 hours (`0 */2 * * *`)

## Prerequisites

- Kubernetes cluster with DevWorkspace Operator installed
- **For external registry mode**: Container registry credentials (for pushing backup images)
- **For OpenShift internal mode**: OpenShift cluster with internal image registry enabled
- k6 load testing tool installed
- kubectl configured with cluster access

## Running Tests

Use the `make test_backup` target to run backup load tests. The test supports both single and separate namespace modes, and correct or incorrect DWOC configurations.

### Single Namespace + Correct DWOC Configuration (Default)

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret
```

### Separate Namespaces + Correct DWOC Configuration

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  SEPARATE_NAMESPACE=true
```

### Single Namespace + Incorrect DWOC Configuration

For testing failure scenarios:

```bash
make test_backup \
  MAX_DEVWORKSPACES=20 \
  BACKUP_MONITOR_DURATION=15 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  DWOC_CONFIG_TYPE=incorrect
```

### Separate Namespaces + Incorrect DWOC Configuration

```bash
make test_backup \
  MAX_DEVWORKSPACES=20 \
  BACKUP_MONITOR_DURATION=15 \
  REGISTRY_PATH=quay.io/your-username \
  REGISTRY_SECRET=your-registry-secret \
  DWOC_CONFIG_TYPE=incorrect \
  SEPARATE_NAMESPACE=true
```

### OpenShift Internal Registry (Auto-detect)

For OpenShift clusters, you can use the internal image registry with automatic route detection:

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH="" \
  REGISTRY_SECRET="" \
  DWOC_CONFIG_TYPE=openshift-internal \
  SEPARATE_NAMESPACE=true
```

Or using the `backup.sh` wrapper:

```bash
./backup.sh 50 30 loadtest-devworkspaces openshift-operators "" "" openshift-internal true
```

### OpenShift Internal Registry (Custom Path)

If you need to specify a custom registry path (e.g., for CRC):

```bash
make test_backup \
  MAX_DEVWORKSPACES=50 \
  BACKUP_MONITOR_DURATION=30 \
  REGISTRY_PATH=default-route-openshift-image-registry.apps-crc.testing \
  REGISTRY_SECRET="" \
  DWOC_CONFIG_TYPE=openshift-internal \
  SEPARATE_NAMESPACE=true
```

## Test Workflow

The complete backup load test (`backup-load-test.sh`) performs these phases:

1. **Phase 1: Configure DWOC for Backup**
   - Sets up registry credentials
   - Enables backup in DevWorkspaceOperatorConfig
   - Configures registry path and auth secret

2. **Phase 2: Create DevWorkspaces**
   - Creates specified number of DevWorkspaces
   - Waits for them to reach Ready state
   - Skips cleanup to leave workspaces for backup

3. **Phase 3: Backup Monitoring**
   - Stops all DevWorkspaces
   - Monitors backup job creation and completion
   - Tracks metrics (jobs, pods, success rate, resource usage)

4. **Phase 4: Cleanup**
   - Removes backup jobs
   - Deletes DevWorkspaces
   - Resets DWOC configuration

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `MAX_DEVWORKSPACES` | Number of DevWorkspaces to create | `15` |
| `BACKUP_MONITOR_DURATION` | How long to monitor backups (minutes) | `30` |
| `LOAD_TEST_NAMESPACE` | Namespace for DevWorkspaces (single mode) | `loadtest-devworkspaces` |
| `DWO_NAMESPACE` | DevWorkspace Operator namespace | `openshift-operators` |
| `REGISTRY_PATH` | Container registry path for backups | `quay.io/rokumar` |
| `REGISTRY_SECRET` | Secret name for registry auth | `quay-push-secret` |
| `DWOC_CONFIG_TYPE` | DWOC config mode: `correct` or `incorrect` | `correct` |
| `SEPARATE_NAMESPACE` | Use separate namespaces per workspace | `false` |

## Metrics Collected

The test collects comprehensive metrics:

### Backup Metrics
- `backup_jobs_total` - Total backup jobs created across all namespaces
- `backup_pods_total` - Total backup pods created (includes all retry attempts; e.g., a job with 6 retries creates 7 pods total)
- `backup_jobs_succeeded` - Successfully completed backup jobs
- `backup_jobs_failed` - Jobs that permanently failed (hit backOffLimit, not just first pod failure)
- `backup_jobs_running` - Currently running/pending backup jobs (includes jobs actively retrying)
- `backup_success_rate` - Percentage of successful backups
- `backup_job_duration` - Time taken for backup jobs to complete
- `workspaces_backed_up` - Number of workspaces successfully backed up
- `imagestreams_created` - Number of ImageStreams created (OpenShift internal registry mode only)
- `imagestreams_expected` - Number of ImageStreams expected (OpenShift internal registry mode only)

### System Metrics
- `average_operator_cpu` - DWO CPU usage
- `average_operator_memory` - DWO memory usage
- `average_etcd_cpu` - etcd CPU usage
- `average_etcd_memory` - etcd memory usage
- `operator_cpu_violations` - Times operator exceeded CPU threshold
- `operator_mem_violations` - Times operator exceeded memory threshold
- `operator_pod_restarts_total` - Operator pod restart count
- `etcd_pod_restarts_total` - etcd pod restart count

## Output

After test completion, you'll find:
- `devworkspace-load-test-report.html` - DevWorkspace creation phase report
- `backup-load-test-report.html` - Backup monitoring phase report with all metrics

## Registry Secret Setup

Before running tests, create a registry push secret:

```bash
kubectl create secret docker-registry your-registry-secret \
  --docker-server=quay.io \
  --docker-username=your-username \
  --docker-password=your-password \
  -n openshift-operators

kubectl label secret your-registry-secret \
  controller.devfile.io/mount-to-devworkspace=true \
  controller.devfile.io/watch-secret=true \
  -n openshift-operators
```

## Troubleshooting

### No backup jobs created

- Verify DWOC backup configuration: `kubectl get dwoc devworkspace-operator-config -o yaml`
- Check that DevWorkspaces are stopped: `kubectl get dw -A`
- Ensure registry secret exists and has proper labels

### Backup jobs failing

- Check job logs: `kubectl logs job/devworkspace-backup-xxxxx`
- Verify registry credentials are correct
- Ensure registry path is accessible and writable

### Metrics not collected

- Ensure operator pod is running: `kubectl get pods -n openshift-operators`
- Check etcd namespace matches your cluster (OpenShift vs vanilla K8s)
- Verify RBAC permissions for k6-backup-tester ServiceAccount

## Notes

- In **separate namespaces mode**, each DevWorkspace gets its own namespace (e.g., `dw-test-1-namespace`)
- Backup jobs are created in the same namespace as their DevWorkspace
- Metrics are collected **cluster-wide** using label selectors, so they work across all namespaces
- The **incorrect DWOC mode** is useful for testing failure scenarios and error handling
