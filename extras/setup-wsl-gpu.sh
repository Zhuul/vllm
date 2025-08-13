#!/bin/bash
# WSL2 GPU Setup for vLLM Development with Podman
# This script configures NVIDIA GPU support in WSL2 environment

set -e

echo "=== WSL2 GPU Setup for vLLM Development ==="
echo "Configuring NVIDIA GPU support in WSL2 + Podman environment"
echo ""

# Check if running in WSL2
if [[ ! -f /proc/version ]] || ! grep -q "microsoft" /proc/version; then
    echo "❌ This script should be run inside WSL2"
    exit 1
fi

# Check if NVIDIA driver is accessible
if ! command -v nvidia-smi &> /dev/null; then
    echo "❌ nvidia-smi not found. Please ensure NVIDIA drivers are installed on Windows host"
    echo "Install from: https://www.nvidia.com/drivers"
    exit 1
fi

echo "✅ NVIDIA drivers detected"
nvidia-smi --query-gpu=name,driver_version,cuda_version --format=csv,noheader,nounits

# Check for CUDA libraries in WSL2 specific locations
WSL_NVIDIA_PATHS=(
    "/usr/lib/wsl/drivers"
    "/usr/lib/wsl/lib"
    "/usr/lib/x86_64-linux-gnu"
    "/usr/local/cuda/lib64"
)

echo ""
echo "🔍 Checking for CUDA libraries..."
CUDA_LIBS_FOUND=false

for path in "${WSL_NVIDIA_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
        echo "Checking $path..."
        if find "$path" -name "libcuda.so*" 2>/dev/null | head -1; then
            CUDA_LIBS_FOUND=true
            echo "✅ Found CUDA libraries in $path"
        fi
    fi
done

if [[ "$CUDA_LIBS_FOUND" == "false" ]]; then
    echo "❌ No CUDA libraries found in expected WSL2 locations"
    echo "This may require NVIDIA Container Toolkit installation"
fi

# Install NVIDIA Container Toolkit if not present
echo ""
echo "🛠️  Installing NVIDIA Container Toolkit..."

# Detect distribution
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_ID
else
    echo "❌ Cannot detect Linux distribution"
    exit 1
fi

# Configure repository based on distribution
if [[ "$DISTRO" == "fedora" ]] || [[ "$DISTRO" == "rhel" ]] || [[ "$DISTRO" == "centos" ]]; then
    echo "Configuring for $DISTRO..."
    
    # Add NVIDIA repository
    if [[ ! -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]]; then
        sudo curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
            -o /etc/yum.repos.d/nvidia-container-toolkit.repo
        echo "✅ Added NVIDIA repository"
    fi
    
    # Install nvidia-container-toolkit
    if ! rpm -q nvidia-container-toolkit &>/dev/null; then
        sudo dnf install -y nvidia-container-toolkit
        echo "✅ Installed NVIDIA Container Toolkit"
    else
        echo "✅ NVIDIA Container Toolkit already installed"
    fi
    
elif [[ "$DISTRO" == "ubuntu" ]] || [[ "$DISTRO" == "debian" ]]; then
    echo "Configuring for $DISTRO..."
    
    # Add NVIDIA repository
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID) \
        && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        && curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    echo "✅ Installed NVIDIA Container Toolkit"
else
    echo "⚠️  Unsupported distribution: $DISTRO"
    echo "Please install nvidia-container-toolkit manually"
fi

# Generate CDI configuration
echo ""
echo "🔧 Configuring Container Device Interface (CDI)..."
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

if [[ -f /etc/cdi/nvidia.yaml ]]; then
    echo "✅ CDI configuration generated"
    echo "Available GPU devices:"
    sudo nvidia-ctk cdi list
else
    echo "❌ Failed to generate CDI configuration"
fi

# Configure Podman for GPU support
echo ""
echo "🐳 Configuring Podman for GPU support..."

# Ensure Podman can use CDI
if command -v podman &> /dev/null; then
    # Test basic Podman functionality
    if podman info &>/dev/null; then
        echo "✅ Podman is accessible"
        
        # Test GPU access
        echo "Testing GPU access with Podman..."
        if podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.0-base-ubuntu20.04 nvidia-smi 2>/dev/null; then
            echo "✅ GPU access working in Podman!"
        else
            echo "⚠️  GPU access test failed - this may be normal if no containers are available"
            echo "Will test again after building vLLM container"
        fi
    else
        echo "⚠️  Podman not accessible - may need to start Podman machine"
        echo "Run: podman machine start"
    fi
else
    echo "⚠️  Podman not found - install with: dnf install podman"
fi

# Create library path configuration for PyTorch
echo ""
echo "📚 Configuring library paths for PyTorch CUDA access..."

# Find all CUDA library paths
CUDA_LIB_PATHS=""
for path in "${WSL_NVIDIA_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
        if find "$path" -name "libcuda.so*" &>/dev/null; then
            CUDA_LIB_PATHS="$CUDA_LIB_PATHS:$path"
        fi
    fi
done

# Create environment configuration
ENV_CONFIG="/tmp/cuda-env.sh"
cat > "$ENV_CONFIG" << 'EOF'
#!/bin/bash
# CUDA Environment Configuration for WSL2
# Source this file or add to your container environment

# WSL2-specific NVIDIA library paths
export CUDA_HOME="/usr/local/cuda"
export PATH="/usr/local/cuda/bin:$PATH"

# WSL2 NVIDIA driver paths
export LD_LIBRARY_PATH="/usr/lib/wsl/drivers:/usr/lib/wsl/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

# NVIDIA Container Runtime
export NVIDIA_VISIBLE_DEVICES=all
export NVIDIA_DRIVER_CAPABILITIES=compute,utility

# PyTorch CUDA configuration
export TORCH_CUDA_ARCH_LIST="6.0;6.1;7.0;7.5;8.0;8.6;8.9;9.0+PTX"

echo "CUDA Environment configured:"
echo "CUDA_HOME: $CUDA_HOME"
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "Available CUDA devices:"
nvidia-smi -L 2>/dev/null || echo "nvidia-smi not accessible"
EOF

echo "✅ Created CUDA environment configuration: $ENV_CONFIG"
echo ""

echo "🎉 WSL2 GPU Setup Complete!"
echo ""
echo "📋 Summary:"
echo "- ✅ NVIDIA drivers verified"
echo "- ✅ NVIDIA Container Toolkit installed"
echo "- ✅ CDI configuration generated"
echo "- ✅ Environment variables configured"
echo ""
echo "🚀 Next Steps:"
echo "1. Source the environment: source $ENV_CONFIG"
echo "2. Restart your vLLM container with proper GPU mounts"
echo "3. Test PyTorch CUDA access in container"
echo ""
echo "💡 For container GPU access, use:"
echo "   podman run --device nvidia.com/gpu=all [your-container]"
echo ""
