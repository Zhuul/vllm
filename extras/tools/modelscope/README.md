# ModelScope Helpers

Scripts in this directory help reuse existing ModelScope cached models when
developing inside the vLLM dev container.

## Components

- `model_profiles.yaml` enumerates handy launch profiles (serve arguments,
  environment overrides, and KV calibration metadata).
- `manage.py` provides a CLI with the following subcommands:
    - `list` — show available profiles.
    - `serve --profile NAME` — launch the OpenAI-compatible server for a profile.
    - `install MODEL_ID` — download/prepare a ModelScope snapshot (creates matching Podman volumes).
    - `info MODEL_ID` — display metadata for a cached snapshot.
    - `check MODEL_ID` — validate that a snapshot can be loaded fully offline.
    - `delete MODEL_ID` — remove the snapshot (optional volume cleanup).
    - `kv-calibrate --profile NAME` — generate KV cache scales using profile settings.
    - `kv-calibrate --model MODEL_ID` — ad-hoc KV calibration with sensible defaults.

All commands respect the ModelScope cache path configured via
`MODELSCOPE_CACHE` (default `/home/vllmuser/.cache/modelscope` inside the dev
container). Update `extras/configs/modelscope.env` to bind mount your host
Podman volumes before running these helpers.
