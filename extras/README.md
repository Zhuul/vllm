# vLLM Development Environment - Essential Tools

This directory contains the essential tools and documentation for vLLM development with GPU support using containers.

## 🎯 Current Status: WORKING ✅

Successfully configured environment:
- **Container**: `vllm-dev:latest` with NVIDIA CUDA 12.9.1
- **GPU**: RTX 5090 (31GB) with CDI support
- **PyTorch**: Latest compatible version from vLLM requirements
- **vLLM**: Pre-built package working

## 📁 Essential Files

### Core Container Setup
- **`Dockerfile`** - Container definition using vLLM's own requirements
- **`run-vllm-dev.ps1`** - Main script to build/run the container
- **`dev-setup.sh`** - In-container development environment setup

### Testing & Verification
- **`final_environment_test.py`** - Comprehensive test to verify everything works

### Documentation
- **`CONTAINER_SETUP_COMPLETE.md`** - Complete setup guide and usage instructions
- **`README.md`** - This file

### GPU Setup (if needed)
- **`setup-podman-wsl2-gpu.ps1`** - One-time GPU setup for WSL2/Podman

## 🚀 Quick Start

### 1. Build Container
```powershell
cd c:\sources\github\vllm
.\extras\run-vllm-dev.ps1 -Build
```

### 2. Run Container
```powershell
.\extras\run-vllm-dev.ps1
```

### 3. Test Environment
```bash
# Inside container
source /home/vllmuser/venv/bin/activate
python /workspace/extras/final_environment_test.py
```

## 📖 Complete Documentation

See **`CONTAINER_SETUP_COMPLETE.md`** for:
- Detailed setup instructions
- Development workflow
- Troubleshooting notes
- Usage examples

## 🧹 Clean & Minimal

This directory contains only the essential, tested, working components. All obsolete files, redundant scripts, and old documentation have been removed to maintain clarity and focus.
