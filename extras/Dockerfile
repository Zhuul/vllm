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

# Set working directory and adjust ownership
WORKDIR /workspace
RUN chown -R vllmuser:vllmuser /workspace

# Create build directories with proper permissions
RUN mkdir -p /workspace/.deps && chown -R vllmuser:vllmuser /workspace/.deps && \
    mkdir -p /tmp/vllm-build && chmod 777 /tmp/vllm-build && \
    mkdir -p /home/vllmuser/.cache && chown -R vllmuser:vllmuser /home/vllmuser/.cache && \
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

# Upgrade pip and setuptools to latest versions
RUN pip install --upgrade pip setuptools>=61 wheel

# Copy vLLM requirements to leverage the project's own dependency management
COPY requirements/ /tmp/requirements/

# Install PyTorch nightly with RTX 5090 (sm_120) support instead of stable version
# This provides better GPU compatibility for the latest architectures
RUN pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu129

# Install modern build tools and vLLM's build dependencies
COPY pyproject.toml /tmp/pyproject.toml
RUN cd /tmp && pip install "setuptools>=61" "setuptools-scm>=8" build wheel ninja cmake

# Install vLLM's common dependencies
RUN pip install -r /tmp/requirements/common.txt

# Install additional development dependencies
RUN pip install \
    pytest pytest-asyncio \
    accelerate \
    datasets \
    jupyter ipython

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
ENV CUDA_VISIBLE_DEVICES=0
ENV CMAKE_BUILD_PARALLEL_LEVEL=4
ENV VLLM_INSTALL_PUNICA_KERNELS=0
ENV MAX_JOBS=4

# RTX 5090 (sm_120) support - critical for latest GPUs
ENV TORCH_CUDA_ARCH_LIST="7.0;7.5;8.0;8.6;8.9;9.0;12.0"
ENV CMAKE_ARGS="-DENABLE_MACHETE=OFF"

# WSL2-specific CUDA environment configuration
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV LD_LIBRARY_PATH=/usr/lib/wsl/drivers:/usr/lib/wsl/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:/usr/local/cuda/lib:$LD_LIBRARY_PATH
ENV TORCH_CUDA_ARCH_LIST="6.0;6.1;7.0;7.5;8.0;8.6;8.9;9.0+PTX"

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
