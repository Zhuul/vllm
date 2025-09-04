# Podman helpers for vLLM

These wrappers build and run a CUDA 13 dev container with PyTorch nightlies.

Key features

- Windows/WSL and Linux support (PowerShell and bash launchers)
- Auto-apply patches on container start (CRLF-safe, idempotent)
- CUDA arch policy aligned with CUDA 13 (no SM70/SM75)
- Named volume mounting for faster builds (`/opt/work`)

Launchers

- Windows: `extras/podman/run.ps1`
- Linux/macOS: `extras/podman/run.sh`

Common options

- Build: `-Build` (ps1) / `--build` (sh)
- GPU check: `-GPUCheck` / `--gpu-check`
- Setup (editable install): `-Setup` / `--setup`
- Work volume: `-WorkVolume NAME` / `--work-volume NAME`
- Progress: `-Progress` / `--progress`
- Mirror sources: `-Mirror` / `--mirror`

Notes

- Scripts normalize CRLF by running a temp copy to avoid chmod/sed on Windows mounts.
- CUDA arch defaults can be changed in `extras/configs/build.env`.
- The entrypoint is `apply-patches-then-exec.sh`, which runs patching before your command.
