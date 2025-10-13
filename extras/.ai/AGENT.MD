# Agent quickstart: vLLM Development with GPU + Patches

This document is the operator-facing playbook for the complete vLLM development
workflow: GPU-capable Podman backend on Windows WSL2 + Rocky Linux 10, patch
management for CUDA/vLLM compatibility, and editable container development.

## 🚨 CRITICAL WORKFLOW RULE: ALWAYS WORK ON MAIN BRANCH

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
1) Provision the Rocky 10 WSL distro and enable GPU + Podman

```powershell
pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -MachineName podman-machine-default -CacheRoot C:\podman-images
```

pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -MachineName podman-machine-default -CreatePodmanContext -PodmanContextName wsl-podman-default -SkipReboot
podman context use wsl-podman-default
podman info
```

3) Validate GPU availability from inside the distro

```powershell
wsl -d podman-machine-default -- bash -lc "ls -l /dev/dxg; nvidia-smi || true"
```

---

## What the helper does

- Downloads the Rocky Linux 10 UBI container rootfs (or uses `-ImagePath`) and imports it into WSL2
- Enables systemd via `/etc/wsl.conf` and gracefully restarts the distro
- Installs base packages: `podman`, `openssh-server`, `fuse-overlayfs`, `slirp4netns`, `iptables`
- Creates a default `podman` user for rootless Podman; enables `podman.socket` in the user session
- Installs NVIDIA Container Toolkit and generates a CDI spec for WSL GPUs
- (Optional) Sets up a Windows `podman` context that connects to the WSL user socket over SSH
nvidia-container-toolkit package resolution issues) but the final GPU test should succeed.

---

## Common options

- `-MachineName <name>`: WSL distro name (default: `podman-machine-default`)
- `-ImagePath <file-or-url>`: Override the Rocky UBI image; `.tar.xz` or `.tar` supported
- `-CacheRoot <dir>`: Cache downloads/import data outside of `%LOCALAPPDATA%`
- `-SkipReboot`: Skip the WSL restarts (you can manually `wsl --terminate <name>` later)
- `-Reset`: Unregister the distro before importing
- `-CreatePodmanContext`: Create a Windows `podman` context (defaults: user `podman`, context `wsl-<name>`) 

---

## Troubleshooting

**WSL/Import Issues**:
- Import fails with `.tar.xz` not supported
  - Decompress to `.tar` and re-run: `tar -xf Rocky-10-Container-UBI.latest.x86_64.tar.xz`
- `nvidia-smi` missing
  - Ensure latest NVIDIA Windows driver with WSL support; re-run the helper to regenerate CDI
- Systemd not active after restart
  - `wsl --terminate <name>` and open a new shell to re-enter the distro; check `/etc/wsl.conf`

**🚨 CRITICAL: Sparse VHD Errors (WSL Import Issues)**:
If you get "Sparse VHD support is currently disabled" errors, **run as Administrator**:
```powershell
Start-Process pwsh -ArgumentList "-NoExit", "-Command", "Set-Location 'C:\sources\github\vllm'; pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -Reset -ImagePath 'C:\ProgramData\podman-images\Rocky-10-WSL-Base.latest.x86_64.wsl'" -Verb RunAs
```
This allows the script to convert the Rocky WSL image or toggle sparse support as needed.

**Compressed image errors (unexpected EOF)**:
- Cause: A corrupted/incomplete cached download of the Rocky UBI archive
- Fixes:
  1) Re-run the helper; it now auto-detects and clears the bad cache and retries once
  2) Manually delete the cache: `C:\ProgramData\podman-images\Rocky-10-Container-UBI.latest.x86_64.tar.xz`
  3) As fallback, run elevated and use `-ConvertImage` or a `.wsl`/prepared `.tar` via `-ImagePath`

Example elevated one-liner if needed:
```powershell
Start-Process pwsh -ArgumentList "-NoExit", "-Command", "Set-Location 'C:\sources\github\vllm'; pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -Reset -ConvertImage -ImagePath 'https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-Container-UBI.latest.x86_64.tar.xz'" -Verb RunAs
```

**Container/Build Issues**:
- "Image missing. Use --build." 
  - Run `extras/podman/run.ps1 --build` to build the dev container first
- Patch application failures
  - Check `extras/patches/python-overrides.txt` for syntax errors
  - Verify source files haven't moved upstream (sync issue)
- CUDA version mismatches
  - Pre-CUDA patches (like `cumem.py`) should be in the overlay system
  - Check container build logs for compilation errors

**Podman Context Issues**:
- `podman` cannot connect from Windows
  - Re-run with `-CreatePodmanContext` or manually `podman system connection ls`
- SSH connection refused
  - Check if sshd is running: `wsl -d <name> -- systemctl status sshd`

---

## MCP Server Issues

### paper-search-mcp Authentication Errors

**Problem**: Hosted MCP servers from Smithery fail with OAuth authentication errors:
```
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
- Pre-CUDA patches: Add to `extras/patches/python-overrides.txt` 
- Post-CUDA patches: Can be applied manually in interactive mode or via future automation
- Repository stays clean: patches are applied to overlay directories, not the working tree

---

## Clean-up / reset

```powershell
# Remove the Windows podman context (optional)
podman system connection rm wsl-podman-default -f
  ---

  ## Unresolved issues (2025-10-13)

  Context from latest runs (Admin PS + VS Code terminal):

  - OOBE prompt still appears during `wsl --install` of the Rocky `.wsl` base, but our new flow avoids launching the distro for config and proceeds to export. Admin run shows successful export to prepared tar: `C:\ProgramData\podman-images\Rocky-10-WSL-Base.latest.x86_64.prepared.tar`.
  - In VS Code, the script keeps deleting the prepared tar as “incomplete” and relaunches elevation. This loop prevents `podman machine init` from progressing.
  - `podman machine list` is empty, confirming init never completes.

  Likely root causes:

  1) Overly strict `Test-PreparedArchive` validation. The exported Rocky `.wsl` may not contain our expected `/etc/containers` or `/etc/ssh` markers because we intentionally avoid launching the distro (to bypass OOBE), so the pre-creation step was skipped. The archive is still valid for Podman import, but our validator flags it as incomplete and deletes it.
  2) Loop between “prepared tar incomplete → re-prepare with elevation.” Admin flow completes export, but VS Code flow immediately deletes that tar again.

  Action plan next session:

  - Relax `Test-PreparedArchive` to accept the exported tar if it at least contains a minimal root filesystem (e.g., `/etc/os-release` present), or skip validation when the source was `.wsl` and export succeeded.
  - Once relaxed, rerun helper without `-ClearCache`. Expect: prepared tar reused → `podman machine init` proceeds.
  - After machine is up, continue with toolkit install and CDI generation as usual, then restart and GPU check.

  Manual fallback (if needed):

  ```powershell
  # Use the prepared tar directly
  pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -ImagePath 'C:\ProgramData\podman-images\Rocky-10-WSL-Base.latest.x86_64.prepared.tar'
  ```

  Notes:

  - We intentionally do not launch the temp distro to avoid OOBE; post-init configuration happens inside the Podman machine environment later.
  - If `wsl --export` succeeds, we should trust the tar and not delete it.

  ---

  ## MCP servers: install + usage notes

  This repo occasionally uses MCP servers to enrich research and automation. Quick reference for Windows + VS Code:

  - Install via Smithery CLI (stable VS Code):
    - If Insiders CLI is not in PATH, prefer stable: `code --version` should work.
    - Install medRxiv server:
      ```powershell
      npx -y @smithery/cli@latest install @JackKuo666/medrxiv-mcp-server --client vscode --key <install-key>
      ```
    - List installed:
      ```powershell
      npx -y @smithery/cli@latest list --client vscode
      ```
    - Uninstall:
      ```powershell
      npx -y @smithery/cli@latest uninstall @JackKuo666/medrxiv-mcp-server --client vscode
      ```

  - If using VS Code Insiders, ensure the CLI exists on PATH:
    ```powershell
    & "$env:LOCALAPPDATA\Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd" --version
    ```
    Then use `--client vscode-insiders` in the install command.

  - Explicit tool invocation examples (medRxiv):
    - Keyword search (10 results):
      "Use tool search_medrxiv_key_words with { \"key_words\": \"glioblastoma\", \"num_results\": 10 }"
      or
      "Use tool search_medrxiv_key_words with { \"query\": \"glioblastoma\", \"max_results\": 10 }" (shape may vary)
    - Advanced search:
      "Use tool search_medrxiv_advanced with { \"term\": \"glioblastoma\", \"start_date\": \"2025-01-01\", \"end_date\": \"2025-10-13\", \"num_results\": 20 }"
    - Fetch metadata by DOI:
      "Use tool get_medrxiv_metadata with { \"doi\": \"10.1101/2025.09.25.25336313\" }"

  - Notes:
    - Some MCP clients require each tool to have a description to auto-invoke. If not present, manual invocation (as above) works.
    - Keep install keys/tokens private; do not commit them.
    - If deep-link install (one-click) fails, use the CLI route above.


# Unregister the WSL distro
pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -MachineName podman-machine-default -Reset
```

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
pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -MachineName podman-machine-default -CacheRoot C:\podman-images

# 2. Sync upstream (if needed)  
pwsh extras/tools/fork-sync/sync_with_upstream.ps1

# 3. Build with patches
extras/podman/run.ps1 --build

# 4. Develop
extras/podman/run.ps1 -Interactive
```

**Reset everything**:
```powershell
# Remove WSL distro
pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -MachineName podman-machine-default -Reset

# Remove Windows podman context (if created)
podman system connection rm wsl-podman-default -f
```
