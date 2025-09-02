#!/usr/bin/env bash
set -euo pipefail

# Apply repo patches if available; best-effort, normalization handled inside helper.
if command -v apply-vllm-patches >/dev/null 2>&1; then
  apply-vllm-patches || true
fi

exec "$@"
