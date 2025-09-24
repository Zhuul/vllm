#!/usr/bin/env bash
# Robust setup entrypoint: prefer extras/dev-setup.sh,
# otherwise use the image-provided /home/vllmuser/setup_vllm_dev.sh.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd)
EXTRAS_DIR=$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)

try_exec() {
	local target="$1"
	if [[ -f "$target" ]]; then
		# Normalize CRLF and avoid chmod on mounted FS
		local tmp
		tmp="$(mktemp /tmp/dev-setup-target.XXXX.sh)"
		tr -d '\r' < "$target" > "$tmp" 2>/dev/null || cp "$target" "$tmp"
		chmod +x "$tmp" 2>/dev/null || true
		exec "$tmp" "$@"
	fi
}

# 1) Current canonical path
if [[ -f "${EXTRAS_DIR}/dev-setup.sh" ]]; then
	try_exec "${EXTRAS_DIR}/dev-setup.sh" "$@"
fi

# 2) Fallback: perform a minimal editable install inline (avoid chmod on /tmp)
echo "🔧 Setting up vLLM (inline fallback)..."
cd /workspace

# Ensure patches applied before building
if command -v apply-vllm-patches >/dev/null 2>&1; then
	apply-vllm-patches || true
fi

# Prefer /opt/work/tmp (mounted volume) if available, else /tmp
if [[ -d /opt/work ]]; then
	export TMPDIR=/opt/work/tmp
else
	export TMPDIR=/tmp
fi
mkdir -p "$TMPDIR" || true

# Build env knobs
export CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-4}
export VLLM_INSTALL_PUNICA_KERNELS=${VLLM_INSTALL_PUNICA_KERNELS:-0}
export MAX_JOBS=${MAX_JOBS:-4}
# CUDA 13 toolchain dropped SM70/75; ensure we don't pass them to nvcc
export TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-"8.0 8.6 8.9 9.0 12.0 13.0"}
export CUDAARCHS=${CUDAARCHS:-"80;86;89;90;120"}

# Install Python deps from repo (torch stack already in image)
if [[ -f requirements/common.txt ]]; then
	pip install -r requirements/common.txt || true
fi

# Avoid slow git describe during setuptools_scm by providing a pretend version
export SETUPTOOLS_SCM_PRETEND_VERSION=${SETUPTOOLS_SCM_PRETEND_VERSION:-0+local}

FETCHCONTENT_BASE_DIR="$TMPDIR/deps" pip install -e . --no-deps --no-build-isolation --verbose
echo "✅ vLLM installed in editable mode (fallback)!"
python - <<'PY'
import vllm
print("vLLM version:", getattr(vllm, "__version__", "unknown"))
PY
