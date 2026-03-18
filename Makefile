# Makefile for DevWorkspace Load Testing
#
# Usage:
#   make test_load ARGS="--vus 10 --duration 30s"
#   make test_backup MAX_DEVWORKSPACES=20 BACKUP_MONITOR_DURATION=15
#   make test_backup DWOC_CONFIG_TYPE=incorrect SEPARATE_NAMESPACE=true
#   make test_backup BACKUP_SCHEDULE="*/5 * * * *"

.PHONY: test_load test_webhook_load test_backup

test_load:
	@echo "Starting DevWorkspace Controller Load Testing Script..." && \
	bash ./test-devworkspace-controller-load/runk6.sh $(ARGS) && \
	echo "Done"

test_webhook_load:
	@echo "Starting DevWorkspace Webhook Server Load Testing Script..." && \
	bash ./test-devworkspace-webhook-server-load/create-users-and-runk6.sh $(ARGS) && \
	echo "Done"

# Backup load testing
# DWOC_CONFIG_TYPE: "correct" (default), "incorrect" (for testing failure scenarios), or "openshift-internal"
# BACKUP_SCHEDULE: Cron schedule for backups (default: "*/2 * * * *" - every 2 minutes)
test_backup:
	@bash test-devworkspace-controller-load/backup/backup-load-test.sh \
		$(or $(MAX_DEVWORKSPACES),15) \
		$(or $(BACKUP_MONITOR_DURATION),30) \
		$(or $(LOAD_TEST_NAMESPACE),loadtest-devworkspaces) \
		$(or $(DWO_NAMESPACE),openshift-operators) \
		$(or $(REGISTRY_PATH),quay.io/rokumar) \
		$(or $(REGISTRY_SECRET),quay-push-secret) \
		$(or $(DWOC_CONFIG_TYPE),correct) \
		$(or $(SEPARATE_NAMESPACE),false) \
		"$(or $(BACKUP_SCHEDULE),*/2 * * * *)"
