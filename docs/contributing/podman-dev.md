---
title: Podman-first Development Environment
---

This guide documents the Podman-first development workflow for building vLLM from source with CUDA and PyTorch nightly.

Primary entrypoint

- Windows (PowerShell): `./extras/podman/run.ps1`
- Linux/macOS (bash): `extras/podman/run.sh`

Legacy launchers at `extras/run-vllm-dev.ps1` and `extras/run-vllm-dev.sh` are deprecated and forward to the Podman wrappers.

Prerequisites

- Podman with GPU CDI enabled (on Windows, use Podman Desktop + WSL; ensure NVIDIA drivers and CUDA are installed on the host).
- Optional named volume for build/work space, e.g., `vllm-work`.

Quick start

Windows (PowerShell):

```powershell
./extras/podman/run.ps1 -Build
./extras/podman/run.ps1 -GPUCheck
./extras/podman/run.ps1 -Setup -WorkVolume vllm-work -Progress
```

Linux/macOS (bash):

```bash
extras/podman/run.sh --build
extras/podman/run.sh --gpu-check
extras/podman/run.sh --setup --work-volume vllm-work --progress
```

Notes

- The image uses CUDA 12.9 UBI9 and installs PyTorch nightly cu129 first to ensure latest GPU arch support (including sm_120 when present).
- The setup step performs an editable vLLM install without downgrading torch family packages.
- Use a named Podman volume for `/opt/work` to avoid `/tmp` tmpfs pressure and to speed up rebuilds.
