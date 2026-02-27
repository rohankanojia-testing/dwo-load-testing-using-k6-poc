#!/bin/bash
# backup.sh
# Usage: ./backup.sh <max_devworkspaces>
# Example: ./backup.sh 2000
#
# Runs backup load testing with DWOC configuration set BEFORE load test execution

# Default max devworkspaces if not provided
MAX_DEVWORKSPACES=${1:-50}

# Adjust VU count relative to devworkspaces
# Example rule: 1 VU per 4 devworkspaces (tweak as needed)
MAX_VUS=$(( MAX_DEVWORKSPACES / 4 ))

echo "Running backup load test with --max-devworkspaces=$MAX_DEVWORKSPACES and --max-vus=$MAX_VUS"

# Check for required environment variables
if [[ -z "${QUAY_USERNAME:-}" ]] || [[ -z "${QUAY_PASSWORD:-}" ]]; then
  echo "⚠️  Warning: QUAY_USERNAME and QUAY_PASSWORD environment variables not set"
  echo "   Ensure the registry secret exists or set these variables:"
  echo "   export QUAY_USERNAME=your-username"
  echo "   export QUAY_PASSWORD=your-password"
  echo ""
fi

# Run backup load test using runk6.sh with backup testing enabled
bash test-devworkspace-controller-load/runk6.sh \
  --mode binary \
  --run-with-eclipse-che false \
  --max-vus ${MAX_VUS} \
  --create-automount-resources true \
  --max-devworkspaces ${MAX_DEVWORKSPACES} \
  --devworkspace-ready-timeout-seconds 3600 \
  --delete-devworkspace-after-ready false \
  --separate-namespaces false \
  --run-backup-test-hook true \
  --registry-path quay.io/rokumar \
  --dwoc-config-type correct \
  --registry-secret quay-push-secret \
  --backup-wait-minutes 30 \
  --test-duration-minutes 40
