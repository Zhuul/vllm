# WSL2 + Podman + GPU Troubleshooting Guide

## The Problem
You're getting "WARNING: The NVIDIA Driver was not detected" in your container, even though CUDA 12.9.1 is available.

## Root Cause
WSL2 + Podman + GPU requires specific configuration that differs from native Linux or Docker setups.

## Solutions (Try in Order)

### 1. Check Prerequisites (Windows Host)
```powershell
# Check Windows NVIDIA drivers (must be R495+)
nvidia-smi

# Check WSL2 kernel version (should be 5.10.16.3+)
wsl cat /proc/version
```

### 2. Install NVIDIA Container Toolkit in WSL2
```bash
# Run from vLLM repository root in WSL2
./extras/manage-container.sh setup-gpu
```

### 3. Diagnose Current Setup
```bash
# Comprehensive diagnostics
./extras/manage-container.sh wsl-gpu

# Quick GPU test
./extras/manage-container.sh gpu
```

### 4. Alternative GPU Flags
If the default method doesn't work, try these alternatives in the run scripts:

**In `run-vllm-dev-fedora.ps1`:**
```powershell
# Method 1 (current): WSL2 + SELinux disable
$Gpus = "--device", "nvidia.com/gpu=all", "--security-opt", "label=disable"

# Method 2: Standard Podman
$Gpus = "--device", "nvidia.com/gpu=all"

# Method 3: Docker-style
$Gpus = "--gpus", "all"

# Method 4: Privileged mode (last resort)
$Gpus = "--privileged", "--device", "nvidia.com/gpu=all"
```

**In `run-vllm-dev-fedora.sh`:**
```bash
# Method 1 (current): WSL2 + SELinux disable
GPUS=("--device" "nvidia.com/gpu=all" "--security-opt" "label=disable")

# Method 2: Standard Podman
GPUS=("--device" "nvidia.com/gpu=all")

# Method 3: Docker-style
GPUS=("--gpus" "all")

# Method 4: Privileged mode (last resort)
GPUS=("--privileged" "--device" "nvidia.com/gpu=all")
```

### 5. Manual Container Test
Test GPU access manually:
```bash
# Test 1: Basic GPU access
podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.9.1-base-ubi9 nvidia-smi

# Test 2: With SELinux disabled
podman run --rm --security-opt=label=disable --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.9.1-base-ubi9 nvidia-smi

# Test 3: Direct path to nvidia-smi in WSL2
podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.9.1-base-ubi9 /usr/lib/wsl/lib/nvidia-smi
```

### 6. Container Runtime Configuration
If still not working, configure Podman runtime:
```bash
# Create Podman GPU configuration
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf << 'EOF'
[containers]
default_capabilities = ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"]

[engine]
runtime = "crun"
hooks_dir = ["/usr/share/containers/oci/hooks.d"]
EOF

# Reset Podman system
podman system reset --force
```

### 7. WSL2 Kernel Update
Ensure you have the latest WSL2 kernel:
```powershell
# In Windows PowerShell (as Administrator)
wsl --update
wsl --shutdown
# Restart WSL2
wsl
```

### 8. Alternative: CPU-Only Mode
If GPU still doesn't work, run in CPU-only mode by commenting out GPU arguments:
```bash
# In run scripts, comment out GPU lines:
# GPUS=("--device" "nvidia.com/gpu=all" "--security-opt" "label=disable")
GPUS=()  # Empty array = no GPU
```

## Common Issues and Solutions

### Issue: "nvidia-container-cli: initialization error"
**Solution:** Install NVIDIA Container Toolkit in WSL2:
```bash
./extras/manage-container.sh setup-gpu
```

### Issue: "Permission denied" or SELinux errors
**Solution:** Add `--security-opt=label=disable` to GPU flags

### Issue: Container runs but GPU not detected
**Solution:** Check Windows NVIDIA drivers and WSL2 kernel version

### Issue: "Device not found" errors
**Solution:** Use `nvidia.com/gpu=all` instead of `--gpus all`

## Verification
Once working, you should see:
```bash
# In container logs
🐍 Virtual environment activated: /home/vllmuser/venv
Setting up vLLM development environment...

# GPU detection
import torch
print(torch.cuda.is_available())  # Should print: True
print(torch.cuda.device_count())  # Should print: 1 (or your GPU count)
```

## Still Not Working?
1. Run full diagnostics: `./extras/manage-container.sh wsl-gpu`
2. Check NVIDIA forums: https://forums.developer.nvidia.com/c/accelerated-computing/cuda/cuda-on-windows-subsystem-for-linux/303
3. Try Docker instead of Podman as a test
4. Consider using native Linux instead of WSL2 for development
