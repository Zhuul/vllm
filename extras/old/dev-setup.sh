#!/bin/bash
# dev-setup.sh - Set up vLLM development environment using nightly wheels
set -euo pipefail

echo "=== vLLM Development Environment Setup ==="
echo "Container: $(hostname)"
echo "User: $(whoami)"
echo "Working directory: $(pwd)"
echo ""

# Activate virtual environment
echo "🐍 Activating Python virtual environment..."
source /home/vllmuser/venv/bin/activate
echo "Virtual environment: $VIRTUAL_ENV"
echo "Python version: $(python --version)"
echo ""

# Check current PyTorch
echo "📦 Current PyTorch:"
python -c "import torch; print(f'PyTorch: {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}')" 2>/dev/null || echo "PyTorch not installed"
echo ""

### Optional: build from a local mirror to avoid slow Windows/virtiofs mounts during heavy C++ builds
if [ "${LOCAL_MIRROR:-0}" = "1" ]; then
    echo "📁 LOCAL_MIRROR=1 -> Copying sources for faster builds..."
    DEST="/opt/work"
    if ! mkdir -p "$DEST" 2>/dev/null; then
        echo "⚠️  No permission to create $DEST, falling back to /tmp/work"
        DEST="/tmp/work"
        mkdir -p "$DEST"
    fi
    echo "   ➜ Mirror destination: $DEST"
    # Ensure destination doesn't have a stray .git folder that could cause permission errors
    rm -rf "$DEST/.git" 2>/dev/null || true
    # Use tar pipeline but avoid preserving ownership/permissions/timestamps to prevent utime errors on Windows mounts
    # Exclude .git to avoid permission issues and speed up copy
    if ! tar -C /workspace --exclude='.git' -cf - . | tar -C "$DEST" -xf - --no-same-owner --no-same-permissions 2>/dev/null; then
        echo "   ⚠️  tar copy failed (likely timestamp/perm issue). Falling back to rsync/cp ..."
        shopt -s dotglob
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude='.git' /workspace/ "$DEST"/ 2>/dev/null || true
        else
            for f in /workspace/*; do
                bname="$(basename "$f")"
                [ "$bname" = ".git" ] && continue
                cp -R "$f" "$DEST"/ 2>/dev/null || true
            done
        fi
        shopt -u dotglob
    fi
    export VLLM_SRC_DIR="$DEST"
else
    export VLLM_SRC_DIR=/workspace
fi
echo "Source dir for build: ${VLLM_SRC_DIR}"

# Ensure a large, persistent temporary directory for heavy builds (pip/CMake use $TMPDIR)
# Default to /opt/work/tmp unless user overrides via VLLM_TMPDIR/TMPDIR
if [ -n "${VLLM_TMPDIR:-}" ]; then
    export TMPDIR="$VLLM_TMPDIR"
fi
if [ -z "${TMPDIR:-}" ] || [[ "$TMPDIR" == "/tmp"* ]]; then
    export TMPDIR="/opt/work/tmp"
fi
export TMP="$TMPDIR"; export TEMP="$TMPDIR"
mkdir -p "$TMPDIR" 2>/dev/null || true
echo "Using TMPDIR=$TMPDIR for build temps"

# Install PyTorch with CUDA 12.9 for RTX 5090 support
echo "🚀 Installing PyTorch nightly (CUDA 12.9 toolchain) ..."
pip uninstall -y torch torchvision torchaudio 2>/dev/null || true
pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu129

# Create a constraints file to prevent downgrades of any currently installed package.
# Use format "name>=version" to allow upgrades but disallow downgrades. Avoid third-party deps.
CONSTRAINTS_FILE="/tmp/pip-constraints-installed.txt"
python - <<'PY'
try:
    from importlib.metadata import distributions
except Exception:  # py39 backport
    from importlib_metadata import distributions  # type: ignore

exclude = {pkg.lower() for pkg in (
    'pip', 'setuptools', 'wheel'
)}
lines = []
for d in distributions():
    name = (d.metadata.get('Name') or '').strip()
    if not name or name.lower() in exclude:
        continue
    ver = (d.version or '').strip()
    if not ver:
        continue
    # Remove local version suffix (after '+') to keep constraint parser happy
    pv = ver.split('+', 1)[0]
    norm = name.lower().replace('_', '-')
    lines.append(f"{norm}>={pv}")
with open('/tmp/pip-constraints-installed.txt','w') as f:
    f.write('\n'.join(sorted(set(lines))))
print('📌 Constraints written to /tmp/pip-constraints-installed.txt (count):', len(lines))
PY
export PIP_CONSTRAINT="$CONSTRAINTS_FILE"
echo "Using PIP_CONSTRAINT=$PIP_CONSTRAINT"

# Set CUDA architecture list; include latest (sm_120) so builds are forward-compatible if such GPU is present.
echo "🔧 Configuring CUDA architectures (legacy + latest)..."
export TORCH_CUDA_ARCH_LIST="7.0 7.5 8.0 8.6 8.9 9.0 12.0"
echo "TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"

# Verify PyTorch version and CUDA capabilities
echo "🔍 Verifying PyTorch installation..."
python -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA version: {torch.version.cuda}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    try:
        device_props = torch.cuda.get_device_properties(0)
        print(f'GPU: {torch.cuda.get_device_name(0)}')
        print(f'Compute Capability: {device_props.major}.{device_props.minor}')
        print(f'Memory: {device_props.total_memory // 1024**3} GB')
        if device_props.major >= 9:  # Blackwell architecture (RTX 50xx)
            print('🎉 RTX 50xx series detected - sm_120 support available!')
        else:
            print(f'Detected GPU architecture: sm_{device_props.major}{device_props.minor}')
    except Exception as e:
        print(f'GPU details unavailable: {e}')
        print('Note: This is common in containers - GPU access might need container restart')
"
echo ""

echo "📦 Preparing to install vLLM from source (editable)..."
pip uninstall vllm -y 2>/dev/null || true

# Preinstall pinned deps to avoid long resolver work (esp. numba/llvmlite)
echo "📋 Installing pinned requirements (build + cuda + common), sanitized to keep torch nightly..."
mkdir -p /tmp/requirements_sanitized
for f in build.txt cuda.txt common.txt; do
    if [ -f "requirements/$f" ]; then
        sed -E '/^(torch|torchvision|torchaudio|xformers)\b/Id' "requirements/$f" > "/tmp/requirements_sanitized/$f"
    fi
done
pip install --pre \
    -r /tmp/requirements_sanitized/build.txt \
    -r /tmp/requirements_sanitized/cuda.txt \
    -r /tmp/requirements_sanitized/common.txt

# Reinstall PyTorch nightly to override any accidental downgrade from requirements
echo "♻️  Ensuring PyTorch stays on nightly cu129 after requirements..."
pip install --pre --upgrade \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/nightly/cu129

# Optionally install xformers if requested; otherwise skip to avoid pin conflicts with torch nightlies.
if [ "${WITH_XFORMERS:-0}" = "1" ]; then
    echo "➕ Installing xformers (may override torch constraints)..."
    pip install --pre xformers -f https://download.pytorch.org/whl/nightly/cu129/torch_nightly.html || true
else
    echo "⏭️  Skipping xformers (set WITH_XFORMERS=1 to include)"
fi

# Build environment tuning
export VLLM_TARGET_DEVICE=cuda
export SETUPTOOLS_SCM_PRETEND_VERSION="0.10.1.dev+cu129"
# Place large build/dependency artifacts on /opt/work to avoid small /tmp tmpfs exhaustion
export VLLM_BUILD_ROOT=${VLLM_BUILD_ROOT:-/opt/work}
export FETCHCONTENT_BASE_DIR="$VLLM_BUILD_ROOT/vllm-build/deps"
mkdir -p "$FETCHCONTENT_BASE_DIR"

# ccache for faster rebuilds
export CCACHE_DIR=/home/vllmuser/.ccache
export CCACHE_MAXSIZE=10G
export PATH=/usr/lib64/ccache:$PATH
command -v ccache >/dev/null 2>&1 && ccache -s || true

# Respect user-provided MAX_JOBS; otherwise derive a conservative default to avoid FA3 OOM (signal 9)
if [ -z "${MAX_JOBS:-}" ]; then
    # Derive from available cores but cap to 4 and adjust for memory pressure
    CORES=$(nproc 2>/dev/null || echo 4)
    # Read MemTotal (kB); if < 32GB, use 2; if < 16GB use 1
    MEM_KB=$(grep -i MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -n "$MEM_KB" ]; then
        if [ "$MEM_KB" -lt 16000000 ]; then
            MAX_JOBS=1
        elif [ "$MEM_KB" -lt 32000000 ]; then
            MAX_JOBS=2
        else
            MAX_JOBS=$(( CORES < 4 ? CORES : 4 ))
        fi
    else
        MAX_JOBS=$(( CORES < 4 ? CORES : 4 ))
    fi
fi
export MAX_JOBS

# Allow an optional memory safe mode specifically for heavy FA3 compilation (can be toggled externally)
if [ "${FA3_MEMORY_SAFE_MODE:-0}" = "1" ]; then
    echo "⚠️  FA3_MEMORY_SAFE_MODE=1 -> Forcing MAX_JOBS=1 and NVCC_THREADS=1 to reduce peak RAM during compilation"
    export MAX_JOBS=1
    export NVCC_THREADS=1
else
    # If user has not set NVCC_THREADS, keep it low (2) to reduce per-translation-unit memory usage
    if [ -z "${NVCC_THREADS:-}" ]; then
        export NVCC_THREADS=2
    fi
fi

# We no longer pass custom CMAKE_ARGS that refer to removed/unsupported options (e.g. ENABLE_MACHETE) to avoid noise.
unset CMAKE_ARGS 2>/dev/null || true
# Enable ccache via CMake compiler launchers (C/C++/CUDA) and enable verbose messages
export CMAKE_ARGS="${CMAKE_ARGS:+$CMAKE_ARGS }-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache -DCMAKE_VERBOSE_MAKEFILE=ON -DCMAKE_RULE_MESSAGES=ON"
export NINJA_STATUS="[%f/%t %o/sec] "
export CMAKE_COLOR_DIAGNOSTICS=ON

# By default we DO NOT disable FA3; user may export VLLM_DISABLE_FA3=1 before invoking this script to skip it.
if [ -z "${VLLM_DISABLE_FA3:-}" ]; then
    export VLLM_DISABLE_FA3=0
fi

echo "🔧 Build environment configured:"
echo "  TORCH_CUDA_ARCH_LIST: $TORCH_CUDA_ARCH_LIST"
echo "  MAX_JOBS: $MAX_JOBS"
echo "  NVCC_THREADS: ${NVCC_THREADS:-unset}"
echo "  FETCHCONTENT_BASE_DIR: $FETCHCONTENT_BASE_DIR"
echo "  VLLM_DISABLE_FA3: $VLLM_DISABLE_FA3 (0=build FA3, 1=skip)"
echo "  FA3_MEMORY_SAFE_MODE: ${FA3_MEMORY_SAFE_MODE:-0}"

# Build and install vLLM
echo "🏗️  Building vLLM from source (no dependency resolution)..."
cd "$VLLM_SRC_DIR"
# Ensure pip/CMake use our larger build root for temp files
export TMPDIR="$VLLM_BUILD_ROOT/tmp"
export CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}
mkdir -p "$TMPDIR" 2>/dev/null || true
LOG_DST="$VLLM_SRC_DIR/extras/build.log"
mkdir -p "$(dirname "$LOG_DST")" 2>/dev/null || true
set -o pipefail
TIMEFORMAT='⏱  Build time: %3lR'
# Progress watcher is fully opt-in now (no auto-enable on TTY)
PROGRESS_WATCH=${PROGRESS_WATCH:-0}

# Optional lightweight progress watcher: echoes lines like "[25/341] ..." as they appear
WATCH_PID=""
if [ "$PROGRESS_WATCH" = "1" ]; then
    echo "🪄 Progress watcher enabled (looking for [x/total] in build.log)"
    (
        # tail -F waits for file to appear; --pid ensures it exits with this script
        tail --pid=$$ -n +1 -F "$LOG_DST" 2>/dev/null | \
        awk 'match($0,/\[[0-9]+\/[0-9]+\]/){
                     ts=strftime("%H:%M:%S");
                     # print a compact, updating status line
                     printf("\r[%s] %s", ts, substr($0, RSTART, RLENGTH));
                     fflush(stdout);
                 } END { print "" }'
    ) &
    WATCH_PID=$!
fi

# Prefer line-buffered output for better streaming through tee if stdbuf exists
if command -v stdbuf >/dev/null 2>&1; then
    time stdbuf -oL -eL pip install --no-build-isolation --no-deps -e . -vv | tee "$LOG_DST"
else
    time pip install --no-build-isolation --no-deps -e . -vv | tee "$LOG_DST"
fi

# Cleanup watcher so we leave the cursor nicely
if [ -n "${WATCH_PID}" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    echo "" >&2
fi
echo "📄 Build log: $LOG_DST"

if [ $? -eq 0 ]; then
    echo "✅ vLLM editable install completed successfully"
else
    echo "❌ Failed to install vLLM"
    exit 1
fi

echo ""
echo "🧪 Testing vLLM installation..."
python -c "import vllm; print('vLLM version:', vllm.__version__)"

echo ""
echo "🎮 Testing GPU support..."
python -c "
import torch
print('CUDA available:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('GPU count:', torch.cuda.device_count())
    try:
        print('Current GPU:', torch.cuda.get_device_name(0))
    except Exception as e:
        print('GPU name unavailable (container GPU access issue)')
else:
    print('No GPU detected - check container GPU mounting')
"

echo ""
echo "📁 vLLM Development Environment Ready!"
echo "======================================"
echo "Source code: /workspace"
echo "Virtual env: $VIRTUAL_ENV"
echo "GPU support: $(python -c 'import torch; print(torch.cuda.is_available())')"
echo ""
echo "🛠️  Quick Commands:"
echo "  python -c 'import vllm'                    # Test vLLM import"
echo "  python -c 'import torch; print(torch.cuda.is_available())'  # Test CUDA"
echo "  nvidia-smi                                 # Check GPU status"
echo ""
echo "� Ready for vLLM development!"
echo "- Edit code: files are mounted from host"
echo "- Test changes: python -m pytest tests/"
echo "- Test environment: python /workspace/extras/final_environment_test.py"
echo "- Run vLLM: python -m vllm.entrypoints.openai.api_server"
echo "- SSH access: ssh vllmuser@localhost -p 2222 (password: vllmdev)"
echo ""
echo "✨ Happy coding!"
