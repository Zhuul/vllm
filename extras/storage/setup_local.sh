#!/usr/bin/env bash
set -euo pipefail

# Prepare a local directory for models and ensure reasonable permissions.
TARGET=${1:-/mnt/ml-models}
mkdir -p "$TARGET"
chmod 775 "$TARGET" || true

echo "Model storage prepared at: $TARGET"
