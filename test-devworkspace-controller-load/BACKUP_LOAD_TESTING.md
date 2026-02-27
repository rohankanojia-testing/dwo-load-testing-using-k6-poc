# Backup/Restore Load Testing for DevWorkspace Operator

This document describes how to run backup/restore load tests for the DevWorkspace Operator to validate backup functionality under high load conditions.

## Overview

The backup/restore load tests validate the DevWorkspace Operator's backup feature ([CRW-9437](https://issues.redhat.com/browse/CRW-9437)) by:

1. Creating a configurable number of DevWorkspaces (50, 500, or 2000+)
2. Stopping all workspaces to trigger backup Jobs
3. Monitoring backup Job creation and completion
4. Collecting metrics on backup success/failure rates and resource usage
5. Testing both correct and incorrect DWOC configurations

**Key Features:**
- Runs as a **post-operation hook** after normal load testing completes
- Tests with workspaces in separate namespaces (simulating multiple users)
- Supports multiple scale levels: 50 (smoke), 500 (medium), 2000+ (production)
- Validates both successful backup scenarios and failure scenarios

## Prerequisites

### Required

1. **Kubernetes/OpenShift cluster** with DevWorkspace Operator installed
2. **Backup feature enabled** in DevWorkspace Operator
3. **Registry credentials** for storing backup images:
   - Quay.io account (recommended)
   - OR OpenShift internal registry access
4. **Environment variables** for registry authentication:
   ```bash
   export QUAY_USERNAME=your-username
   export QUAY_PASSWORD=your-password
   ```

   **Note:** The registry secret will be automatically created from these environment variables when you run the tests. If the secret already exists, it will be validated and reused.

### Cluster Resources

**For smoke tests (50 workspaces):**
- Minimal cluster (CRC, small OpenShift/K8s cluster)
- ~4-8 GB RAM, 4-8 vCPUs

**For medium scale (500 workspaces):**
- Medium cluster
- ~32-64 GB RAM, 16-32 vCPUs

**For production scale (2000+ workspaces):**
- Large/production cluster
- ~128+ GB RAM, 64+ vCPUs
- Sufficient etcd and storage capacity

## Test Scenarios

### Case 1: Correct DWOC Configuration

**What it tests:**
- Normal backup operation under load
- Backup Jobs created successfully for stopped workspaces
- Backups complete and images pushed to registry

**Expected results:**
- ~N backup Jobs created (one per workspace)
- >95% success rate
- No operator crashes
- Stable resource usage

### Case 2: Incorrect DWOC Configuration

**What it tests:**
- Backup failure handling under load
- Multiple backup Job creation due to misconfiguration
- Resource impact of failing backups

**Configuration:** Intentional typo in registry path (e.g., `quay.io` → `quay.i`)

**Expected results:**
- Multiple backup Jobs per workspace
- High failure rate
- Resource spike possible
- Failed Jobs logged for analysis

## Running the Tests

### Quick Start (Smoke Test)

Test with 50 workspaces to validate setup:

```bash
# Set registry credentials (required)
export QUAY_USERNAME=your-username
export QUAY_PASSWORD=your-password

# Run smoke test plan
./scripts/run_all_loadtests.sh test-plans/backup-restore-smoke-test-plan.json
```

**Before running:**
1. Edit `test-plans/backup-restore-smoke-test-plan.json`
2. Replace `quay.io/CHANGEME` with your actual registry path (e.g., `quay.io/yourusername`)
3. Set `QUAY_USERNAME` and `QUAY_PASSWORD` environment variables

### Medium Scale (500 Workspaces)

```bash
# Run correct config test
./scripts/run_all_loadtests.sh test-plans/backup-restore-correct-config-test-plan.json

# Run incorrect config test
./scripts/run_all_loadtests.sh test-plans/backup-restore-incorrect-config-test-plan.json
```

### Production Scale (2000 Workspaces)

1. Enable the 2000 workspace test in the JSON file:
   ```json
   {
     "name": "backup_2000_correct_config",
     "enabled": true,
     ...
   }
   ```

2. Run the test:
   ```bash
   ./scripts/run_all_loadtests.sh test-plans/backup-restore-correct-config-test-plan.json
   ```

### Direct Execution (Custom Parameters)

```bash
make test_load ARGS=" \
  --mode binary \
  --max-vus 50 \
  --max-devworkspaces 50 \
  --delete-devworkspace-after-ready false \
  --separate-namespaces true \
  --devworkspace-ready-timeout-seconds 900 \
  --test-duration-minutes 15 \
  --run-backup-test-hook true \
  --dwoc-config-type correct \
  --registry-path quay.io/yourusername \
  --registry-secret quay-push-secret \
  --backup-wait-minutes 15"
```

## Test Parameters

| Parameter | Description | Default | Values |
|-----------|-------------|---------|--------|
| `--run-backup-test-hook` | Enable backup testing hook | `false` | `true`, `false` |
| `--dwoc-config-type` | DWOC configuration type | `correct` | `correct`, `incorrect` |
| `--registry-path` | Registry path for backups | (required) | `quay.io/username` |
| `--registry-secret` | Registry auth secret name | (required) | `quay-push-secret` |
| `--backup-wait-minutes` | Max wait for backup completion | `30` | `15-60` |
| `--separate-namespaces` | Use separate namespaces per workspace | `false` | `true`, `false` |
| `--delete-devworkspace-after-ready` | **MUST be `false`** for backup tests | `true` | `false` |

## What Happens During the Test

### Phase 1: Normal Load Test
1. Creates N DevWorkspaces (running state)
2. Waits for all workspaces to become Ready
3. Monitors operator and etcd metrics

### Phase 2: Backup Testing Hook (Post-Operation)
1. **Stop all workspaces** - Patches all DevWorkspaces with `started: false`
2. **Configure DWOC** - Applies backup configuration (correct or incorrect)
3. **Start monitoring** - Watches for backup Job creation
4. **Wait for Jobs** - Monitors Jobs until completion or timeout
5. **Collect metrics** - Counts succeeded/failed Jobs, resource usage
6. **Generate report** - Creates comprehensive backup summary
7. **Reset DWOC** - Disables backup configuration
8. **Cleanup** - Returns control for normal teardown

### Phase 3: Cleanup
- Deletes all DevWorkspaces and namespaces
- Cleans up test resources

## Metrics Collected

### Job Metrics
- Total backup Jobs created
- Jobs succeeded
- Jobs failed
- Jobs running/pending
- Success rate / Failure rate
- Average Job duration

### Resource Metrics
- Backup Job pod CPU usage (average)
- Backup Job pod memory usage (average)
- Operator CPU/memory during backup operations
- etcd CPU/memory during backup operations

### Failure Analysis
- Failed Job details
- Pod logs from failed Jobs
- Error patterns

## Output Files

All output is saved in the `logs/` directory:

| File | Description |
|------|-------------|
| `<timestamp>_backup_jobs_watch.log` | Real-time backup Job events |
| `<timestamp>_backup_jobs_metrics.txt` | Job metrics summary |
| `<timestamp>_backup_jobs_failures.log` | Failed Job details and logs |
| `<timestamp>_backup_summary.txt` | Comprehensive report |
| `<timestamp>_events.log` | Kubernetes events (from main test) |
| `<timestamp>_dw_watch.log` | DevWorkspace watch logs (from main test) |

## Interpreting Results

### Successful Test (Correct Config)

```
Total backup Jobs: 50
Succeeded: 48
Failed: 2
Running/Pending: 0

Success rate: 96.00%
Failure rate: 4.00%
```

**Expected:**
- Success rate >95%
- Failed Jobs <5%
- All Jobs complete within timeout
- No operator restarts

### Expected Failure Pattern (Incorrect Config)

```
Total backup Jobs: 150
Succeeded: 0
Failed: 150
Running/Pending: 0

Success rate: 0.00%
Failure rate: 100.00%
```

**Expected:**
- Multiple Jobs per workspace (due to retries)
- 100% failure rate
- Resource spike during Job creation
- Registry authentication/pull errors in logs

## Troubleshooting

### No Backup Jobs Created

**Possible causes:**
- Workspaces not actually stopped
- DWOC backup configuration not applied
- Backup cron schedule not triggering

**Solutions:**
```bash
# Verify workspaces are stopped
kubectl get dw -A -o jsonpath='{.items[*].spec.started}'

# Verify DWOC configuration
kubectl get devworkspaceoperatorconfig devworkspace-operator-config -n openshift-operators -o yaml

# Check operator logs
kubectl logs -n openshift-operators -l app.kubernetes.io/name=devworkspace-controller --tail=100
```

### Backup Jobs Failing (Correct Config)

**Possible causes:**
- Registry credentials invalid
- Registry path incorrect
- Network issues
- Storage quota exceeded

**Solutions:**
```bash
# Verify secret exists and is labeled
kubectl get secret quay-push-secret -n openshift-operators --show-labels

# Test registry credentials
kubectl create job test-backup --image=quay.io/username/test:latest -- echo "test"

# Check Job pod logs
kubectl logs -n <namespace> <backup-job-pod-name>
```

### Backup Jobs Stuck in Pending

**Possible causes:**
- Insufficient cluster resources
- Image pull errors
- Pod scheduling issues

**Solutions:**
```bash
# Check pod status
kubectl get pods -A | grep backup

# Describe stuck pod
kubectl describe pod <backup-job-pod-name> -n <namespace>

# Check node resources
kubectl top nodes
```

### Test Timeout

**Possible causes:**
- Too many workspaces for cluster capacity
- Backup Jobs taking too long
- Network/registry latency

**Solutions:**
- Increase `--backup-wait-minutes`
- Reduce `--max-devworkspaces`
- Use more powerful cluster
- Check registry performance

## Best Practices

1. **Start small** - Run smoke test (50 workspaces) first
2. **Validate setup** - Ensure registry credentials work before large scale tests
3. **Monitor resources** - Watch cluster CPU/memory during tests
4. **Progressive scaling** - Test 50 → 500 → 2000 incrementally
5. **Clean between runs** - Ensure cluster is clean before each test
6. **Save logs** - Archive logs directory after each test run

## Example Workflow

```bash
# 1. Set registry credentials
export QUAY_USERNAME=myuser
export QUAY_PASSWORD=mypass

# 2. Update test plans with your registry path
sed -i 's/quay.io\/CHANGEME/quay.io\/myuser/g' test-plans/backup-restore-*.json

# 3. Run smoke test to validate
# (Registry secret will be created automatically from environment variables)
./scripts/run_all_loadtests.sh test-plans/backup-restore-smoke-test-plan.json

# 4. Review results
cat logs/*_backup_summary.txt

# 5. If smoke test passes, run medium scale
./scripts/run_all_loadtests.sh test-plans/backup-restore-correct-config-test-plan.json

# 6. Archive logs
tar -czf backup-test-results-$(date +%Y%m%d).tar.gz logs/
```

## Additional Notes

- Backup testing runs **after** normal load test completes
- Workspaces can be in **single or separate namespaces** (separate namespaces simulates multiple users)
- Workspaces must **not be deleted** after ready (kept for backup)
- DWOC configuration is **reset** after backup testing completes
- Compatible with both Quay.io and OpenShift internal registry

## Support

For issues or questions:
- Check operator logs: `kubectl logs -n openshift-operators -l app.kubernetes.io/name=devworkspace-controller`
- Review CRW-9437: https://issues.redhat.com/browse/CRW-9437
- Consult main README: `/Users/rokumar/work/repos/dwo-k6-load-testing/README.md`
