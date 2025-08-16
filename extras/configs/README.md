# configs README

This folder centralizes editable configuration for images/builds:

- build.env: Bash-exported defaults (CUDA/UBI/Python/vLLM tag, arch list, volumes)
- build.yaml (optional): YAML equivalent for tools that prefer structured configs
- versions.json (optional): Machine-friendly manifest for automation

Consumers (scripts/Containerfiles) should read values from here and allow runtime overrides via environment variables.
