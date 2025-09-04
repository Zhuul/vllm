# extras/ overview

This directory hosts non-core assets: container/build tooling, configs, testing, storage helpers, and optional patches. Everything here is designed to be self-contained and safe for Windows + WSL and Linux.

Layout

- podman/ — Podman-first run/build wrappers (Windows PowerShell + bash)
- configs/ — Centralized versions and build configuration
- patches/ — Optional patches applied automatically at container start
- storage/ — Volume/caching helpers
- testing/ — Test harness, matrices, and results
- secrets/ — Local, gitignored credentials

Primary entrypoint: `extras/podman/run.ps1` (Windows) or `extras/podman/run.sh` (Linux/macOS).

## What’s new

- CUDA 13.0 base (Rocky Linux 9) with PyTorch nightlies and ffmpeg stack.
- Default CUDA arch policy updated for CUDA 13 (drops SM70/SM75):
    - TORCH_CUDA_ARCH_LIST: "8.0 8.6 8.9 9.0 12.0 13.0"
    - CUDAARCHS: "80;86;89;90;120"
    - Override via `extras/configs/build.env` or environment variables.
- Auto-patch on container start (idempotent, CRLF-safe):
    - 0001-cumem-alloc-env-fallback.diff — prefer PYTORCH_ALLOC_CONF
    - 0002-cub-reduce-to-sum-cuda13.diff — CUB Reduce->Sum compatibility
- Setup flow is CRLF/WSL-safe: scripts run from a normalized temp copy.

## Quick start

1) Configure (optional): edit `extras/configs/build.env`.
2) Build the image:
     - Windows: `./extras/podman/run.ps1 -Build`
     - Linux/macOS: `extras/podman/run.sh --build`
3) GPU check:
     - Windows: `./extras/podman/run.ps1 -GPUCheck`
     - Linux/macOS: `extras/podman/run.sh --gpu-check`
4) Install vLLM in editable mode (compiles extensions):
     - Windows: `./extras/podman/run.ps1 -Setup -WorkVolume vllm-work -Progress`
     - Linux/macOS: `extras/podman/run.sh --setup --work-volume vllm-work --progress`

Notes for Windows/WSL

- The launcher maps /dev/dxg and WSL libraries automatically; NV env vars are set safely (no "void").
- PowerShell quoting for inline Python:
    - `./extras/podman/run.ps1 -Command 'python -c "import torch;print(torch.__version__)"'`
- Scripts avoid in-place edits on the mounted repo to prevent permission errors.

## Patches

Place `.diff` files in `extras/patches/`. On container start, a helper normalizes CRLF, applies patches, or uses targeted Python fallbacks for known fragile hunks. No source-file changes are committed to the host by design.

## Storage and caches

Use a named volume for large builds and cache:

- `-WorkVolume vllm-work` (PowerShell)
- `--work-volume vllm-work` (bash)

## Testing

See `extras/testing/README.md` for matrix and run helpers.

## Secrets

See `extras/secrets/README.md` for token handling.
