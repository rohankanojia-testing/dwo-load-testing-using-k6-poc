# Makefile for DevWorkspace Load Testing

# Default arguments can be overridden at runtime:
#   make test_load ARGS="--vus 10 --duration 30s"

.PHONY: test_load test_webhook_load

test_load:
	@echo "Starting DevWorkspace Controller Load Testing Script..." && \
	bash ./test-devworkspace-controller-load/runk6.sh $(ARGS) && \
	echo "Done"

test_webhook_load:
	@echo "Starting DevWorkspace Webhook Server Load Testing Script..." && \
	bash ./test-devworkspace-webhook-server-load/create-users-and-runk6.sh $(ARGS) && \
	echo "Done"
