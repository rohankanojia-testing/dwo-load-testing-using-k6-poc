#!/usr/bin/env bash
set -euo pipefail

# Interactive script to convert pasted k6 output to CSV
#
# Usage: ./paste-to-csv.sh

echo "Paste your k6 output below, then press Ctrl+D (EOF) when done:"
echo "---"

# Read all input until EOF (Ctrl+D)
INPUT=$(cat)

# Prompt for target and namespace
read -p "Enter DW target (e.g., 1000, 1500): " TARGET
read -p "Enter namespace type (Single or Separate): " NAMESPACE

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the main script
echo "$INPUT" | "${SCRIPT_DIR}/k6-output-to-csv.sh" --target "$TARGET" --namespace "$NAMESPACE"
