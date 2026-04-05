# Patch workflow for vLLM development

This document summarizes the intended workflow for keeping the fork in sync, preparing the
container environment, and layering patches for experimentation. It covers both the automation
running on GitHub and the local steps you take before hacking on the codebase.

## 1. Keep the fork aligned with upstream

- The scheduled workflow `.github/workflows/fork-sync.yml` copies the upstream repository
  (`vllm-project/vllm`) into the fork (`Zhuul/vllm`) every day.
- Files that only exist in the fork—`extras/`, the fork-sync workflow itself, and other
  additive automation—are marked as *protected*. The sync script (`extras/tools/fork-sync/`
  `sync_with_upstream.{sh,ps1}`) backs them up before the merge and restores them afterward so
  an upstream update never removes local tooling.
- When developing locally, run the same helper script to merge upstream changes. That guarantees
  the protected paths stay identical between CI and your machine.

## 2. Container setup and pre-build overlays

- Launching `extras/podman/run.ps1 -Setup` (or `run.sh` on Linux) builds the dev container if
  needed and starts it with the entrypoint `extras/podman/entrypoint/apply-patches-then-exec.sh`.
- The actual patch orchestration is owned by the Python patch manager
  `extras/tools/patch_manager.py`. Shell entrypoints such as
  `apply_patches.sh` and `apply_patches_overlay.sh` are only thin launchers.
- The entrypoint normalizes Windows line endings, configures `git` to trust the mounted
  workspace, and can invoke `extras/patches/apply_patches_overlay.sh` before any build commands run.
  By default this is disabled to avoid mutating the bind-mounted workspace in interactive shells
  or image-only runs; enable it by setting `APPLY_PATCHES_ON_START=1` if you really need pre-setup
  patch application.
- Patch registration lives in `extras/patches/patches.json`. Each entry points at a diff file in
  `extras/patches/`, and the patch manager applies them in order.
- Overlay definitions live in `extras/patches/python-overrides.txt`. Each line copies a file from
  the repository into an overlay directory inside the container (defaults to
  `/opt/work/python-overrides`) and can apply transforms (for example, adapting
  `vllm/device_allocator/cumem.py` for CUDA 13).
- Overlay mode must leave the repository clean. The helper now fails early if a patch no longer
  applies or if any tracked file stays modified, signalling that the overlay definitions need an
  update instead of silently mutating the tree.

## 3. Editable install

- `extras/podman/dev-setup.sh` performs the editable install. It exports
  `SETUPTOOLS_SCM_ROOT=/workspace` and `SETUPTOOLS_SCM_IGNORE_VCS_ERRORS=1` so
  `setuptools_scm` resolves the version without probing the temporary build directory.
- After publishing overlays it re-checks `git status`. If any tracked file is dirty, the script
  stops immediately, ensuring the pre-build stage remains reproducible.

## 4. Post-build experimentation

- Once the setup script finishes, drop into an interactive shell with `run.ps1 -Interactive`.
  Use this phase for manual edits, runtime experiments, or additional scripted patches.
- Future customizations can be organized under `extras/patches/post-setup.d/` (or a similar
  directory) and invoked from the interactive helper so that experimental work is clearly
  separated from the deterministic pre-build overlay stage.

## 4.1 Creating new extras patches

- Prefer adding compatibility or environment-specific fixes as new files under `extras/patches/`
  instead of editing synced upstream files directly. In practice, this means creating the source
  change temporarily only to extract a patch, then restoring the upstream file.
- Register every new patch in `extras/patches/patches.json` so the normal overlay/setup flow picks
  it up automatically.
- If a patch is likely to drift as upstream changes, add a `patch_fallback(...)` handler in
  `extras/tools/patch_manager.py`. Keep that fallback idempotent so it becomes a no-op once the
  upstream tree already contains the needed behavior.
- Validate a new patch with `git apply --check extras/patches/<patch>.diff` before relying on it
  in the container setup flow.
- When generating a new patch, prefer producing it from a real diff instead of hand-writing hunk
  headers. That is more reliable for long files and reduces patch format errors.
- Include a short compatibility comment inside the patched code block when the reason is subtle.
  This is especially important for toolkit, header, or platform mismatches so later agents such as
  Jules AI can see why the patch exists without rereading the whole history.

## 4.1.1 Agnostic patch rules

- A proper extras patch should describe a source-level or toolkit-level fact, not a host-shell
  fact. The desired result should be identical whether setup is launched from PowerShell, bash,
  Podman, WSL, or a future wrapper.
- Avoid embedding host-specific assumptions into the patch body itself. In particular, do not make
  patch behavior depend on Windows path separators, Podman mount paths, PowerShell syntax, or WSL
  detection unless the upstream source truly requires platform-specific code.
- Prefer matching on stable code structure or public API shape. For example, the current
  `cuda-memcpy-batch-compat` patch is based on the `cuMemcpyBatchAsync` function signature exposed
  by the CUDA headers, which is a toolkit property rather than a host-environment property.
- If a patch exists only because of one local launcher or one transient environment quirk, fix that
  launcher or environment logic first instead of encoding the workaround in the patch.
- When a fallback is required in `patch_manager.py`, keep it idempotent and based on target-file
  content. A fallback should succeed because the source shape matches an expected upstream pattern,
  not because a specific shell happened to invoke setup.
- Before considering a patch complete, validate both of these conditions:
  1. `git apply --check extras/patches/<patch>.diff` passes against the current tree.
  2. The patch rationale still makes sense if the same repository is built from a different host
     shell or container wrapper.

## 4.2 Validation profiles

- The standard post-setup validation entrypoint is `python extras/testing/run_tests.py --profile <name>`.
  Profile definitions live in `extras/testing/test_matrix.yaml`, and the harness details live in
  `extras/testing/README.md`.
- `image-validation` is the image/runtime sanity profile. It runs `env_smoke` first to capture a
  runtime report, then runs `deepseek_smoke` to verify an actual offline generation path.
- `edit-mode` is the editable-install regression profile. It runs the lightweight pytest smoke
  command from the `smoke` suite and then the same `deepseek_smoke` check, which makes it useful
  after upstream syncs or patch changes.
- For the current local workflow, prefer writing result files under `build/testing-results/`, for
  example:

  ```bash
  python extras/testing/run_tests.py --profile image-validation \
    --output /workspace/build/testing-results/image-validation.json

  python extras/testing/run_tests.py --profile edit-mode \
    --output /workspace/build/testing-results/edit-mode.json
  ```

- Each run writes both a machine-readable JSON file and a readable `.txt` summary, plus any
  per-command artifacts under the sibling `*-artifacts/` directory.

By enforcing clean working trees after each automated step, the workflow mirrors what CI expects
and keeps the Windows-mounted repository free of unexpected modifications.

## 5. Handling secrets for local testing

- Real API credentials live in `extras/secrets/*.env`. Copy the provided `*.env.example`
  templates, fill in your personal tokens (for example, Hugging Face access keys), and keep them
  next to the examples with a `.env` suffix.
- The helpers now auto-discover every `extras/secrets/*.env` file (excluding `*.env.example`) and
  forward them to `podman run` through `--env-file`, so everything inside the dev container can use
  the same credentials without baking them into the image.
- All `extras/secrets/*.env` files are ignored by Git; only the example templates belong in the
  repository. Verify with `git status` before committing changes.

## 6. GPU passthrough on Windows + WSL2 Podman

- Make sure your Windows host has the latest NVIDIA driver with WSL2 support and that `wsl --update`
   has run recently.
- If you prefer to install manually, use `podman machine init --image <Fedora CoreOS qcow>` from an elevated shell.
    > **Heads-up:** Podman on Windows currently rejects `template://` URIs, so always point it at an actual
    > local file or an HTTP(S) download.
- From the repository root, run the helper script:

  ```powershell
  pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Install
  ```

  Add `-CpuCount <n>` / `-MemoryGB <n>` to override auto-selected resources. Use `-Update` to refresh NVIDIA CDI
  bindings without tearing the VM down, or `-Remove` for a clean slate. When elevation is required, the script will
  re-launch itself via `Start-Process -Verb RunAs` and propagate the detected Podman CLI path automatically.

- After the script restarts the machine, launch `extras/podman/run.ps1 -GPUCheck` (or `run.sh --gpu-check`)
   to confirm that `/dev/dxg` and the CUDA libraries are visible from inside the dev container. If the helper
   reports `Image missing. Use --build.`, rebuild the development container first via `extras/podman/run.ps1 --build`.

If the helper still reports missing `/dev/dxg`, open Podman Desktop, ensure GPU sharing is enabled for
the selected machine, and rerun the script (include `-Rootful` if you skipped it the first time, since
rootless containers cannot mount GPU device nodes). When running on other distributions, replicate the
script’s steps manually: install `nvidia-container-toolkit`, and generate a CDI spec via
`nvidia-ctk cdi generate --mode wsl`.
