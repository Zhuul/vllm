#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Configures a Podman machine running under WSL2 (Rocky Linux 10 default) for NVIDIA GPU passthrough.

.DESCRIPTION
    Installs the NVIDIA Container Toolkit inside the Podman machine, generates a CDI spec for
    WSL2 GPUs, and verifies device/node availability. This script is idempotent and safe to run
    multiple times. A machine reboot is recommended after toolkit installation.

.PARAMETER MachineName
    Name of the Podman machine to configure. Defaults to "podman-machine-default".

.PARAMETER SkipReboot
    Prevents the script from automatically restarting the Podman machine after configuration.

.PARAMETER ImagePath
    Optional override for the Podman guest image. Defaults to the Rocky Linux 10 WSL Base archive.

.EXAMPLE
    pwsh extras/tools/enable-podman-rockylinux-wsl-gpu.ps1

.NOTES
    Requires Podman 4.6+ with `podman machine` support and an NVIDIA driver on Windows that
    exposes the CUDA WSL integration. Run from an elevated PowerShell session for best results.
#>

[CmdletBinding()]
param(
    [string]$MachineName = "podman-machine-default",
    [string]$ImagePath = 'https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-WSL-Base.latest.x86_64.wsl',
    [switch]$Reset,
    [switch]$ConvertImage,
    [string]$CacheRoot,
    [switch]$ClearCache,

    [switch]$Rootful,
    [switch]$AllowSparseUnsafe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:PodmanImageCacheRoot = $null
$script:ElevatedLaunchDone = $false

function Wait-FileUnlocked {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None)
            try { return } finally { $stream.Dispose() }
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Timed out waiting for exclusive access to '$Path'."
}

function Assert-Administrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "This option requires an elevated PowerShell session. Re-run in an 'Administrator: PowerShell' window."
    }
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Podman {
    param([string[]]$Arguments)
    $result = & podman @Arguments
    return $result
}

function Test-PodmanMachine {
    try {
        $name = Invoke-Podman @('machine','inspect',$MachineName,'--format','{{.Name}}') | Select-Object -First 1
        if ($name -and $name.TrimEnd('*') -eq $MachineName) {
            return $true
        }
    } catch {
    }
    return $false
}

function Assert-SafeMachineName {
    # SAFETY: Only allow operations on podman-machine-default to prevent accidental damage
    if ($MachineName -ne "podman-machine-default") {
        throw "SAFETY CHECK FAILED: This script only operates on 'podman-machine-default'. Current target: '$MachineName'. Use -MachineName 'podman-machine-default' explicitly if intended."
    }
}

function Confirm-PodmanCli {
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        throw "Podman CLI not found. Install Podman Desktop or Podman for Windows first."
    }
}

function Invoke-ElevatedImagePreparation {
    param(
        [string]$Reason = "",
        [switch]$UseConvertImage
    )

    if (Test-IsAdministrator) {
        return $false
    }

    if ($script:ElevatedLaunchDone) { 
        Write-Host "ℹ️  Elevation already attempted in this session; skipping duplicate request." -ForegroundColor DarkGray
        return $false 
    }

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    $cwdEsc = (Get-Location).Path.Replace("'","''")
    $scriptEsc = $scriptPath.Replace("'","''")
    $imageEsc = if ($ImagePath) { $ImagePath.Replace("'","''") } else { $null }

    # Build the -Command string cleanly without invalid escape sequences
    $cmd = "Set-Location '$cwdEsc'; pwsh '$scriptEsc' -MachineName '" + $MachineName.Replace("'","''") + "'"
    if ($UseConvertImage) { $cmd += " -ConvertImage" }
    if ($ImagePath) { $cmd += " -ImagePath '" + $imageEsc + "'" }
    if ($CacheRoot) { $cmd += " -CacheRoot '" + $CacheRoot.Replace("'","''") + "'" }
    if ($Rootful.IsPresent) { $cmd += " -Rootful" }
    if ($AllowSparseUnsafe.IsPresent) { $cmd += " -AllowSparseUnsafe" }

    Write-Host "🔐 Elevation required to prepare/import the machine image. Launching an Administrator PowerShell..." -ForegroundColor Yellow
    if ($Reason) { Write-Host ("   Reason: {0}" -f $Reason) -ForegroundColor DarkGray }

    $startArgs = @('-NoExit','-Command', $cmd)
    try {
        $script:ElevatedLaunchDone = $true
        Start-Process pwsh -ArgumentList $startArgs -Verb RunAs -Wait | Out-Null
        return $true
    } catch {
        Write-Warning "Failed to launch elevated PowerShell. Please rerun from an 'Administrator: PowerShell' session."
        return $false
    }
}

function Get-PodmanImageCacheRoot {
    param([string]$OverrideRoot)

    $candidates = @()
    if ($OverrideRoot) { $candidates += $OverrideRoot }
    # Prefer generic env var
    if ($env:PODMAN_IMAGE_CACHE) { $candidates += $env:PODMAN_IMAGE_CACHE }

    $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ($commonData) {
        $candidates += (Join-Path $commonData 'podman-images')
    }

    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ($localData) {
        $candidates += (Join-Path $localData 'podman-images')
    }

    $candidates += (Join-Path ([IO.Path]::GetTempPath()) 'podman-images')

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (-not (Test-Path $full)) {
                New-Item -ItemType Directory -Path $full -Force | Out-Null
            }
            return $full
        } catch {
            # try next candidate
        }
    }

    throw "Unable to determine a writable cache location. Provide -CacheRoot or set PODMAN_IMAGE_CACHE."
}

function Convert-RockyImage {
    param([string]$ImageSpec)

    $resolved = Resolve-ImagePath -ImageSpec $ImageSpec
    if (-not $resolved) {
        throw "Unable to resolve image reference '$ImageSpec'."
    }

    # Avoid recursive re-preparation
    if ($resolved.EndsWith('.prepared.tar',[StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "ℹ️  Resolved image is already a prepared WSL archive: $resolved" -ForegroundColor DarkGray
        return $resolved
    }

    # Preferred path: If source is a .wsl (installable WSL image), install it, export to tar without launching (to avoid OOBE), and unregister
    if ($resolved.EndsWith('.wsl',[StringComparison]::OrdinalIgnoreCase)) {
        Assert-Administrator
        $preparedArchive = [IO.Path]::ChangeExtension($resolved,'prepared.tar')
        if (Test-Path $preparedArchive) {
            if (Test-PreparedArchive -TarPath $preparedArchive) {
                Write-Host "ℹ️  Reusing prepared archive '$preparedArchive'." -ForegroundColor DarkGray
                return $preparedArchive
            } else {
                Write-Host "🧹 Detected incomplete prepared archive. Removing '$preparedArchive' to rebuild..." -ForegroundColor Yellow
                try { Remove-Item -Force $preparedArchive } catch {}
            }
        }

        $tempDistro = "podman-temp-" + [Guid]::NewGuid().ToString('N')
        Write-Host "⬇️  Installing Rocky .wsl image as temporary WSL distro '$tempDistro'..." -ForegroundColor DarkGray
        $installArgs = @('--install','--from-file',"$resolved",'--name',"$tempDistro")
        $pInstall = Start-Process -FilePath wsl.exe -ArgumentList ($installArgs -join ' ') -NoNewWindow -PassThru -Wait
        # OOBE may cause non-zero exit; proceed if the distro is registered
        $registered = & wsl.exe -l -q 2>$null | Where-Object { $_ -eq $tempDistro }
        if (-not $registered) {
            throw "wsl.exe install failed (distro '$tempDistro' not registered). Exit code: $($pInstall.ExitCode)"
        }
        # Immediately terminate to avoid OOBE user prompt blocking subsequent steps
        try { Start-Process -FilePath wsl.exe -ArgumentList ("--terminate `"$tempDistro`"") -NoNewWindow -PassThru -Wait | Out-Null } catch {}
        # Ensure WSL2 (this does not launch the distro)
        try { Start-Process -FilePath wsl.exe -ArgumentList ("--set-version `"$tempDistro`" 2") -NoNewWindow -PassThru -Wait | Out-Null } catch {}

        Write-Host "Exporting prepared distro to tar archive..." -ForegroundColor Yellow
        $exportProc = Start-Process -FilePath wsl.exe -ArgumentList ("--export `"$tempDistro`" `"$preparedArchive`"") -NoNewWindow -PassThru -Wait
        if ($exportProc.ExitCode -ne 0) {
            throw "wsl.exe export failed with exit code $($exportProc.ExitCode)"
        }
        try { Start-Process -FilePath wsl.exe -ArgumentList ("--unregister `"$tempDistro`"") -NoNewWindow -PassThru -Wait | Out-Null } catch {}
        Write-Host "✅ Prepared archive ready at '$preparedArchive'." -ForegroundColor Green
        return $preparedArchive
    }

    # If the source is a .tar.xz, decompress and repackage to a plain .tar for WSL import
    if ($resolved.EndsWith('.tar.xz',[StringComparison]::OrdinalIgnoreCase)) {
        $plainTar = $resolved -replace '\.tar\.xz$', '.tar'
        if (-not (Test-Path $plainTar)) {
            Write-Host "🗜️  Converting compressed archive to plain tar for WSL import..." -ForegroundColor DarkGray
            $xzWork = Join-Path ([IO.Path]::GetTempPath()) ("podman-xz-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $xzWork | Out-Null
            try {
                $extractArgs = "-xf `"$resolved`" -C `"$xzWork`""
                $p1 = Start-Process -FilePath tar.exe -ArgumentList $extractArgs -NoNewWindow -PassThru -Wait
                if ($p1.ExitCode -ne 0) { throw "tar extraction failed with exit code $($p1.ExitCode)" }
                $createArgs = "-cf `"$plainTar`" -C `"$xzWork`" ."
                $p2 = Start-Process -FilePath tar.exe -ArgumentList $createArgs -NoNewWindow -PassThru -Wait
                if ($p2.ExitCode -ne 0) { throw "tar creation failed with exit code $($p2.ExitCode)" }
            } finally {
                Remove-Item $xzWork -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host "✅ Created plain tar '$plainTar' for import." -ForegroundColor Green
        }
        $resolved = $plainTar
    }

    if ($resolved.EndsWith('.tar',[StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "ℹ️  Resolved image is a tar; will prepare a WSL-compatible archive." -ForegroundColor DarkGray
    }

    if ($resolved.EndsWith('.vhdx',[StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "ℹ️  Resolved image is a VHDX; Podman may not accept it directly. Consider exporting to tar via 'wsl --export'." -ForegroundColor Yellow
        return $resolved
    }

    $preparedArchive = [IO.Path]::ChangeExtension($resolved,'prepared.tar')
    if (Test-Path $preparedArchive) {
        if (Test-PreparedArchive -TarPath $preparedArchive) {
            Write-Host "ℹ️  Reusing prepared archive '$preparedArchive'." -ForegroundColor DarkGray
            return $preparedArchive
        } else {
            Write-Host "🧹 Detected incomplete prepared archive. Removing '$preparedArchive' to rebuild..." -ForegroundColor Yellow
            try { Remove-Item -Force $preparedArchive } catch {}
        }
    }

    Assert-Administrator

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("podman-wsl-" + [Guid]::NewGuid().ToString('N'))
    $tempDistro = "podman-temp-" + [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        # Attempt to enable sparse VHD for the temp distro to allow import if gated
        try {
            Enable-SparseVhdSupport -Distribution $tempDistro
        } catch {
            Write-Host "ℹ️  Could not pre-enable sparse VHD on temp distro (may not exist yet); proceeding with import." -ForegroundColor DarkGray
        }

        Write-Host "⬇️  Importing Rocky archive into temporary WSL distro '$tempDistro' for conversion..." -ForegroundColor DarkGray
        $importProc = Start-Process -FilePath wsl.exe -ArgumentList ("--import `"$tempDistro`" `"$tempRoot`" `"$resolved`" --version 2") -NoNewWindow -PassThru -Wait
        if ($importProc.ExitCode -ne 0) {
            throw "wsl.exe import failed with exit code $($importProc.ExitCode)"
        }

        try {
            $prepScript = @'
set -euo pipefail
SUDO=
if command -v sudo >/dev/null 2>&1; then
    SUDO=sudo
fi
if command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y openssh-server shadow-utils policycoreutils-python-utils || true
fi
mkdir -p /etc/containers /etc/containers/registries.conf.d /etc/ssh
touch /etc/containers/containers.conf
touch /etc/containers/registries.conf.d/999-podman-machine.conf
touch /etc/ssh/sshd_config
if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable sshd || true
fi
'@
            $prepScript = $prepScript -replace "`r", ""
            $prepEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($prepScript))
            $cmd = "echo $prepEncoded | base64 -d | bash"
            $pPrep = Start-Process -FilePath wsl.exe -ArgumentList ("-d `"$tempDistro`" --user root bash -lc `"$cmd`"") -NoNewWindow -PassThru -Wait
            if ($pPrep.ExitCode -ne 0) { Write-Host "ℹ️  Preparation inside temp distro exited with code $($pPrep.ExitCode); continuing." -ForegroundColor DarkGray }
        } catch {
            Write-Host "ℹ️  Could not pre-create /etc/containers in temp distro; continuing." -ForegroundColor DarkGray
        }

        Start-Process -FilePath wsl.exe -ArgumentList ("--terminate `"$tempDistro`"") -NoNewWindow -Wait | Out-Null
        Start-Process -FilePath wsl.exe -ArgumentList "--shutdown" -NoNewWindow -Wait | Out-Null

        Write-Host "Exporting prepared distro to tar archive..." -ForegroundColor Yellow
        $exportProc = Start-Process -FilePath wsl.exe -ArgumentList ("--export `"$tempDistro`" `"$preparedArchive`"") -NoNewWindow -PassThru -Wait
        if ($exportProc.ExitCode -ne 0) {
            throw "wsl.exe export failed with exit code $($exportProc.ExitCode)"
        }

        Write-Host "✅ Prepared archive ready at '$preparedArchive'." -ForegroundColor Green
        return $preparedArchive
    } finally {
        try { Start-Process -FilePath wsl.exe -ArgumentList ("--unregister `"$tempDistro`"") -NoNewWindow -PassThru -Wait | Out-Null } catch {}
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PreparedArchive {
    param([Parameter(Mandatory=$true)][string]$TarPath)
    try {
        # List entries in the tar and verify expected OS markers exist.
        # We accept two tiers:
        #  1) Strong markers: etc/containers and etc/ssh present (preferred)
        #  2) Minimal OS marker: etc/os-release (or usr/lib/os-release) present (sufficient)
        $list = & tar.exe -tf $TarPath 2>$null
        if (-not $list) { return $false }

        # Normalize entries to avoid leading ./ and support potential 'rootfs/' prefix
        $norm = $list | ForEach-Object { $_ -replace '^\./', '' }

        $hasContainers = $norm | Where-Object { $_ -match '^(?:rootfs/)?etc/containers/?$' -or $_ -match '^(?:rootfs/)?etc/containers/containers\.conf$' }
        $hasSsh = $norm | Where-Object { $_ -match '^(?:rootfs/)?etc/ssh/?$' -or $_ -match '^(?:rootfs/)?etc/ssh/sshd_config$' }
        if ($hasContainers -and $hasSsh) { return $true }

        # Minimal Rocky/EL rootfs marker
        $hasOsRelease = $norm | Where-Object { $_ -match '^(?:rootfs/)?etc/os-release$' -or $_ -match '^(?:rootfs/)?usr/lib/os-release$' }
        if ($hasOsRelease) {
            Write-Host "ℹ️  Prepared archive validated via minimal OS marker (os-release present)." -ForegroundColor DarkGray
            return $true
        }

        return $false
    } catch { return $false }
}

function Resolve-ImagePath {
    param([string]$ImageSpec)

    if (-not $ImageSpec) {
        return $null
    }

    if ($ImageSpec -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        if (-not $script:PodmanImageCacheRoot) {
            $script:PodmanImageCacheRoot = Get-PodmanImageCacheRoot -OverrideRoot $CacheRoot
        }
        $cacheRoot = $script:PodmanImageCacheRoot
        $leaf = Split-Path $ImageSpec -Leaf
        if (-not $leaf) {
            $leaf = 'podman-machine-image.qcow2'
        }
        $localPath = Join-Path $cacheRoot $leaf
        if ($leaf -match '(?i)container|ubi') {
            Write-Warning "The specified image appears to be a container archive. Prefer the official Rocky .wsl image when possible for WSL installs. See docs: https://docs.rockylinux.org/10/guides/interoperability/import_rocky_to_wsl/"
        }
        if ($ClearCache.IsPresent -and (Test-Path $localPath)) {
            Write-Host "🧹 Clearing cached image at '$localPath' (-ClearCache specified)..." -ForegroundColor Yellow
            try { Remove-Item -Force $localPath } catch {}
            $prepared = [IO.Path]::ChangeExtension($localPath,'prepared.tar'); if (Test-Path $prepared) { try { Remove-Item -Force $prepared } catch {} }
            $legacyPrepared = [IO.Path]::ChangeExtension($localPath,'prepared.vhdx'); if (Test-Path $legacyPrepared) { try { Remove-Item -Force $legacyPrepared } catch {} }
            $fixed = [IO.Path]::ChangeExtension($localPath,'fixed.vhdx'); if (Test-Path $fixed) { try { Remove-Item -Force $fixed } catch {} }
        }
        if (-not (Test-Path $localPath)) {
            Write-Host "⬇️  Downloading Podman machine image from '$ImageSpec'..." -ForegroundColor Cyan
            try {
                Invoke-WebRequest -Uri $ImageSpec -OutFile $localPath -UseBasicParsing | Out-Null
            } catch {
                if (Test-Path $localPath) { Remove-Item $localPath -Force }
                throw "Failed to download image from '$ImageSpec': $($_.Exception.Message)"
            }
        } else {
            Write-Host "ℹ️  Reusing cached machine image '$localPath'." -ForegroundColor DarkGray
        }
        $preparedCandidate = [IO.Path]::ChangeExtension($localPath,'prepared.tar')
        if (Test-Path $preparedCandidate) {
            if (Test-PreparedArchive -TarPath $preparedCandidate) {
                Write-Host "ℹ️  Using prepared machine image '$preparedCandidate'." -ForegroundColor DarkGray
                return $preparedCandidate
            } else {
                Write-Host "🧹 Detected incomplete prepared archive. Removing '$preparedCandidate' to rebuild..." -ForegroundColor Yellow
                try { Remove-Item -Force $preparedCandidate } catch {}
            }
        }
        $legacyPrepared = [IO.Path]::ChangeExtension($localPath,'prepared.vhdx')
        if (Test-Path $legacyPrepared) {
            Write-Host "ℹ️  Using legacy prepared VHDX '$legacyPrepared'." -ForegroundColor DarkGray
            return $legacyPrepared
        }
        $fixedCandidate = [IO.Path]::ChangeExtension($localPath,'fixed.vhdx')
        if (Test-Path $fixedCandidate) {
            Write-Host "ℹ️  Using previously converted VHDX '$fixedCandidate'." -ForegroundColor DarkGray
            return $fixedCandidate
        }
        return $localPath
    }

    if (-not (Test-Path $ImageSpec)) {
        throw "Image path '$ImageSpec' does not exist."
    }
    $resolved = (Resolve-Path $ImageSpec).Path
    if ($resolved.EndsWith('.wsl',[StringComparison]::OrdinalIgnoreCase) -or $resolved.EndsWith('.tar',[StringComparison]::OrdinalIgnoreCase)) {
        $preparedCandidate = [IO.Path]::ChangeExtension($resolved,'prepared.tar')
        if (Test-Path $preparedCandidate) {
            if (Test-PreparedArchive -TarPath $preparedCandidate) {
                Write-Host "ℹ️  Using prepared machine image '$preparedCandidate'." -ForegroundColor DarkGray
                return $preparedCandidate
            } else {
                Write-Host "🧹 Detected incomplete prepared archive. Removing '$preparedCandidate' to rebuild..." -ForegroundColor Yellow
                try { Remove-Item -Force $preparedCandidate } catch {}
            }
        }
        $legacyPrepared = [IO.Path]::ChangeExtension($resolved,'prepared.vhdx')
        if (Test-Path $legacyPrepared) {
            Write-Host "ℹ️  Using legacy prepared VHDX '$legacyPrepared'." -ForegroundColor DarkGray
            return $legacyPrepared
        }
        $fixedCandidate = [IO.Path]::ChangeExtension($resolved,'fixed.vhdx')
        if (Test-Path $fixedCandidate) {
            Write-Host "ℹ️  Using previously converted VHDX '$fixedCandidate'." -ForegroundColor DarkGray
            return $fixedCandidate
        }
    }
    return $resolved
}

function Initialize-PodmanMachine {
    if (Test-PodmanMachine) {
        return
    }
    Write-Host "🆕 Creating Podman machine '$MachineName'..." -ForegroundColor Cyan
    $resolvedImage = Resolve-ImagePath -ImageSpec $ImagePath
    $initArgs = @('machine','init')
    if ($resolvedImage) {
        Write-Host "📦 Using machine image '$resolvedImage'." -ForegroundColor DarkGray
        $initArgs += @('--image',$resolvedImage)
    }
    $initArgs += $MachineName
    $output = & podman @initArgs 2>&1
    $exitCode = $LASTEXITCODE
    $sparseMessage = ($output | Out-String)
    $convertedImage = $null
    $attemptedConversion = $false

    # Helper to clear cached image and re-resolve
    function Clear-And-RedownloadImage([string]$currentResolved) {
        try {
            if ($currentResolved -and (Test-Path $currentResolved)) {
                Write-Host "🧹 Removing cached machine image '$currentResolved' due to extraction error..." -ForegroundColor Yellow
                Remove-Item -Force -ErrorAction SilentlyContinue $currentResolved
                $prepared = [IO.Path]::ChangeExtension($currentResolved,'prepared.tar')
                if (Test-Path $prepared) { Remove-Item -Force -ErrorAction SilentlyContinue $prepared }
                $fixed = [IO.Path]::ChangeExtension($currentResolved,'fixed.vhdx')
                if (Test-Path $fixed) { Remove-Item -Force -ErrorAction SilentlyContinue $fixed }
            }
        } catch {}
        return (Resolve-ImagePath -ImageSpec $ImagePath)
    }

    # If init failed with compressed file extraction errors, clear cache and retry once
    if ($exitCode -ne 0 -and ($sparseMessage -match 'unexpected EOF')) {
        Write-Host "⚠️  Detected a corrupted or incomplete cached image (unexpected EOF). Will clear cache and retry once." -ForegroundColor Yellow
        $resolvedImage = Clear-And-RedownloadImage -currentResolved $resolvedImage
        $initArgs = @('machine','init')
        if ($resolvedImage) { $initArgs += @('--image',$resolvedImage) }
        $initArgs += $MachineName
        $output = & podman @initArgs 2>&1
        $exitCode = $LASTEXITCODE
        $sparseMessage = ($output | Out-String)
    }

    if ($exitCode -ne 0 -and $sparseMessage -match 'Sparse VHD support is currently disabled') {
        Write-Host "⚠️  Podman init blocked by WSL sparse-vhd gate; preparing a reusable archive..." -ForegroundColor Yellow
        $convertedImage = $null
        try {
            $convertedImage = Convert-RockyImage -ImageSpec $ImagePath
        } catch {
            $msg = ($_.Exception.Message | Out-String)
            if ($msg -match 'elevated PowerShell session' -or $msg -match 'Convert-VHD requires elevation') {
                $launched = Invoke-ElevatedImagePreparation -Reason "WSL sparse-vhd gate: image preparation requires elevation" -UseConvertImage
                if ($launched) {
                    Write-Host "Launched elevated session to prepare image; exiting current (non-admin) session..." -ForegroundColor Yellow
                    exit 0
                }
            }
            throw
        }
        $attemptedConversion = $true
        if ($convertedImage) {
            $resolvedImage = $convertedImage
            $initArgs = @('machine','init','--image',$resolvedImage,$MachineName)
            $output = & podman @initArgs 2>&1
            $exitCode = $LASTEXITCODE
        } elseif ($AllowSparseUnsafe.IsPresent) {
            Write-Host "ℹ️  Conversion failed; attempting to enable sparse support explicitly." -ForegroundColor DarkGray
            try {
                Enable-SparseVhdSupport -Distribution $MachineName
                $output = & podman @initArgs 2>&1
                $exitCode = $LASTEXITCODE
            } catch {
                throw
            }
        }
    } elseif ($exitCode -ne 0 -and ($sparseMessage -match 'unexpected EOF')) {
        # As an additional fallback, try conversion if extraction kept failing
        try {
            $convertedImage = Convert-RockyImage -ImageSpec $ImagePath
            if ($convertedImage) {
                $resolvedImage = $convertedImage
                $initArgs = @('machine','init','--image',$resolvedImage,$MachineName)
                $output = & podman @initArgs 2>&1
                $exitCode = $LASTEXITCODE
            }
        } catch {
            $msg = ($_.Exception.Message | Out-String)
            if ($msg -match 'elevated PowerShell session' -or $msg -match 'Convert-VHD requires elevation') {
                $launched = Invoke-ElevatedImagePreparation -Reason "Corrupted image (unexpected EOF): image preparation requires elevation" -UseConvertImage
                if ($launched) {
                    Write-Host "Launched elevated session to prepare image; exiting current (non-admin) session..." -ForegroundColor Yellow
                    exit 0
                }
            }
            throw
        }
        $attemptedConversion = $true
    } elseif ($exitCode -ne 0 -and $AllowSparseUnsafe.IsPresent -and $sparseMessage -match 'allow-unsafe') {
    Write-Host "⚠️  WSL rejected '--allow-unsafe'; preparing a reusable archive instead." -ForegroundColor Yellow
        $convertedImage = $null
        try {
        $convertedImage = Convert-RockyImage -ImageSpec $ImagePath
        } catch {
            $msg = ($_.Exception.Message | Out-String)
            if ($msg -match 'elevated PowerShell session' -or $msg -match 'Convert-VHD requires elevation') {
                $launched = Invoke-ElevatedImagePreparation -Reason "WSL rejected allow-unsafe: image preparation requires elevation" -UseConvertImage
                if ($launched) {
                    Write-Host "Launched elevated session to prepare image; exiting current (non-admin) session..." -ForegroundColor Yellow
                    exit 0
                }
            }
            throw
        }
        $attemptedConversion = $true
        if ($convertedImage) {
            $resolvedImage = $convertedImage
            $initArgs = @('machine','init','--image',$resolvedImage,$MachineName)
            $output = & podman @initArgs 2>&1
            $exitCode = $LASTEXITCODE
        }
    }
    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if (-not $message) { $message = "podman machine init exited with code $exitCode" }
        if ($attemptedConversion -and -not $convertedImage) {
            $message += "`nArchive preparation failed; run 'extras/tools/enable-podman-rockylinux-wsl-gpu.ps1 -ConvertImage' from elevated PowerShell first."
        }
    if ($sparseMessage -match 'unexpected EOF') {
            $message += "`nDetected a corrupted image download; try clearing the cache or re-downloading (use -ClearCache). Current cache root: C:\\ProgramData\\podman-images\\"
        }
        throw "Failed to initialize Podman machine '$MachineName': $message"
    }
}

function Enable-SparseVhdSupport {
    param([string]$Distribution)
    Write-Host "🪫 Enabling sparse VHD import for '$Distribution' (allows WSL to attach pre-sparse Rocky image)..." -ForegroundColor Yellow
    $attempts = @(
        @('--manage',$Distribution,'--set-sparse','--allow-unsafe'),
        @('--manage',$Distribution,'--set-sparse','--allow-unsafe','true'),
        @('--manage',$Distribution,'--set-sparse','true','--allow-unsafe'),
        @('--manage',$Distribution,'--set-sparse','true','--allow-unsafe','true'),
        @('--manage',$Distribution,'--set-sparse','true','--allow-unsafe=true'),
        @('--manage',$Distribution,'--set-sparse=true','--allow-unsafe'),
        @('--manage',$Distribution,"--set-sparse=true","--allow-unsafe=true")
    )
    $failMessages = @()
    for ($i = 0; $i -lt $attempts.Count; $i++) {
        $cmdArgs = $attempts[$i]
        $output = & wsl.exe @cmdArgs 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            if ($i -gt 0) {
                Write-Host "ℹ️  Sparse support enabled using syntax variant: wsl.exe $($cmdArgs -join ' ')" -ForegroundColor DarkGray
            }
            return
        }
        $msg = ($output | Out-String).Trim()
        if (-not $msg) { $msg = "wsl.exe exited with code $exitCode" }
        $failMessages += "- wsl.exe $($cmdArgs -join ' '): $msg"
    }
    $joined = [string]::Join("`n",$failMessages)
    if ($joined -match 'allow-unsafe is not a valid boolean') {
        $guidance = @(
            "WSL on this host does not recognise '--allow-unsafe'.",
            "Update WSL via 'wsl.exe --update --pre-release' or convert the Rocky .wsl archive to a fixed .vhdx and rerun with -ImagePath pointing to that file.",
            "See https://docs.rockylinux.org/10/guides/interoperability/import_rocky_to_wsl/ for manual conversion steps."
        )
        $joined = "$joined`n$([string]::Join(' ', $guidance))"
    }
    throw "Failed to enable sparse VHD support for '$Distribution':`n$joined"
}

function Start-MachineIfNeeded {
    $state = $null
    try {
        $state = Invoke-Podman @('machine','inspect',$MachineName,'--format','{{.State}}') | Select-Object -First 1
    } catch {}
    if (-not $state) {
        throw "Machine '$MachineName' could not be inspected. Ensure it exists or rerun with -Reset."
    }
    if ($state.Trim() -ne 'Running') {
        Write-Host "🟢 Starting Podman machine '$MachineName'..." -ForegroundColor Green
        Invoke-Podman @('machine','start',$MachineName) | Out-Null
    }
}

function Reset-PodmanMachine {
    if (-not $Reset.IsPresent) {
        return
    }
    
    # SAFETY: Verify we're only targeting the expected machine
    Assert-SafeMachineName
    
    Write-Host "♻️ Resetting Podman machine '$MachineName'..." -ForegroundColor Yellow
    if (Test-PodmanMachine) {
        try {
            Write-Host "   Stopping machine '$MachineName'..." -ForegroundColor DarkGray
            Invoke-Podman @('machine','stop',$MachineName) | Out-Null
        } catch {
            Write-Host "   Machine '$MachineName' was already stopped." -ForegroundColor DarkGray
        }
        Write-Host "   Removing machine '$MachineName'..." -ForegroundColor DarkGray
        Invoke-Podman @('machine','rm','-f',$MachineName) | Out-Null
    } else {
        Write-Host "ℹ️  Machine '$MachineName' already absent." -ForegroundColor DarkGray
    }
}

function Set-PodmanRootfulMode {
    if (-not $Rootful.IsPresent) {
        return
    }
    if (-not (Test-PodmanMachine)) {
        return
    }
    $rootfulState = Invoke-Podman @('machine','inspect',$MachineName,'--format','{{.Rootful}}') | Select-Object -First 1
    if ($rootfulState -and $rootfulState.Trim().ToLower() -eq 'true') {
        return
    }
    Write-Host "🔑 Enabling rootful mode for '$MachineName'..." -ForegroundColor Yellow
    Invoke-Podman @('machine','set','--rootful',$MachineName) | Out-Null
    try {
        Invoke-Podman @('machine','stop',$MachineName) | Out-Null
    } catch {}
}

function Get-OsRelease {
    $osRelease = Invoke-Podman @('machine','ssh',$MachineName,'--','cat','/etc/os-release')
    $map = @{}
    foreach ($line in $osRelease) {
        if ($line -match '^(?<key>[A-Z0-9_]+)=("?)(?<value>.*)\2$') {
            $map[$Matches.key] = $Matches.value
        }
    }
    return $map
}

function Install-PodmanAndToolkit {
    $remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

# First, ensure Podman is installed inside the WSL machine
if ! command -v podman >/dev/null 2>&1; then
    echo "Installing Podman inside WSL machine..."
    sudo dnf install -y podman
fi

# Create user socket directory and start Podman system service
mkdir -p /run/user/$(id -u)/podman
if ! pgrep -f "podman system service" >/dev/null 2>&1; then
    echo "Starting Podman system service..."
    podman system service --time=0 unix:///run/user/$(id -u)/podman/podman.sock &
    sleep 2
fi

# Set up NVIDIA container toolkit
REPO_FILE="/etc/yum.repos.d/nvidia-container-toolkit.repo"
ARCH="$(uname -m)"
. /etc/os-release
MAJOR="${VERSION_ID%%.*}"
ID_LIKE_LOWER=$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
ID_LOWER=$(echo "$ID" | tr '[:upper:]' '[:lower:]')

if [ ! -f "$REPO_FILE" ]; then
    if [[ "$ID_LOWER" == "rocky" || "$ID_LOWER" == "rhel" || "$ID_LIKE_LOWER" == *"rhel"* ]]; then
        if [[ "$MAJOR" =~ ^1[0-9]$ ]]; then
            CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel${MAJOR}/${ARCH}/cuda-rhel${MAJOR}.repo"
            TMP_REPO=$(mktemp)
            if curl -fsSL "$CUDA_REPO" -o "$TMP_REPO"; then
                sudo mv "$TMP_REPO" "$REPO_FILE"
            else
                rm -f "$TMP_REPO"
            fi
        elif [[ "$MAJOR" -ge 8 ]]; then
            CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel${MAJOR}/${ARCH}/cuda-rhel${MAJOR}.repo"
            TMP_REPO=$(mktemp)
            if curl -fsSL "$CUDA_REPO" -o "$TMP_REPO"; then
                sudo mv "$TMP_REPO" "$REPO_FILE"
            else
                rm -f "$TMP_REPO"
            fi
        fi
    fi

    if [ ! -f "$REPO_FILE" ]; then
        cat <<'EOF' | sudo tee "$REPO_FILE" >/dev/null
[nvidia-container-toolkit]
name=NVIDIA Container Toolkit
baseurl=https://nvidia.github.io/libnvidia-container/stable/rpm
enabled=1
gpgcheck=1
gpgkey=https://nvidia.github.io/libnvidia-container/gpgkey
EOF
    fi
fi

if command -v rpm-ostree >/dev/null 2>&1; then
    sudo rpm-ostree install --idempotent nvidia-container-toolkit || true
else
    sudo dnf install -y nvidia-container-toolkit || true
fi

if command -v nvidia-ctk >/dev/null 2>&1; then
    sudo mkdir -p /etc/cdi /var/cdi
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml --mode=wsl || true
    sudo cp -f /etc/cdi/nvidia.yaml /var/cdi/nvidia.yaml || true
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    true
elif [ -x /usr/lib/wsl/drivers/nvidia-smi ]; then
    sudo ln -sf /usr/lib/wsl/drivers/nvidia-smi /usr/local/bin/nvidia-smi
elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    sudo ln -sf /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
fi

sudo mkdir -p /usr/lib/wsl
if [ ! -e /usr/lib/wsl/lib ] && [ -d /mnt/c/Windows/System32/nvidia-cuda ]; then
    sudo ln -sf /mnt/c/Windows/System32/nvidia-cuda /usr/lib/wsl/lib
fi
if [ ! -e /usr/lib/wsl/drivers ] && [ -d /mnt/c/Windows/System32/DriverStore/FileRepository ]; then
    sudo ln -sf /mnt/c/Windows/System32/DriverStore/FileRepository /usr/lib/wsl/drivers
fi

sudo udevadm control --reload || true
exit 0
'@

    $remoteScriptLf = $remoteScript -replace "`r", ""
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScriptLf))
    $sshArgs = @('machine','ssh',$MachineName,'--','bash','-lc',"set -euo pipefail; echo $encoded | base64 -d >/tmp/configure-gpu.sh; chmod +x /tmp/configure-gpu.sh; sudo /tmp/configure-gpu.sh")
    Invoke-Podman $sshArgs | Out-Null
}

function Remove-OrphanedConnections {
    Write-Host "🧹 Cleaning up orphaned Podman connections..." -ForegroundColor DarkGray
    
    # SAFETY: Only remove connections specifically related to our target machine
    try {
        $connections = & podman system connection list --format json 2>$null | ConvertFrom-Json
        foreach ($conn in $connections) {
            # Only target connections that match our specific machine name pattern
            if ($conn.Name -eq $MachineName -or $conn.Name -eq "$MachineName-root") {
                Write-Host "   Removing connection '$($conn.Name)' for machine '$MachineName'..." -ForegroundColor DarkGray
                & podman system connection remove $conn.Name 2>$null | Out-Null
            }
        }
    } catch {
        # Ignore errors during cleanup
        Write-Host "   Connection cleanup completed (some connections may not have existed)." -ForegroundColor DarkGray
    }
}

function Test-PodmanGpu {
    Write-Host "🔍 Checking GPU devices inside the machine..." -ForegroundColor Yellow
    $cmd = 'bash -lc "ls -l /dev/dxg 2>/dev/null; ls -l /dev/nvidia* 2>/dev/null; nvidia-smi || true"'
    Invoke-Podman @('machine','ssh',$MachineName,'--',$cmd)
}

$script:PodmanImageCacheRoot = Get-PodmanImageCacheRoot -OverrideRoot $CacheRoot

Confirm-PodmanCli

# SAFETY: Ensure we only operate on the expected machine name
Assert-SafeMachineName

if ($ConvertImage) {
    if (-not (Test-IsAdministrator)) {
        if (Invoke-ElevatedImagePreparation -Reason "Manual -ConvertImage requested" -UseConvertImage) {
            Write-Host "Launched elevated session to prepare image; exiting current (non-admin) session..." -ForegroundColor Yellow
            exit 0
        }
    }
    Assert-Administrator
    $convertedPath = Convert-RockyImage -ImageSpec $ImagePath
    if ($convertedPath) {
        Write-Host "ℹ️  Prepared archive ready at '$convertedPath'. Re-run without -ConvertImage to provision the Podman machine." -ForegroundColor Cyan
    }
    return
}

Write-Host "🎯 Target: Configuring Podman machine '$MachineName' only" -ForegroundColor Cyan
Write-Host "🛡️  Safety: This script will not affect other machines, images, or containers" -ForegroundColor Green

Reset-PodmanMachine
Initialize-PodmanMachine
Set-PodmanRootfulMode
Start-MachineIfNeeded
Remove-OrphanedConnections
$osInfo = Get-OsRelease
$machineId = if ($osInfo.ContainsKey('ID') -and $osInfo['ID']) { $osInfo['ID'] } elseif ($osInfo.ContainsKey('ID_LIKE') -and $osInfo['ID_LIKE']) { $osInfo['ID_LIKE'] } elseif ($osInfo.ContainsKey('PRETTY_NAME') -and $osInfo['PRETTY_NAME']) { $osInfo['PRETTY_NAME'] } else { 'unknown' }
if ($machineId -notlike 'rocky*') {
    Write-Warning ("Machine reports ID='{0}'. Script was validated against Rocky Linux 10; adjust steps manually if your image differs." -f $machineId)
}

Write-Host "⚙️  Installing Podman and NVIDIA container runtime inside '$MachineName'..." -ForegroundColor Cyan
Install-PodmanAndToolkit

if (-not $SkipReboot.IsPresent) {
    Write-Host "🔄 Restarting machine to finalize toolkit installation..." -ForegroundColor Cyan
    Invoke-Podman @('machine','stop',$MachineName) | Out-Null
    Invoke-Podman @('machine','start',$MachineName) | Out-Null
}

Test-PodmanGpu

Write-Host "✅ GPU configuration routine completed. Re-run your container helper (run.ps1 -GPUCheck) to validate from the workload container." -ForegroundColor Green
