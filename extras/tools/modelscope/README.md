# ModelScope Helpers

Scripts in this directory help reuse existing ModelScope cached models when
developing inside the vLLM dev container.

## Components

- `model_profiles.yaml` enumerates handy launch profiles (serve arguments,
  environment overrides, and KV calibration metadata).
- `manage.py` provides a CLI with the following subcommands:
    - `list` — show available profiles.
    - `serve --profile NAME` — launch the OpenAI-compatible server for a profile.
    - `kv-calibrate --profile NAME` — generate KV cache scales with llm-compressor.

All commands respect the ModelScope cache path configured via
`MODELSCOPE_CACHE` (default `/home/vllmuser/.cache/modelscope` inside the dev
container). Update `extras/configs/modelscope.env` to bind mount your host
Podman volumes before running these helpers.
