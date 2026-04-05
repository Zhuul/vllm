# Extras Docs

This directory documents fork-local workflow that intentionally stays outside
the upstream vLLM source tree.

Use these docs when working on local setup, patch layering, smoke validation,
or other customization that should remain isolated under `extras/`.

The top-level `README.md` is intentionally kept close to upstream. Fork-local
workflow notes should live here (or elsewhere under `extras/`) instead of being
added to synced upstream-facing documents.

## Documents

- [patch-workflow.md](patch-workflow.md):
  sync, setup, patch-manager flow, agnostic patch authoring rules, and
  validation profiles.
- [../testing/README.md](../testing/README.md):
  smoke harness details, profile definitions, example commands, and artifacts.

## Quick Start

- Start with `patch-workflow.md` for the local container/setup flow.
- Use `../testing/README.md` for the `image-validation` and `edit-mode`
  profiles plus the DeepSeek smoke/cache helpers.

## Working Rule

When a local compatibility fix is needed, prefer this order:

1. Keep the synced upstream file unchanged in the repository.
2. Express the fix as an `extras/patches/*.diff` patch.
3. Register it in `extras/patches/patches.json`.
4. Add an idempotent fallback in `extras/tools/patch_manager.py` only if patch
   drift is likely after future upstream syncs.
5. Validate the patch with `git apply --check` before relying on it in setup.

The goal is to make patches depend on source or toolkit behavior, not on host
details such as Podman, WSL, PowerShell, or Windows path conventions.
