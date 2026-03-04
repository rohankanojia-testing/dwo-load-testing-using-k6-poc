# Makefile for DevWorkspace Load Testing
#
# Usage:
#   make test_load ARGS="--vus 10 --duration 30s"
#   make test_backup MAX_DEVWORKSPACES=20 BACKUP_MONITOR_DURATION=15

.PHONY: test_load test_webhook_load test_backup test_backup_incorrect

test_load:
	@echo "Starting DevWorkspace Controller Load Testing Script..." && \
	bash ./test-devworkspace-controller-load/runk6.sh $(ARGS) && \
	echo "Done"

test_webhook_load:
	@echo "Starting DevWorkspace Webhook Server Load Testing Script..." && \
	bash ./test-devworkspace-webhook-server-load/create-users-and-runk6.sh $(ARGS) && \
	echo "Done"

# Backup load testing with correct DWOC configuration
test_backup:
	@bash test-devworkspace-controller-load/backup/backup-load-test.sh \
		$(or $(MAX_DEVWORKSPACES),15) \
		$(or $(BACKUP_MONITOR_DURATION),30) \
		$(or $(LOAD_TEST_NAMESPACE),loadtest-devworkspaces) \
		$(or $(DWO_NAMESPACE),openshift-operators) \
		$(or $(REGISTRY_PATH),quay.io/rokumar) \
		$(or $(REGISTRY_SECRET),quay-push-secret) \
		correct

# Backup load testing with incorrect DWOC configuration (for testing failure scenarios)
test_backup_incorrect:
	@bash test-devworkspace-controller-load/backup/backup-load-test.sh \
		$(or $(MAX_DEVWORKSPACES),15) \
		$(or $(BACKUP_MONITOR_DURATION),30) \
		$(or $(LOAD_TEST_NAMESPACE),loadtest-devworkspaces) \
		$(or $(DWO_NAMESPACE),openshift-operators) \
		$(or $(REGISTRY_PATH),quay.io/rokumar) \
		$(or $(REGISTRY_SECRET),quay-push-secret) \
		incorrect
