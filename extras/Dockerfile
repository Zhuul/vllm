# vLLM Development Container with GPU Support
# Uses vLLM's own requirements for automatic dependency management

FROM nvidia/cuda:12.9.1-cudnn-devel-ubi9

# Set CUDA environment variables for build tools
ENV CUDA_HOME=/usr/local/cuda
ENV CUDA_ROOT=/usr/local/cuda
ENV PATH=$CUDA_HOME/bin:$PATH
ENV LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH
ENV CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
ENV CUDNN_LIBRARY_PATH=/usr/lib64
ENV CUDNN_INCLUDE_PATH=/usr/include

# Install system packages with additional CUDA development libraries
RUN dnf update -y && dnf install --allowerasing -y \
    python3 python3-pip python3-devel \
    git gcc gcc-c++ cmake ninja-build \
    make patch which findutils tar \
    wget curl vim nano \
    && dnf clean all

# Create symlinks for python
RUN ln -sf /usr/bin/python3 /usr/bin/python

# Create a non-root user for development
RUN useradd -m -s /bin/bash vllmuser && \
    echo "vllmuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install essential system tools
RUN dnf install -y hostname iproute iputils

# Add NVIDIA Machine Learning repo for RHEL9/UBI9 and install NCCL runtime/devel
# Needed for PyTorch nightly cu129 to avoid ncclCommWindowRegister symbol errors
# Install NCCL runtime/devel from the CUDA repository available in the base image
RUN set -euxo pipefail \
    && dnf makecache -y \
    && (dnf install -y libnccl libnccl-devel || dnf install -y libnccl-2 libnccl-devel-2) \
    && dnf clean all

# Set working directory and adjust ownership
WORKDIR /workspace
RUN chown -R vllmuser:vllmuser /workspace

# Create build directories with proper permissions
RUN mkdir -p /workspace/.deps && chown -R vllmuser:vllmuser /workspace/.deps && \
    mkdir -p /tmp/vllm-build && chmod 777 /tmp/vllm-build && \
    mkdir -p /opt/work && chmod 777 /opt/work && \
    mkdir -p /home/vllmuser/.cache && chown -R vllmuser:vllmuser /home/vllmuser/.cache && \
    mkdir -p /home/vllmuser/.ccache && chown -R vllmuser:vllmuser /home/vllmuser/.ccache && \
    mkdir -p /home/vllmuser/.cmake && chown -R vllmuser:vllmuser /home/vllmuser/.cmake && \
    chmod -R 755 /workspace && \
    chmod -R 777 /tmp

# Switch to the non-root user
USER vllmuser

# Create and activate virtual environment
ENV VIRTUAL_ENV=/home/vllmuser/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Set pip configuration
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1
ENV PYTHONUNBUFFERED=1
ENV PIP_DEFAULT_TIMEOUT=120
ENV PIP_RETRIES=5
ENV PIP_PREFER_BINARY=1

# Upgrade pip and setuptools to latest versions
RUN pip install --upgrade pip setuptools>=61 wheel

COPY requirements/ /tmp/requirements/

# Install PyTorch nightly first (includes latest GPU arch support such as Blackwell sm_120 when present)
RUN pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu129 && \
    python - << 'PY'
from packaging.version import Version
pins = []
try:
    import torch
    pins.append(f"torch>={Version(torch.__version__).public}")
except Exception: pass
try:
    import torchvision
    pins.append(f"torchvision>={Version(torchvision.__version__).public}")
except Exception: pass
try:
    import torchaudio
    pins.append(f"torchaudio>={Version(torchaudio.__version__).public}")
except Exception: pass
open('/tmp/pip-constraints-torch-nightly.txt','w').write('\n'.join(pins))
print('Pinned constraints:\n'+'\n'.join(pins))
PY

# Install modern build tools and vLLM's build dependencies and CUDA deps early,
# but sanitize requirements to avoid downgrading torch-family or forcing xformers pins.
COPY pyproject.toml /tmp/pyproject.toml
RUN set -euxo pipefail \
        && cd /tmp \
        && pip install "setuptools>=61" "setuptools-scm>=8" build wheel ninja cmake \
        && mkdir -p /tmp/requirements_sanitized \
        && for f in build.txt cuda.txt common.txt; do \
                 if [ -f "/tmp/requirements/$f" ]; then \
                     sed -E '/^(torch|torchvision|torchaudio|xformers)\b/Id' "/tmp/requirements/$f" > "/tmp/requirements_sanitized/$f"; \
                 fi; \
             done \
    && pip install --pre -c /tmp/pip-constraints-torch-nightly.txt \
          -r /tmp/requirements_sanitized/build.txt \
          -r /tmp/requirements_sanitized/cuda.txt \
          -r /tmp/requirements_sanitized/common.txt \
    && pip install --pre --upgrade -c /tmp/pip-constraints-torch-nightly.txt \
          torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu129

# Install minimal development extras
RUN pip install pytest pytest-asyncio ipython

# Note: vLLM will be installed from source in development mode via dev-setup.sh
# This ensures compatibility with the PyTorch nightly build

# Create activation script for easy virtual environment access
RUN echo '#!/bin/bash' > /home/vllmuser/activate_venv.sh && \
    echo 'source /home/vllmuser/venv/bin/activate' >> /home/vllmuser/activate_venv.sh && \
    echo 'echo "Virtual environment activated: $VIRTUAL_ENV"' >> /home/vllmuser/activate_venv.sh && \
    echo 'echo "Python version: $(python --version)"' >> /home/vllmuser/activate_venv.sh && \
    echo 'echo "PyTorch version: $(python -c \"import torch; print(torch.__version__)\")"' >> /home/vllmuser/activate_venv.sh && \
    echo 'echo "CUDA available: $(python -c \"import torch; print(torch.cuda.is_available())\")"' >> /home/vllmuser/activate_venv.sh && \
    chmod +x /home/vllmuser/activate_venv.sh

# Ensure virtual environment is activated in .bashrc
RUN echo 'source /home/vllmuser/venv/bin/activate' >> /home/vllmuser/.bashrc && \
    echo 'echo "🐍 Python virtual environment activated"' >> /home/vllmuser/.bashrc && \
    echo 'echo "🚀 Ready for vLLM development!"' >> /home/vllmuser/.bashrc

# Create development helper script that uses current workspace requirements
RUN echo '#!/bin/bash' > /home/vllmuser/setup_vllm_dev.sh && \
    echo 'echo "🔧 Setting up vLLM for development..."' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'cd /workspace' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo '# Use temporary build directory to avoid permission issues' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'export TMPDIR=/tmp/vllm-build' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'mkdir -p "$TMPDIR" && chmod 777 "$TMPDIR"' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'export CMAKE_BUILD_PARALLEL_LEVEL=4' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'export VLLM_INSTALL_PUNICA_KERNELS=0' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'export MAX_JOBS=4' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo '# Install current workspace requirements first' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'if [ -f requirements/common.txt ]; then pip install -r requirements/common.txt; fi' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo '# Use temporary directory for CMake build files' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'FETCHCONTENT_BASE_DIR="$TMPDIR/deps" pip install -e . --no-build-isolation --verbose' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'echo "✅ vLLM installed in editable mode!"' >> /home/vllmuser/setup_vllm_dev.sh && \
    echo 'python -c "import vllm; print(\"vLLM version:\", vllm.__version__)"' >> /home/vllmuser/setup_vllm_dev.sh && \
    chmod +x /home/vllmuser/setup_vllm_dev.sh

# Add environment variables for better CUDA memory management and build optimization
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
# Do not pin a single GPU here; let runtime inject device selection
# ENV CUDA_VISIBLE_DEVICES=0
ENV CMAKE_BUILD_PARALLEL_LEVEL=4
ENV VLLM_INSTALL_PUNICA_KERNELS=0
ENV MAX_JOBS=4

# Enable ccache for faster rebuilds
ENV CCACHE_DIR=/home/vllmuser/.ccache
ENV CCACHE_MAXSIZE=10G
ENV PATH=/usr/lib64/ccache:$PATH

# CUDA arch list including legacy + latest (sm_120) so builds cover both older and newest GPUs.
ENV TORCH_CUDA_ARCH_LIST="7.0 7.5 8.0 8.6 8.9 9.0 12.0"
# Do not force-disable Machete; allow upstream defaults. User may still pass -e CMAKE_ARGS for custom CMake settings.
ENV CMAKE_ARGS=""

# WSL2-specific CUDA environment configuration
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV LD_LIBRARY_PATH=/usr/local/cuda/compat:/usr/lib/wsl/drivers:/usr/lib/wsl/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:/usr/local/cuda/lib:$LD_LIBRARY_PATH

# Add runtime library detection script
RUN echo '#!/bin/bash' > /home/vllmuser/check_cuda_libs.sh && \
    echo 'echo "=== CUDA Library Check ==="' >> /home/vllmuser/check_cuda_libs.sh && \
    echo 'echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"' >> /home/vllmuser/check_cuda_libs.sh && \
    echo 'echo "Searching for CUDA libraries..."' >> /home/vllmuser/check_cuda_libs.sh && \
    echo 'find /usr/lib/wsl -name "libcuda.so*" 2>/dev/null | head -3 || echo "No WSL CUDA libs"' >> /home/vllmuser/check_cuda_libs.sh && \
    echo 'ldconfig -p | grep cuda | head -3 || echo "No CUDA in ldconfig"' >> /home/vllmuser/check_cuda_libs.sh && \
    echo 'echo "PyTorch CUDA status:"' >> /home/vllmuser/check_cuda_libs.sh && \
    echo 'python -c "import torch; print(f\"CUDA available: {torch.cuda.is_available()}\"); print(f\"Device count: {torch.cuda.device_count()}\")" 2>/dev/null || echo "PyTorch not available"' >> /home/vllmuser/check_cuda_libs.sh && \
    chmod +x /home/vllmuser/check_cuda_libs.sh
