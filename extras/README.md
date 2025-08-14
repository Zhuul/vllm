# vLLM Development Environment - Essential Tools

This directory contains the essential tools and documentation for vLLM development with GPU support using containers.

## 🎯 Current Status

Development container workflow consolidated & working:
- **Image**: `vllm-dev:latest` (CUDA 12.9.1 base, nightly PyTorch inside dev setup script)
- **Launchers**: Single PowerShell (`run-vllm-dev.ps1`) and Bash (`run-vllm-dev.sh`) scripts
- **GPU Support**: Generic (Ampere → Blackwell). sm_120 included in arch list; no 5090-specific logic baked into code.
- **Flash Attention / Machete**: Built by default (no extras‑level disabling). Optional memory tuning via env.

## 📁 Essential Files

### Core Container Setup
- **`Dockerfile`** – Dev image definition (env baked in; minimal launcher flags)
- **`run-vllm-dev.ps1`** – Unified Windows/PowerShell launcher (auto Podman/Docker)
- **`run-vllm-dev.sh`** – Unified Bash launcher (Linux/macOS/WSL shells)
- **`dev-setup.sh`** – In‑container editable install (nightly torch + vLLM build)

### Testing & Verification
- **`final_environment_test.py`** - Comprehensive test to verify everything works

### Documentation
- **`CONTAINER_SETUP_COMPLETE.md`** - Complete setup guide and usage instructions
- **`README.md`** - This file

### GPU Setup (if needed)
- **`setup-podman-wsl2-gpu.ps1`** - One-time GPU setup for WSL2/Podman

## 🚀 Quick Start

### 1. Build Image
PowerShell:
```powershell
cd c:\sources\github\vllm
./extras/run-vllm-dev.ps1 -Build
```
Bash:
```bash
./extras/run-vllm-dev.sh -b
```

### 2. Launch Interactive Shell
PowerShell:
```powershell
./extras/run-vllm-dev.ps1
```
Bash:
```bash
./extras/run-vllm-dev.sh
```

### 3. Inside Container – Build Editable vLLM
```bash
./extras/dev-setup.sh
```

### 4. Quick GPU / Torch Check
Outside (one‑off):
```powershell
./extras/run-vllm-dev.ps1 -GPUCheck
```
or
```bash
./extras/run-vllm-dev.sh -g
```

Inside container:
```bash
python -c 'import torch;print(torch.__version__, torch.cuda.is_available())'
```

### 5. Environment Validation
```bash
python /workspace/extras/final_environment_test.py
```

### 6. Run a Sample Server (after build)
```bash
python -m vllm.entrypoints.openai.api_server --model meta-llama/Llama-3.1-8B
```

### 7. One‑off Commands (no shell)
PowerShell:
```powershell
./extras/run-vllm-dev.ps1 -Command "python -c 'import vllm,torch;print(vllm.__version__, torch.cuda.device_count())'"
```
Bash:
```bash
./extras/run-vllm-dev.sh -c "python -c 'import vllm,torch;print(vllm.__version__, torch.cuda.device_count())'"
```

## ⚙️ Tunable Environment Variables
Set before running `dev-setup.sh` (or export in container shell):

| Variable | Purpose | Default Logic |
|----------|---------|---------------|
| `TORCH_CUDA_ARCH_LIST` | CUDA arch targets (includes sm_120) | Set in Dockerfile (spaces) |
| `MAX_JOBS` | Parallel C++ compile jobs | Auto: cores capped (≤4) & memory aware |
| `NVCC_THREADS` | Threads per nvcc instance | Auto=2 (or 1 if memory safe mode) |
| `FA3_MEMORY_SAFE_MODE` | Force single‑threaded heavy FA3 build | Off (0) |
| `VLLM_DISABLE_FA3` | Skip Flash Attention v3 (diagnostic only) | 0 (build) |
| `FETCHCONTENT_BASE_DIR` | CMake deps cache dir | /tmp/vllm-build/deps |
| `VLLM_TARGET_DEVICE` | Target device | cuda |

Example memory‑safe rebuild:
```bash
FA3_MEMORY_SAFE_MODE=1 MAX_JOBS=1 NVCC_THREADS=1 ./extras/dev-setup.sh
```

Skip FA3 (temporary troubleshooting):
```bash
VLLM_DISABLE_FA3=1 ./extras/dev-setup.sh
```

## 🐛 Troubleshooting Highlights
| Symptom | Likely Cause | Action |
|---------|--------------|--------|
| `cicc killed (signal 9)` | Host/container RAM/OOM during FA3 | Re-run with FA3_MEMORY_SAFE_MODE=1 |
| `torch.cuda.is_available() == False` | Driver / device mapping issue | Re-launch with `-GPUCheck`; verify nvidia-smi output |
| Slow rebuilds | No cache or high MAX_JOBS thrash | Lower MAX_JOBS; ensure FETCHCONTENT_BASE_DIR persists |
| Missing Machete ops | Build skipped / wrong CMAKE_ARGS passed | Ensure `CMAKE_ARGS` not forcing `-DENABLE_MACHETE=OFF` |

## 📖 More Detail
See **`CONTAINER_SETUP_COMPLETE.md`** for deep dive (workflow, extended troubleshooting, notes on host GPU configs).

## 🧹 Clean & Minimal
Obsolete multi-launcher scripts removed. Only:
- Unified PowerShell: `run-vllm-dev.ps1`
- Unified Bash: `run-vllm-dev.sh`
- Core build helper: `dev-setup.sh`

Everything else supports validation or docs.
