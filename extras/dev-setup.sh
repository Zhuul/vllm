#!/bin/bash
# dev-setup.sh - Set up vLLM development environment using nightly wheels

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

# Install PyTorch with CUDA 12.9 for RTX 5090 support
echo "🚀 Installing PyTorch nightly with CUDA 12.9 for RTX 5090..."
pip uninstall torch torchvision torchaudio -y 2>/dev/null || true
pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu129

# Set CUDA architecture list to include RTX 5090 (sm_120)
echo "🔧 Configuring CUDA architectures for RTX 5090..."
export TORCH_CUDA_ARCH_LIST="7.0;7.5;8.0;8.6;8.9;9.0;12.0"
echo "TORCH_CUDA_ARCH_LIST set to: $TORCH_CUDA_ARCH_LIST"

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

# Install vLLM from source (required for RTX 5090 sm_120 support)
echo "📦 Installing vLLM from source for RTX 5090 compatibility..."
pip uninstall vllm -y 2>/dev/null || true

# Use existing PyTorch installation approach
echo "🔧 Configuring build for existing PyTorch..."
python use_existing_torch.py

# Install build requirements
echo "📋 Installing build requirements..."
pip install -r requirements/build.txt

# Set build environment for RTX 5090
export MAX_JOBS=4
export VLLM_TARGET_DEVICE=cuda
export SETUPTOOLS_SCM_PRETEND_VERSION="0.10.1.dev+cu129"
export FETCHCONTENT_BASE_DIR=/tmp/vllm-build/deps
export CMAKE_ARGS="-DENABLE_MACHETE=OFF"
export VLLM_INSTALL_PUNICA_KERNELS=0
mkdir -p $FETCHCONTENT_BASE_DIR

echo "🔧 Build environment configured:"
echo "  TORCH_CUDA_ARCH_LIST: $TORCH_CUDA_ARCH_LIST"
echo "  MAX_JOBS: $MAX_JOBS"
echo "  CMAKE_ARGS: $CMAKE_ARGS"
echo "  FETCHCONTENT_BASE_DIR: $FETCHCONTENT_BASE_DIR"

# Build and install vLLM
echo "🏗️  Building vLLM from source..."
pip install --no-build-isolation -e .

if [ $? -eq 0 ]; then
    echo "✅ vLLM nightly wheel installed successfully"
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
