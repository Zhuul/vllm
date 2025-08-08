#!/bin/bash
# check-wsl-gpu.sh
# Diagnostic script to check WSL2 + GPU setup

echo "=== WSL2 + GPU Diagnostic Tool ==="
echo

# Check if we're in WSL2
echo "WSL Version Check:"
if grep -q Microsoft /proc/version; then
    echo "✅ Running in WSL2"
    cat /proc/version
else
    echo "❌ Not running in WSL2 - this script is for WSL2 environments"
    exit 1
fi
echo

# Check WSL kernel version
echo "WSL Kernel Version:"
uname -r
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
echo "Kernel version: $KERNEL_VERSION"
if [[ $(echo "$KERNEL_VERSION" | cut -d'.' -f1) -ge 5 && $(echo "$KERNEL_VERSION" | cut -d'.' -f2) -ge 10 ]]; then
    echo "✅ Kernel version supports GPU"
else
    echo "⚠️  Older kernel - GPU support may be limited"
fi
echo

# Check if NVIDIA driver stub is available
echo "NVIDIA Driver Stub Check:"
if [ -f /usr/lib/wsl/lib/libcuda.so.1 ]; then
    echo "✅ NVIDIA driver stub found: /usr/lib/wsl/lib/libcuda.so.1"
else
    echo "❌ NVIDIA driver stub NOT found"
    echo "Install NVIDIA Windows drivers (R495+) on Windows host"
fi

if [ -f /usr/lib/wsl/lib/nvidia-smi ]; then
    echo "✅ nvidia-smi found: /usr/lib/wsl/lib/nvidia-smi"
    echo "Running nvidia-smi from WSL location:"
    /usr/lib/wsl/lib/nvidia-smi
else
    echo "⚠️  nvidia-smi not found at WSL location"
fi
echo

# Check if NVIDIA Container Toolkit is installed
echo "NVIDIA Container Toolkit Check:"
if command -v nvidia-ctk &> /dev/null; then
    echo "✅ nvidia-ctk found: $(which nvidia-ctk)"
    nvidia-ctk --version
else
    echo "❌ nvidia-ctk NOT found"
    echo "Install NVIDIA Container Toolkit in WSL2"
fi
echo

# Check Podman configuration
echo "Podman Configuration:"
if command -v podman &> /dev/null; then
    echo "✅ Podman found: $(which podman)"
    podman --version
    
    echo "Podman runtime configuration:"
    podman info --format "{{.Host.OCIRuntime}}" 2>/dev/null || echo "Could not get runtime info"
    
    # Check if crun/runc supports GPU
    echo "Container runtime GPU support:"
    if podman info 2>/dev/null | grep -q "nvidia"; then
        echo "✅ NVIDIA support detected in Podman"
    else
        echo "⚠️  NVIDIA support not detected in Podman config"
    fi
else
    echo "❌ Podman not found"
fi
echo

# Test GPU access directly
echo "Direct GPU Access Test:"
echo "Testing direct CUDA access..."
if /usr/lib/wsl/lib/nvidia-smi > /dev/null 2>&1; then
    echo "✅ Direct GPU access works"
else
    echo "❌ Direct GPU access failed"
    echo "Check Windows NVIDIA drivers (need R495+)"
fi
echo

# Test GPU access via container
echo "Container GPU Access Test:"
echo "Testing GPU access via Podman..."
if podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.9.1-base-ubi9 nvidia-smi > /dev/null 2>&1; then
    echo "✅ Container GPU access works!"
else
    echo "❌ Container GPU access failed"
    echo "This is the issue we need to fix"
fi
echo

echo "=== Recommendations ==="
echo
echo "For WSL2 + Podman + GPU to work, you need:"
echo "1. ✅ Windows NVIDIA drivers R495+ (installed on Windows host)"
echo "2. ✅ WSL2 with kernel 5.10.16.3+ (update with: wsl --update)"
echo "3. ❓ NVIDIA Container Toolkit in WSL2"
echo "4. ❓ Podman configured for GPU passthrough"
echo
echo "Next steps if GPU doesn't work:"
echo "• Install NVIDIA Container Toolkit in WSL2"
echo "• Configure Podman runtime for GPU support"
echo "• Use --security-opt=label=disable with Podman"
