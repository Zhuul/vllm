# Podman helpers for vLLM

This folder contains Podman-specific wrappers. They preserve back-compat by calling the existing scripts in `extras/` when present.

- Containerfile: Thin wrapper that defers to `extras/Dockerfile` by default.
- build.sh: Builds the image using values from `../configs/build.env`.
- entrypoint/: Optional entrypoint scripts used inside containers.
- scripts/: Utility helpers for Podman machine/GPU/volumes.

See README for usage.

Documentation: see `docs/contributing/podman-dev.md` for the Podman-first workflow and deprecation notes for legacy launchers.
