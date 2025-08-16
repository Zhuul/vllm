#!/usr/bin/env bash
# Robust setup entrypoint: prefer extras/dev-setup.sh, fallback to extras/old/dev-setup.sh,
# otherwise use the image-provided /home/vllmuser/setup_vllm_dev.sh.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd)
EXTRAS_DIR=$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)

try_exec() {
	local target="$1"
	if [[ -f "$target" ]]; then
		chmod +x "$target" 2>/dev/null || true
		exec "$target" "$@"
	fi
}

# 1) Current canonical path
if [[ -f "${EXTRAS_DIR}/dev-setup.sh" ]]; then
	chmod +x "${EXTRAS_DIR}/dev-setup.sh" 2>/dev/null || true
	exec "${EXTRAS_DIR}/dev-setup.sh" "$@"
fi

# 2) Legacy archived location
if [[ -f "${EXTRAS_DIR}/old/dev-setup.sh" ]]; then
	chmod +x "${EXTRAS_DIR}/old/dev-setup.sh" 2>/dev/null || true
	exec "${EXTRAS_DIR}/old/dev-setup.sh" "$@"
fi

# 3) Fallback to image helper
if command -v /home/vllmuser/setup_vllm_dev.sh >/dev/null 2>&1 || [[ -f /home/vllmuser/setup_vllm_dev.sh ]]; then
	exec /home/vllmuser/setup_vllm_dev.sh "$@"
fi

echo "[setup] No setup script found at extras/dev-setup.sh or extras/old/dev-setup.sh, and no image helper present." >&2
exit 1
