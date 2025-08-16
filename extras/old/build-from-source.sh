#!/usr/bin/env bash
set -euo pipefail
set -x

# Activate venv if present
if [ -f /home/vllmuser/venv/bin/activate ]; then
  source /home/vllmuser/venv/bin/activate || true
fi

# Temporary build dirs to avoid permission issues
export TMPDIR=${TMPDIR:-/tmp/vllm-build}
umask 0002
mkdir -p "$TMPDIR" || true
chmod 777 "$TMPDIR" || true
export FETCHCONTENT_BASE_DIR="${FETCHCONTENT_BASE_DIR:-$TMPDIR/deps}"

# Parallelism and CUDA arch list (include Blackwell sm_120 == 12.0)
export CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-4}
export MAX_JOBS=${MAX_JOBS:-4}
export NVCC_THREADS=${NVCC_THREADS:-2}
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-7.0 7.5 8.0 8.6 8.9 9.0 12.0}"

# Keep FA2/FA3 and machete enabled by default
export VLLM_DISABLE_FA3=${VLLM_DISABLE_FA3:-0}   # 0=build FA3
export FA3_MEMORY_SAFE_MODE=${FA3_MEMORY_SAFE_MODE:-0}

echo "=== Build env ==="
echo "TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"
echo "FETCHCONTENT_BASE_DIR=$FETCHCONTENT_BASE_DIR"
echo "CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL MAX_JOBS=$MAX_JOBS NVCC_THREADS=$NVCC_THREADS"

python - << 'PY'
import os, torch
print('torch', torch.__version__)
print('cuda_version', torch.version.cuda)
print('cuda_available', torch.cuda.is_available())
print('arch_list', os.getenv('TORCH_CUDA_ARCH_LIST'))
PY

# Ensure core build tools present (setup will also ensure, this is harmless)
python -m pip install -r requirements/build.txt -q

# Run editable build with verbose logs and capture output
mkdir -p extras
set +e
python -m pip install -e . --no-build-isolation -vv |& tee extras/build.log
status=${PIPESTATUS[0]}
set -e
echo "=== pip exited with code: $status ==="
exit $status
