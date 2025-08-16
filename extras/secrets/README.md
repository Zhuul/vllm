# secrets directory

This directory is gitignored and intended for local-only secret material such as model hub tokens.

Files are expected to be simple KEY=VALUE lines that can be sourced by shell scripts.

Examples:
- hf-credentials.env
- cn-modelhub-credentials.env

Do NOT commit secrets. See README for details.
