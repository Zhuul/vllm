#!/usr/bin/env bash
set -euo pipefail

# Deprecated: please use extras/podman/run.sh. This script forwards for back-compat.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd)
exec "${SCRIPT_DIR}/podman/run.sh" "$@"
