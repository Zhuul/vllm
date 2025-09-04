#!/usr/bin/env bash
set -euo pipefail

# Apply repo patches if available; best-effort, normalization handled inside helper.
if command -v apply-vllm-patches >/dev/null 2>&1; then
  echo "[entrypoint] applying patches..."
  apply-vllm-patches || true
fi

# If first args are `bash -lc <path-to-script.sh>` (single token, no spaces), normalize CRLF then exec
if [[ "${1-}" == "bash" && "${2-}" == "-lc" ]]; then
  arg3="${3-}"
  # Only handle when it's a single token path ending in .sh with no spaces or shell operators
  if [[ -n "$arg3" && "$arg3" != *' '* && "$arg3" != *';'* && "$arg3" != *'&'* && "$arg3" != *'|'* && "$arg3" == *.sh ]]; then
    # Resolve to filesystem path if it exists
    if [[ -f "$arg3" ]]; then
      SRC_SCRIPT="$arg3"
      TMP_SCRIPT="$(mktemp /tmp/entry-XXXX.sh)"
      tr -d '\r' < "$SRC_SCRIPT" > "$TMP_SCRIPT" 2>/dev/null || cp "$SRC_SCRIPT" "$TMP_SCRIPT"
      chmod +x "$TMP_SCRIPT" 2>/dev/null || true
      exec bash -lc "$TMP_SCRIPT"
    fi
  fi
fi

exec "$@"
