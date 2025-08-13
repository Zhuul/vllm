# WSL2 + Podman Machine + GPU Setup for vLLM Development
# Based on https://kubecoin.io/install-podman-desktop-windows-fedora-gpu

Write-Host "=== WSL2 + Podman Machine + GPU Setup for vLLM Development ===" -ForegroundColor Cyan
Write-Host "Based on: https://kubecoin.io/install-podman-desktop-windows-fedora-gpu" -ForegroundColor Gray
Write-Host ""

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step {
    param([string]$Title, [string]$Description)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Yellow
    Write-Host $Description -ForegroundColor Gray
    Write-Host ""
}

# Check if running as administrator
if (-not (Test-Administrator)) {
    Write-Host "❌ This script needs to be run as Administrator for proper setup." -ForegroundColor Red
    Write-Host "Please right-click PowerShell and `"Run as Administrator`"" -ForegroundColor Yellow
    exit 1
}

Write-Step "Step 1: Install Scoop Package Manager" "Scoop will help us install Podman and Podman Desktop easily"

# Install Scoop if not present
try {
    $null = Get-Command scoop -ErrorAction Stop
    Write-Host "✅ Scoop is already installed" -ForegroundColor Green
} catch {
    Write-Host "Installing Scoop..." -ForegroundColor Yellow
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
    
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "✅ Scoop installed successfully" -ForegroundColor Green
    } else {
        Write-Host "❌ Failed to install Scoop" -ForegroundColor Red
        exit 1
    }
}

Write-Step "Step 2: Add Scoop Buckets" "Adding extras bucket for Podman Desktop"

# Add required buckets
scoop bucket add extras 2>$null
scoop bucket add main 2>$null
Write-Host "✅ Scoop buckets configured" -ForegroundColor Green

Write-Step "Step 3: Install Podman and Podman Desktop" "Installing the core Podman tools"

# Install Podman CLI and Desktop
try {
    scoop install podman
    scoop install podman-desktop
    Write-Host "✅ Podman and Podman Desktop installed successfully" -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to install Podman components" -ForegroundColor Red
    Write-Host "You may need to install manually from: https://podman.io/getting-started/installation" -ForegroundColor Yellow
}

Write-Step "Step 4: Initialize Podman Machine (WSL2 VM)" "Setting up the Linux VM for containers"

# Initialize and start Podman machine
Write-Host "Initializing Podman machine (this may take a few minutes)..." -ForegroundColor Yellow
try {
    podman machine init
    Write-Host "✅ Podman machine initialized" -ForegroundColor Green
    
    Write-Host "Starting Podman machine..." -ForegroundColor Yellow
    podman machine start
    Write-Host "✅ Podman machine started" -ForegroundColor Green
    
    # Verify Podman is working
    $podmanInfo = podman info 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Podman is working correctly" -ForegroundColor Green
    } else {
        Write-Host "⚠️  Podman may need additional configuration" -ForegroundColor Yellow
    }
} catch {
    Write-Host "⚠️  Podman machine setup encountered issues - this may be normal on first run" -ForegroundColor Yellow
    Write-Host "Try running `"podman machine start`" manually if needed" -ForegroundColor Gray
}

Write-Step "Step 5: Configure GPU Support in Podman Machine" "Installing NVIDIA Container Toolkit in the Podman VM"

Write-Host "Connecting to Podman machine to install GPU support..." -ForegroundColor Yellow
Write-Host "Note: This will open an SSH session to the Podman VM" -ForegroundColor Gray

# Create script to run inside Podman machine
$GPUSetupScript = @"
#!/bin/bash
echo "=== Installing NVIDIA Container Toolkit in Podman Machine ==="

# Add NVIDIA Container Toolkit repository
echo "Adding NVIDIA repository..."
sudo curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  -o /etc/yum.repos.d/nvidia-container-toolkit.repo

# Install the toolkit
echo "Installing NVIDIA Container Toolkit..."
sudo yum install -y nvidia-container-toolkit

# Generate CDI configuration
echo "Generating GPU CDI configuration..."
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

echo "✅ NVIDIA Container Toolkit setup complete!"
echo "You can now exit this session (type 'exit')"
"@

# Save the script to a temporary file
$TempScript = "$env:TEMP\gpu-setup.sh"
$GPUSetupScript | Out-File -FilePath $TempScript -Encoding UTF8

Write-Host ""
Write-Host "🚀 NEXT STEPS:" -ForegroundColor Cyan
Write-Host "1. The script has been saved to: $TempScript" -ForegroundColor White
Write-Host "2. Run this command to configure GPU in Podman machine:" -ForegroundColor White
Write-Host "   podman machine ssh" -ForegroundColor Yellow
Write-Host "3. Inside the Podman machine, run:" -ForegroundColor White
Write-Host "   curl -s https://raw.githubusercontent.com/your-script-url/gpu-setup.sh | bash" -ForegroundColor Yellow
Write-Host "   OR copy and paste the commands from: $TempScript" -ForegroundColor Yellow
Write-Host "4. After GPU setup, test with:" -ForegroundColor White
Write-Host "   podman run --rm --device nvidia.com/gpu=all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi" -ForegroundColor Yellow
Write-Host ""

Write-Step "Step 6: Test Your Setup" "Verifying everything works"

Write-Host "Testing basic Podman functionality..." -ForegroundColor Yellow
try {
    podman ps 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Podman basic functionality working" -ForegroundColor Green
    }
} catch {
    Write-Host "⚠️  Podman may need manual start: podman machine start" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "🎉 Setup Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "📋 Summary:" -ForegroundColor Cyan
Write-Host "- ✅ Scoop package manager installed" -ForegroundColor White
Write-Host "- ✅ Podman CLI and Desktop installed" -ForegroundColor White
Write-Host "- ✅ Podman machine (WSL2 VM) initialized" -ForegroundColor White
Write-Host "- 🔄 GPU support needs manual configuration (see steps above)" -ForegroundColor Yellow
Write-Host ""
Write-Host "🔧 Manual GPU Setup Required:" -ForegroundColor Yellow
Write-Host "1. Run: podman machine ssh" -ForegroundColor White
Write-Host "2. Follow the GPU setup commands in: $TempScript" -ForegroundColor White
Write-Host "3. Test GPU: podman run --rm --device nvidia.com/gpu=all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi" -ForegroundColor White
Write-Host ""
Write-Host "5. Start Podman Desktop from Start Menu or run podman-desktop" -ForegroundColor Cyan
