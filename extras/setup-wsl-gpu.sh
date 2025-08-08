#!/bin/bash
# setup-wsl-gpu.sh
# Install NVIDIA Container Toolkit for WSL2 + Podman

set -e

echo "=== NVIDIA Container Toolkit Setup for WSL2 ==="
echo "This script installs NVIDIA Container Toolkit for Podman in WSL2"
echo

# Check if we're in WSL2
if ! grep -q Microsoft /proc/version; then
    echo "❌ This script must be run inside WSL2"
    exit 1
fi

# Check if running as root or with sudo
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo "🔧 Setting up NVIDIA Container Toolkit repository..."

# Add NVIDIA GPG key
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | $SUDO gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Add NVIDIA repository
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

echo "🔧 Updating package lists..."
$SUDO apt-get update

echo "🔧 Installing NVIDIA Container Toolkit..."
$SUDO apt-get install -y nvidia-container-toolkit

echo "🔧 Configuring Podman runtime..."
# Configure the container runtime for Podman
$SUDO nvidia-ctk runtime configure --runtime=crun

# Alternative configuration for podman
echo "🔧 Configuring Podman for GPU support..."

# Create/update Podman configuration
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf << 'EOF'
[containers]
# Enable GPU support
default_capabilities = [
  "CHOWN",
  "DAC_OVERRIDE", 
  "FOWNER",
  "FSETID",
  "KILL",
  "NET_BIND_SERVICE",
  "SETFCAP",
  "SETGID",
  "SETPCAP",
  "SETUID",
  "SYS_CHROOT"
]

[engine]
# Use crun runtime (better GPU support)
runtime = "crun"

# GPU support configuration
hooks_dir = ["/usr/share/containers/oci/hooks.d"]
EOF

# Ensure crun is available and configured
if ! command -v crun &> /dev/null; then
    echo "🔧 Installing crun runtime..."
    $SUDO apt-get install -y crun
fi

echo "🔧 Restarting Podman service (if running)..."
# Reset podman system to pick up new configuration
podman system reset --force 2>/dev/null || true

echo "✅ NVIDIA Container Toolkit setup complete!"
echo
echo "🧪 Testing GPU access..."
echo "Testing with: podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.9.1-base-ubi9 nvidia-smi"
echo

if podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.9.1-base-ubi9 nvidia-smi; then
    echo "🎉 GPU access is working!"
else
    echo "❌ GPU access still not working. Additional troubleshooting needed."
    echo
    echo "Try alternative GPU flags:"
    echo "• --device nvidia.com/gpu=all"
    echo "• --gpus all"
    echo "• --security-opt=label=disable --device nvidia.com/gpu=all"
fi

echo
echo "📝 Configuration complete. You can now use GPU in containers with:"
echo "   podman run --device nvidia.com/gpu=all <image>"
