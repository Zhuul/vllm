# extras/ overview

This directory hosts all non-core assets: container/build tooling, configs, testing, storage helpers, and optional patches. The goals are clarity, single-responsibility, and easy extension without touching the vLLM core.

Suggested layout (implemented here):

- podman/ — Podman-specific build/launch wrappers and helpers
- configs/ — Centralized, declarative versions and build configuration
- secrets/ — Gitignored area for local tokens/config (not committed)
- testing/ — Test/benchmark harness, matrices, and results
- storage/ — External volumes and cache management helpers
- patches/ — Optional patch/plug-in mechanism for controlled tweaks

Primary entrypoint: use `extras/podman/` as the canonical way to build and run the dev container.

Deprecation: the legacy launchers `extras/run-vllm-dev.sh` and `extras/run-vllm-dev.ps1` are deprecated and now forward to the Podman wrappers. Please switch to `extras/podman/run.sh` (Linux/macOS) or `extras/podman/run.ps1` (Windows).

## Quick start

- Edit `extras/configs/build.env` to set CUDA/UBI/Python defaults.
- Use `extras/podman/build.sh` to build images with those defaults.
- Use `extras/podman/run.ps1` (Windows) or `extras/podman/run.sh` (Linux/macOS) to run the dev container.

Examples

- Windows (PowerShell):
    - Build image: `./extras/podman/run.ps1 -Build`
    - GPU check: `./extras/podman/run.ps1 -GPUCheck`
    - Setup build: `./extras/podman/run.ps1 -Setup -WorkVolume vllm-work -Progress`

- Linux/macOS (bash):
    - Build image: `extras/podman/run.sh --build`
    - GPU check: `extras/podman/run.sh --gpu-check`
    - Setup build: `extras/podman/run.sh --setup --work-volume vllm-work --progress`

## Secrets

Place tokens in `extras/secrets/` per its README and never commit them. Load them in session or bind-mount into containers.

## Testing

See `extras/testing/README.md` for defining a matrix, recording results, and comparing runs.

## Storage

See `extras/storage/README.md` for model/cache volume guidance for performance and reproducibility.

## Patches

If you need to tweak upstream vLLM without forking, use `extras/patches/` to stage diffs and apply them during build.
