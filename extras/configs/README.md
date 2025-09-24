# configs README

This folder centralizes editable configuration for images/builds:

- build.env: Bash-exported defaults (CUDA/UBI/Python/vLLM tag, arch list, volumes)
- build.yaml (optional): YAML equivalent for tools that prefer structured configs
- versions.json (optional): Machine-friendly manifest for automation

Consumers (scripts/Containerfiles) should read values from here and allow runtime overrides via environment variables.

CUDA 13 arch policy

- TORCH_CUDA_ARCH_LIST defaults to: "8.0 8.6 8.9 9.0 12.0 13.0"
- CUDAARCHS defaults to: "80;86;89;90;120"

Both `extras/podman/run.ps1` and `extras/podman/run.sh` read build.env and pass these values into builds and setup runs.
