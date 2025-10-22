# Agent quickstart: vLLM Development with GPU + Patches

This document is the operator-facing playbook for the complete vLLM development
workflow: GPU-capable Podman backend on Windows WSL2 + Fedora CoreOS, patch
management for CUDA/vLLM compatibility, and editable container development.

## � Markdown Guidelines for GitHub CI

**Follow these rules to pass `markdownlint` checks on first try:**

- **Headings**: Always surround with blank lines (above and below). Start at beginning of line (no indentation).
- **Heading Hierarchy**: Increment by one level only (h1 → h2 → h3, never h1 → h3).
- **Code Blocks**: Always add blank line before and after. Specify language (`` ```bash ``, `` ```powershell ``, `` ```json ``).
- **Lists**:
    - Ordered lists: Use sequential numbering (`1.`, `2.`, `3.`) not parentheses (`1)`) or repeated (`1.`, `1.`, `1.`)
    - Nested items: Indent with 4 spaces (not 2)
    - Surround lists with blank lines
- **No Multiple Blank Lines**: Use only one blank line between sections
- **Trailing Spaces**: Remove all trailing whitespace (except 2 spaces for hard line breaks)
- **Shell Comments**: Keep `#` comments **inside** code blocks, not outside (prevents them being parsed as headings)
- **File Endings**: End all files with exactly one newline

**Quick validation**: Run `pre-commit run markdownlint --all-files` before committing.

---

## �🚨 CRITICAL WORKFLOW RULE: ALWAYS WORK ON MAIN BRANCH

**⚠️ NEVER create feature branches without explicit approval first!**

- **ALL development work must happen directly on `main` branch**
- **Commit frequently** to avoid loss of work during merge conflicts
- **No feature branches** unless specifically requested by the user
- This avoids confusion, merge conflicts, and ensures security fixes stay applied

## Technical Context

**Context**: This fork maintains patches for recent CUDA (13.x) compatibility,
experimental vLLM features, and development tooling. The challenge is managing
patches that must be applied at different build stages:

- **Pre-CUDA compile**: Core compatibility (e.g., `cumem.py` for CUDA 13)
- **Post-CUDA, pre-vLLM compile**: CUDA toolkit integration patches
- **Post-vLLM compile**: Runtime/experimental patches (future)

It complements the detailed Patch Workflow doc in `extras/docs/patch-workflow.md`.

---

## TL;DR

1. Provision the WSL Podman machine with GPU enabled

```powershell
pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Install
```

1. (Optional) Tune resources or refresh GPU config

```powershell
pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Install -CpuCount 8 -MemoryGB 16
pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Update
```

1. Validate GPU availability from inside the distro

```powershell
wsl -d podman-machine-default -- bash -lc "ls -l /dev/dxg; nvidia-smi || true"
```

---

## What the helper does

- Initializes `podman-machine-default` on WSL with the latest Fedora CoreOS image.
- Configures CPU/RAM sizing (auto-detects but accepts `-CpuCount`/`-MemoryGB`).
- Ensures the machine starts immediately and exposes the NVIDIA CDI devices required by Podman Desktop.
- Re-runs GPU wiring in place via `-Update`, or removes the machine entirely with `-Remove`.

---

## Common options

- `-Install`: Create the machine if missing (safe to rerun).
- `-Update`: Refresh GPU/CDI bindings on an existing machine.
- `-Remove`: Tear down the machine entirely.
- `-CpuCount <n>` / `-MemoryGB <n>`: Override the auto-sizing heuristics.
- `-PodmanPath <path>`: Explicit Podman CLI path when elevation requires it.

---

## Troubleshooting

### Podman machine fails to start

- Run with elevation once so the helper can register CDI devices: `Start-Process pwsh -Verb RunAs -ArgumentList 'extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Install'`.
- Use `-Remove` then `-Install` if initialization leaves the machine in a broken state.

### GPU missing inside the container

- Confirm `nvidia-smi` works in Windows and WSL: `wsl -d podman-machine-default -- nvidia-smi`.
- Re-run the helper with `-Update` to regenerate CDI specs.
- Ensure Podman Desktop (or CLI) is ≥4.9 for CDI-aware GPU passthrough.

### Container rebuild issues

- `extras/podman/run.ps1 --build --no-cache` rebuilds the image from scratch.
- Patches failing to apply: inspect `extras/patches/*.diff` and `extras/patches/python-overrides.txt` for path drift after upstream syncs.
- Nightly torch skew: always install `torch torchvision torchaudio` together (handled in the Dockerfile). If manual install is needed, pass the shared `--index-url` for the nightly wheelhouse.

---

## MCP Server Issues

### paper-search-mcp Authentication Errors

**Problem**: Hosted MCP servers from Smithery fail with OAuth authentication errors:

```text
Error 401 status sending message to https://server.smithery.ai/@openags/paper-search-mcp/mcp: 
{"error":"invalid_token","error_description":"Missing Authorization header"}
```

**Root Cause**: VS Code MCP integration doesn't fully support OAuth flow for hosted servers.

**Solutions**:

1. **Local Installation** (Recommended):

    ```bash
    # Use Smithery CLI for local install
    npx -y @smithery/cli install @openags/paper-search-mcp --client vscode
    
    # Or install from source
    git clone https://github.com/openags/paper-search-mcp.git
    cd paper-search-mcp
    pip install -e .
    ```

2. **Use Alternative**: Use direct Python package installation instead of hosted service.

**Status**: Use hf-mcp-server (official HuggingFace) which works reliably with VS Code MCP integration.

---

## Dev loop after provisioning

The complete development cycle with patch management:

1. **Sync upstream changes** (preserves `extras/` and patches):

    ```powershell
    pwsh extras/tools/fork-sync/sync_with_upstream.ps1
    ```

    **Fork Sync Tooling Details**:

    - **Purpose**: Safely merge upstream `vllm-project/vllm` changes while preserving fork-specific customizations
    - **Protected Paths**: Automatically backs up and restores `extras/` directory and `.github/workflows/fork-sync.yml`
    - **Process**: Fetches upstream, attempts fast-forward merge, falls back to regular merge if needed
    - **Safety**: Validates clean working tree, handles in-progress merges/rebases, restores protected content
    - **Windows Support**: `sync_with_upstream.ps1` wrapper locates Git Bash and executes the shell script
    - **Customization**: Override protected paths via `PROTECTED_PATHS="path1 path2"` environment variable
    - **Usage**: Run from repository root, accepts optional remote/branch parameters
    - **Post-sync**: Automatically commits restored protected paths and suggests push command

2. **Build container with pre-build patches**:

    ```powershell
    # The entrypoint applies patches from extras/patches/python-overrides.txt
    # before CUDA compilation (e.g., cumem.py for CUDA 13 compatibility)
    extras/podman/run.ps1 --build
    ```

3. **Enter development mode**:

    ```powershell
    # Interactive shell with editable vLLM install
    extras/podman/run.ps1 -Interactive

    # Or run with GPU validation
    extras/podman/run.ps1 -GPUCheck
    ```

4. **Inside container - test your changes**:

    ```bash
    # The workspace is mounted as /workspace, vLLM is editable-installed
    cd /workspace
    python -c "import vllm; print(vllm.__version__)"

    # Test GPU + recent CUDA
    python -c "import torch; print(f'CUDA: {torch.version.cuda}, GPU: {torch.cuda.get_device_name()}')"
    ```

**Patch Management Notes**:

- Pre-CUDA overlays live in `extras/patches/python-overrides.txt`; `dev-setup.sh` copies listed files into a container-local overlay directory (defaults to `/opt/work/python-overrides`) and registers a `.pth` so they shadow upstream modules without leaving Git diffs.
- Container startup entrypoint normalizes line endings and, by default, does not apply any `.diff` patches to the bind-mounted `/workspace` (set `APPLY_PATCHES_ON_START=1` to opt-in).
- `run.ps1 -Setup` invokes `extras/podman/dev-setup.sh`, which mirrors `/workspace` into a container-local source overlay (e.g., `/opt/work/src-overlay` or `/tmp/src-overlay`), applies all `extras/patches/*.diff` inside that overlay, and installs vLLM in editable mode from the overlay with `FETCHCONTENT_BASE_DIR=$TMPDIR/deps`.
- No reset step is needed anymore: the host worktree remains pristine; all patching occurs in the container overlay.
- Post-CUDA or ad-hoc tweaks can still be applied interactively inside the container, but prefer encoding them as `.diff` files or overlay directives so future rebuilds stay reproducible.

---

## Clean-up / reset

```powershell
# Remove the Windows podman context (optional)
podman system connection rm wsl-podman-default -f

# Remove the Podman machine entirely
pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Remove
```

---

## MCP Servers

This repo uses MCP (Model Context Protocol) servers for enhanced research, automation, and development workflows.

**Active servers**: Cloudflare docs, GitHub, Markitdown, Playwright, Microsoft Learn, Clear Thought, Semantic Scholar (academic papers), Neo4j Agent Memory (when database available)

**Complete documentation**: See `extras/.ai/.mcp-servers.md` for:

- Installation guides and patterns
- Server comparison tables
- Usage examples and best practices
- Troubleshooting tips
- Neo4j database setup options (Docker/AuraDB/Desktop)

**Quick install pattern**:

```powershell
# Via Smithery CLI
npx -y @smithery/cli@latest install @author/server-name --client vscode
```

**Note**: Never commit personal API keys or credentials. Use environment variables or secure storage.

---

## Remove the Podman machine

```powershell
pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Remove
```

---

## Fork Sync Tooling (`extras/tools/fork-sync/`)

**Critical Infrastructure**: These scripts maintain alignment with upstream `vllm-project/vllm` while preserving our fork-specific customizations.

## Scripts Overview

- **`sync_with_upstream.ps1`**: PowerShell wrapper for Windows environments
    - Locates Git Bash installation automatically
    - Converts Windows paths to MSYS format for bash execution
    - Passes through all parameters to the shell script

- **`sync_with_upstream.sh`**: Core bash script that performs the sync operation
    - Fetches from upstream remote (default: `upstream/main`)
    - Backs up protected paths before merge
    - Attempts fast-forward merge, falls back to regular merge
    - Restores protected content and commits changes
    - Ensures `.gitignore` includes `extras/secrets/*.env`

## Protected Paths (Default)

- `extras/` - All fork-specific tooling, patches, configurations
- `.github/workflows/fork-sync.yml` - Fork-specific GitHub Actions workflow

## Usage Patterns

```powershell
# Standard sync (most common)
pwsh extras/tools/fork-sync/sync_with_upstream.ps1

# Sync from different remote/branch
pwsh extras/tools/fork-sync/sync_with_upstream.ps1 upstream dev

# Custom protected paths
$env:PROTECTED_PATHS = "extras custom-dir"; pwsh extras/tools/fork-sync/sync_with_upstream.ps1
```

### Safety Features

- **Pre-flight checks**: Validates git repository, clean working tree, no in-progress operations
- **Backup/restore**: Creates temporary backup of protected paths before merge
- **Automatic fallback**: If fast-forward fails, attempts regular merge with --no-edit
- **Post-sync validation**: Commits restored paths, suggests push command
- **Error handling**: Exits cleanly on conflicts, preserves working state

### When to Use

- **After upstream releases**: Sync latest vLLM changes before development
- **Before major work**: Ensure fork is current to minimize future conflicts  
- **Conflict resolution**: When manual git operations create divergence
- **Regular maintenance**: Periodic sync to stay aligned with upstream

### Troubleshooting

- **Merge conflicts**: Resolve manually, then re-run script to restore protected paths
- **Missing upstream remote**: Add with `git remote add upstream https://github.com/vllm-project/vllm.git`
- **Permission issues**: Ensure Git Bash is accessible, run PowerShell as needed
- **Path conflicts**: Check `PROTECTED_PATHS` environment variable or script defaults

**⚠️ Always use this tooling instead of manual `git pull upstream/main`** - it prevents accidental loss of fork customizations.

---

## Related docs

- **Patch workflow and container overlays**: `extras/docs/patch-workflow.md`
- **Fork sync helpers**: `extras/tools/fork-sync/README.md`
- **Current patches**: `extras/patches/python-overrides.txt` (pre-CUDA compile patches)
- **Build automation**: `extras/ci/build.yaml`, `extras/configs/build.env`

## Quick reference

**Full cycle from scratch**:

```powershell
# 1. Provision WSL2 + GPU
pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Install

# 2. Sync upstream (if needed)  
pwsh extras/tools/fork-sync/sync_with_upstream.ps1

# 3. Build with patches
extras/podman/run.ps1 --build

# 4. Develop
extras/podman/run.ps1 -Interactive
```

**Reset everything**:

```powershell
# Remove Podman machine
pwsh extras/tools/enable-podman-latest-fedora-wsl-gpu.ps1 -Remove

# Remove Windows podman context (if created)
podman system connection rm wsl-podman-default -f
```
