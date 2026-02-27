# Backup/Restore Load Testing Scripts

This directory contains all scripts related to backup/restore load testing for the DevWorkspace Operator.

## Directory Structure

```
backup/
├── README.md                      # This file
├── run-backup-tests.sh           # Main entry point - orchestrates all backup testing
├── setup-backup-secret.sh        # Registry secret creation and validation
├── backup-testing-hook.sh        # Core backup testing logic (stop workspaces, monitor, report)
├── configure-dwoc-backup.sh      # DevWorkspaceOperatorConfig management
└── monitor-backup-jobs.sh        # Backup Job monitoring and metrics collection
```

## Main Entry Point

**`run-backup-tests.sh`** is the primary entry point called by `runk6.sh`. It handles:
1. Registry secret setup (from `QUAY_USERNAME`/`QUAY_PASSWORD` environment variables)
2. Parameter validation
3. Orchestration of backup testing workflow

## Usage from runk6.sh

The main script `runk6.sh` calls backup testing with a single slim call:

```bash
source test-devworkspace-controller-load/backup/run-backup-tests.sh
run_backup_tests \
  "$LOAD_TEST_NAMESPACE" \
  "$REGISTRY_PATH" \
  "$DWOC_CONFIG_TYPE" \
  "$SEPARATE_NAMESPACES" \
  "$REGISTRY_SECRET" \
  "$DWO_NAMESPACE" \
  "$BACKUP_WAIT_MINUTES"
```

All backup logic is contained within this directory - `runk6.sh` doesn't need to know implementation details.

## Direct Usage

Each script can also be run directly for testing/debugging:

### Setup Registry Secret
```bash
export QUAY_USERNAME=myuser
export QUAY_PASSWORD=mypass
./setup-backup-secret.sh setup
```

### Run Full Backup Tests
```bash
export QUAY_USERNAME=myuser
export QUAY_PASSWORD=mypass
./run-backup-tests.sh loadtest-devworkspaces quay.io/myuser correct true
```

### Configure DWOC
```bash
./configure-dwoc-backup.sh correct quay.io/myuser quay-push-secret
```

### Monitor Backup Jobs (standalone)
```bash
source ./monitor-backup-jobs.sh
watch_backup_jobs
# Wait for jobs...
generate_backup_report
```

## Environment Variables

### Required (if secret doesn't exist)
- `QUAY_USERNAME` - Registry username
- `QUAY_PASSWORD` - Registry password

### Optional
- `DWO_CONFIG_NAME` - DevWorkspaceOperatorConfig name (default: `devworkspace-operator-config`)
- `DWO_NAMESPACE` - DevWorkspace Operator namespace (default: `openshift-operators`)
- `BACKUP_JOB_LABEL` - Label selector for backup Jobs (default: `devworkspace.devfile.io/backup-job=true`)

## Script Responsibilities

### run-backup-tests.sh
- Main orchestrator
- Secret setup and validation
- Parameter validation
- Calls backup-testing-hook.sh

### setup-backup-secret.sh
- Creates docker-registry secret from environment variables
- Adds required label: `controller.devfile.io/watch-secret=true`
- Validates existing secrets
- Idempotent (safe to run multiple times)

### backup-testing-hook.sh
- Stop all DevWorkspaces
- Configure DWOC for backup
- Start monitoring
- Wait for backup Jobs
- Collect metrics
- Reset DWOC
- Generate final report

### configure-dwoc-backup.sh
- Apply correct/incorrect DWOC backup configuration
- Reset DWOC configuration
- Validate configuration

### monitor-backup-jobs.sh
- Watch backup Jobs in real-time
- Collect Job metrics (success/failure rates, durations)
- Analyze failed Jobs
- Generate comprehensive reports

## Design Principles

1. **Separation of Concerns**: Each script has a clear, focused responsibility
2. **Composability**: Scripts can be used independently or composed together
3. **Automation**: Secrets and configuration are handled automatically
4. **Idempotency**: Safe to run multiple times without side effects
5. **Clear Entry Point**: `run-backup-tests.sh` is the single entry point for external callers

## Testing

To test the backup scripts in isolation:

```bash
# 1. Set credentials
export QUAY_USERNAME=testuser
export QUAY_PASSWORD=testpass

# 2. Run smoke test
./run-backup-tests.sh my-test-namespace quay.io/testuser correct false

# 3. Check results
cat ../../logs/*_backup_summary.txt
```

## Documentation

For full documentation on backup/restore load testing, see:
- `../BACKUP_LOAD_TESTING.md` - Complete user guide
- `../../test-plans/backup-restore-*.json` - Test plan examples
