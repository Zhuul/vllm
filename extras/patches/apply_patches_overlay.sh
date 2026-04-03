#!/usr/bin/env bash
set -euo pipefail

if [[ "${VLLM_PATCH_ENV:-}" != "container" ]]; then
  echo "[patches] Skipping host invocation (set VLLM_PATCH_ENV=container inside container)" >&2
  exit 0
fi

if grep -q $'\r' "$0" 2>/dev/null; then
  tmp_self=$(mktemp /tmp/apply_patches_overlay_self.XXXXXX.sh)
  tr -d '\r' < "$0" > "$tmp_self" || cp "$0" "$tmp_self"
  chmod +x "$tmp_self" 2>/dev/null || true
  exec "$tmp_self" "$@"
fi

ROOT_DIR=${ROOT_DIR:-$(pwd)}
PATCH_DIR="${PATCH_DIR:-$ROOT_DIR/extras/patches}"
PATCH_MANAGER="$ROOT_DIR/extras/tools/patch_manager.py"
PATCH_CONFIG="$PATCH_DIR/patches.json"
PATCH_TRACK_FILE=${PATCH_TRACK_FILE:-/opt/work/tmp/vllm_patched_files.txt}

cd "$ROOT_DIR"

if [[ ! -f "$PATCH_MANAGER" ]]; then
  echo "[patches] ERROR: patch manager not found at $PATCH_MANAGER" >&2
  exit 1
fi

if [[ ! -f "$PATCH_CONFIG" ]]; then
  echo "[patches] ERROR: patch config not found at $PATCH_CONFIG" >&2
  exit 1
fi

if ! command -v python >/dev/null 2>&1; then
  echo "[patches] ERROR: python is required for patch_manager.py" >&2
  exit 1
fi

echo "[patches] Delegating to patch_manager.py (overlay mode)"
python "$PATCH_MANAGER" --config "$PATCH_CONFIG" --overlay-mode --track-file "$PATCH_TRACK_FILE"
