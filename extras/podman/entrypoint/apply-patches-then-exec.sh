#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] start"

export VLLM_PATCH_ENV=${VLLM_PATCH_ENV:-container}

# Normalize CRLF in podman helper scripts (best effort)
for dir in /workspace/extras/podman /workspace/extras/patches; do
  [[ -d "$dir" ]] || continue
  find "$dir" -type f -name '*.sh' -print0 2>/dev/null | while IFS= read -r -d '' f; do
    if grep -q $'\r' "$f" 2>/dev/null; then
      tmp="$f.tmp.$$"
      tr -d '\r' < "$f" > "$tmp" 2>/dev/null || cp "$f" "$tmp"
      mv "$tmp" "$f" || true
    fi
  done
done || true

if command -v git >/dev/null 2>&1; then
  git config --global --add safe.directory /workspace >/dev/null 2>&1 || true
fi

export PYTHON_PATCH_OVERLAY=${PYTHON_PATCH_OVERLAY:-1}

OVERLAY_HELPER=/workspace/extras/patches/apply_patches_overlay.sh
LEGACY_HELPER=/workspace/extras/patches/apply_patches.sh

# Only apply patches at container start when explicitly requested.
# This avoids mutating the bind-mounted workspace during interactive shells
# or image-only builds. Dev setup will apply and then reset as needed.
PATCH_RAN=0
if [[ "${APPLY_PATCHES_ON_START:-0}" == "1" ]]; then
  if [[ -f "$OVERLAY_HELPER" ]]; then
    echo "[entrypoint] applying patches via overlay helper (overlay=$PYTHON_PATCH_OVERLAY)"
    bash "$OVERLAY_HELPER" || true
    PATCH_RAN=1
  elif command -v apply-vllm-patches >/dev/null 2>&1; then
    echo "[entrypoint] applying patches via helper (overlay=$PYTHON_PATCH_OVERLAY)"
    apply-vllm-patches || true
    PATCH_RAN=1
  elif [[ -f "$LEGACY_HELPER" ]]; then
    echo "[entrypoint] applying patches via workspace script"
    bash "$LEGACY_HELPER" || true
    PATCH_RAN=1
  else
    echo "[entrypoint] no patch helper found" >&2
  fi
else
  echo "[entrypoint] skipping patch application at start (APPLY_PATCHES_ON_START=${APPLY_PATCHES_ON_START:-0})"
fi

if command -v git >/dev/null 2>&1 && [[ $PATCH_RAN -eq 1 ]]; then
  dirty=$(git status --porcelain --untracked-files=no)
  if [[ -n "$dirty" ]]; then
    warn_limit=${PATCH_OVERLAY_WARN_LIMIT:-20}
    if [[ ! "$warn_limit" =~ ^[0-9]+$ ]]; then
      warn_limit=20
    fi
    dirty_count=$(printf '%s\n' "$dirty" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "[entrypoint] WARNING: tracked files modified during patch application (${dirty_count})" >&2
    if (( warn_limit > 0 )); then
      printf '%s\n' "$dirty" | head -n "$warn_limit" >&2
      if (( dirty_count > warn_limit )); then
        echo "[entrypoint] ... suppressed $((dirty_count - warn_limit)) additional entries (set PATCH_OVERLAY_WARN_LIMIT to adjust)" >&2
      fi
    else
      echo "[entrypoint] diff output suppressed (PATCH_OVERLAY_WARN_LIMIT=$warn_limit)" >&2
    fi
  fi
fi

echo "[entrypoint] exec: $*"
if [[ -n "${PYTHONPATH:-}" ]]; then export PYTHONPATH; fi
exec "$@"
