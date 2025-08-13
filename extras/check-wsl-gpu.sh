#!/bin/bash
# Check WSL2 GPU Setup for vLLM Development
# This script verifies NVIDIA GPU accessibility in WSL2 environment

set -e

echo "=== WSL2 GPU Check for vLLM Development ==="
echo "Verifying NVIDIA GPU accessibility and configuration"
echo ""

# Basic system info
echo "🖥️  System Information:"
echo "Kernel: $(uname -r)"
echo "Distribution: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo ""

# Check if running in WSL2
if [[ -f /proc/version ]] && grep -q "microsoft" /proc/version; then
    echo "✅ Running in WSL2"
else
    echo "❌ Not running in WSL2"
    exit 1
fi

# Check NVIDIA driver
echo ""
echo "🎮 NVIDIA Driver Check:"
if command -v nvidia-smi &> /dev/null; then
    echo "✅ nvidia-smi available"
    nvidia-smi --query-gpu=name,driver_version,cuda_version --format=csv,noheader,nounits
    echo ""
    echo "GPU Devices:"
    nvidia-smi -L
else
    echo "❌ nvidia-smi not found"
    echo "Install NVIDIA drivers on Windows host"
fi

# Check CUDA installation
echo ""
echo "🚀 CUDA Installation Check:"
if command -v nvcc &> /dev/null; then
    echo "✅ nvcc available"
    nvcc --version | grep "release"
else
    echo "⚠️  nvcc not found (may be normal if using container CUDA)"
fi

# Check CUDA libraries
echo ""
echo "📚 CUDA Libraries Check:"
WSL_NVIDIA_PATHS=(
    "/usr/lib/wsl/drivers"
    "/usr/lib/wsl/lib"
    "/usr/lib/x86_64-linux-gnu"
    "/usr/local/cuda/lib64"
)

FOUND_LIBS=()
for path in "${WSL_NVIDIA_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
        LIBS=$(find "$path" -name "libcuda.so*" 2>/dev/null | head -3)
        if [[ -n "$LIBS" ]]; then
            echo "✅ Found CUDA libraries in $path:"
            echo "$LIBS" | sed 's/^/   /'
            FOUND_LIBS+=("$path")
        fi
    fi
done

if [[ ${#FOUND_LIBS[@]} -eq 0 ]]; then
    echo "❌ No CUDA libraries found"
else
    echo ""
    echo "Library paths with CUDA: ${FOUND_LIBS[*]}"
fi

# Check NVIDIA Container Toolkit
echo ""
echo "🐳 NVIDIA Container Toolkit Check:"
if command -v nvidia-ctk &> /dev/null; then
    echo "✅ nvidia-ctk available"
    echo "Version: $(nvidia-ctk --version)"
    
    # Check CDI configuration
    if [[ -f /etc/cdi/nvidia.yaml ]]; then
        echo "✅ CDI configuration exists"
        echo "Available devices:"
        nvidia-ctk cdi list 2>/dev/null | head -5 || echo "   (CDI list failed)"
    else
        echo "⚠️  CDI configuration missing"
        echo "Run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    fi
else
    echo "❌ nvidia-ctk not found"
    echo "Install NVIDIA Container Toolkit"
fi

# Check Podman
echo ""
echo "🐳 Podman Check:"
if command -v podman &> /dev/null; then
    echo "✅ Podman available"
    echo "Version: $(podman --version)"
    
    if podman info &>/dev/null; then
        echo "✅ Podman daemon accessible"
        
        # Test GPU device access
        echo "Testing GPU device access..."
        if podman run --rm --device nvidia.com/gpu=all --security-opt=label=disable \
           nvidia/cuda:12.0-base-ubuntu20.04 nvidia-smi -L 2>/dev/null; then
            echo "✅ GPU device access working!"
        else
            echo "⚠️  GPU device access failed"
            echo "This may be due to missing CDI configuration or container issues"
        fi
    else
        echo "⚠️  Podman daemon not accessible"
        echo "Try: podman machine start"
    fi
else
    echo "❌ Podman not found"
fi

# Check Python/PyTorch if available
echo ""
echo "🐍 Python/PyTorch Check:"
if command -v python3 &> /dev/null; then
    echo "✅ Python3 available: $(python3 --version)"
    
    # Check if PyTorch is available
    if python3 -c "import torch" 2>/dev/null; then
        echo "✅ PyTorch available"
        TORCH_VERSION=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null)
        echo "PyTorch version: $TORCH_VERSION"
        
        # Check CUDA availability in PyTorch
        CUDA_AVAILABLE=$(python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null)
        CUDA_COUNT=$(python3 -c "import torch; print(torch.cuda.device_count())" 2>/dev/null)
        
        if [[ "$CUDA_AVAILABLE" == "True" ]]; then
            echo "✅ PyTorch CUDA available"
            echo "CUDA devices: $CUDA_COUNT"
            python3 -c "import torch; print('CUDA version:', torch.version.cuda)" 2>/dev/null
        else
            echo "❌ PyTorch CUDA not available"
            echo "This is the main issue - PyTorch cannot access CUDA runtime"
        fi
    else
        echo "⚠️  PyTorch not available"
    fi
else
    echo "⚠️  Python3 not found"
fi

# Environment variables check
echo ""
echo "🌍 Environment Variables:"
echo "CUDA_HOME: ${CUDA_HOME:-'not set'}"
echo "PATH: ${PATH}"
echo "LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-'not set'}"
echo "NVIDIA_VISIBLE_DEVICES: ${NVIDIA_VISIBLE_DEVICES:-'not set'}"

# Summary
echo ""
echo "📊 Summary:"
if command -v nvidia-smi &> /dev/null; then
    echo "✅ NVIDIA drivers working"
else
    echo "❌ NVIDIA drivers issue"
fi

if [[ ${#FOUND_LIBS[@]} -gt 0 ]]; then
    echo "✅ CUDA libraries found"
else
    echo "❌ CUDA libraries missing"
fi

if command -v nvidia-ctk &> /dev/null && [[ -f /etc/cdi/nvidia.yaml ]]; then
    echo "✅ Container toolkit configured"
else
    echo "❌ Container toolkit needs setup"
fi

if command -v podman &> /dev/null && podman info &>/dev/null; then
    echo "✅ Podman working"
else
    echo "❌ Podman needs setup"
fi

echo ""
echo "💡 Recommendations:"
echo "1. If PyTorch CUDA is not available, restart container with proper GPU mounts"
echo "2. Ensure LD_LIBRARY_PATH includes WSL NVIDIA paths"
echo "3. Use --device nvidia.com/gpu=all when running containers"
echo "4. Check container has proper CUDA environment variables"
echo ""
