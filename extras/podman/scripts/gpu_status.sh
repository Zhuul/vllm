#!/usr/bin/env bash
set -euo pipefail

# Helper to show GPU/CDI status under Podman (Linux/WSL)

podman info --format json | jq '.host' || podman info || true

# Show CDI devices if available
podman cdi list || true
