# Use NVIDIA's CUDA image with UBI9 base (Red Hat/Fedora ecosystem)
# This provides CUDA toolkit and runtime with cuDNN
FROM nvidia/cuda:12.9.1-cudnn-devel-ubi9

# Install system packages: Python, pip, git, compilers, and build tools
# UBI9 uses dnf package manager like Fedora
RUN dnf update -y && dnf install --allowerasing -y \
    python3 python3-pip python3-devel \
    git gcc gcc-c++ cmake ninja-build \
    make patch which findutils tar \
    wget curl vim nano \
    && dnf clean all

# Create symlinks for python (some tools expect 'python' command)
RUN ln -sf /usr/bin/python3 /usr/bin/python

# Create a non-root user for development first
RUN useradd -m -s /bin/bash vllmuser && \
    echo "vllmuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set working directory and adjust ownership to the new user
WORKDIR /workspace
RUN chown -R vllmuser:vllmuser /workspace

# Switch to the non-root user for virtual environment setup
USER vllmuser

# Create and activate virtual environment in user space
ENV VIRTUAL_ENV=/home/vllmuser/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Set pip configuration for virtual environment
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1
ENV PYTHONUNBUFFERED=1

# Upgrade pip and install Python build dependencies in virtual environment
RUN pip install --upgrade pip && \
    pip install setuptools setuptools-scm>=8.0 wheel packaging numpy ninja

# Install PyTorch with CUDA support (matching CUDA version in container)
RUN pip install torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0 \
    --index-url https://download.pytorch.org/whl/cu124

# Install additional Python packages commonly needed for vLLM development
RUN pip install pytest pytest-asyncio transformers tokenizers

# Create activation script for easy virtual environment access
RUN echo '#!/bin/bash' > /home/vllmuser/activate_venv.sh && \
    echo 'source /home/vllmuser/venv/bin/activate' >> /home/vllmuser/activate_venv.sh && \
    echo 'echo "Virtual environment activated: $VIRTUAL_ENV"' >> /home/vllmuser/activate_venv.sh && \
    echo 'echo "Python version: $(python --version)"' >> /home/vllmuser/activate_venv.sh && \
    echo 'echo "Pip version: $(pip --version)"' >> /home/vllmuser/activate_venv.sh && \
    chmod +x /home/vllmuser/activate_venv.sh

# Ensure virtual environment is activated in .bashrc for interactive sessions
RUN echo 'source /home/vllmuser/venv/bin/activate' >> /home/vllmuser/.bashrc && \
    echo 'echo "🐍 Python virtual environment activated"' >> /home/vllmuser/.bashrc
