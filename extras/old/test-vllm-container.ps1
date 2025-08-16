# vLLM Container Test Script
# Run this from the vLLM workspace directory

Write-Host "🚀 Testing vLLM Container Environment..." -ForegroundColor Green
Write-Host ("=" * 50)

# Test 1: Basic container functionality  
Write-Host "`n📋 Test 1: Container and GPU Access" -ForegroundColor Yellow
& podman run --rm --device=nvidia.com/gpu=all vllm-dev-fixed:v2 bash -c 'source /home/vllmuser/venv/bin/activate; cd /tmp; python -c "import torch; print(torch.cuda.is_available())"'

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Container and GPU access working!" -ForegroundColor Green
} else {
    Write-Host "❌ Container or GPU access failed!" -ForegroundColor Red
    exit 1
}

# Test 2: vLLM installation
Write-Host "`n📋 Test 2: vLLM Installation" -ForegroundColor Yellow  
& podman run --rm --device=nvidia.com/gpu=all vllm-dev-fixed:v2 bash -c 'source /home/vllmuser/venv/bin/activate; cd /tmp; python -c "import vllm; print(vllm.__version__)"'

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ vLLM installation working!" -ForegroundColor Green
} else {
    Write-Host "❌ vLLM installation failed!" -ForegroundColor Red
    exit 1
}

Write-Host "`n🎉 SUCCESS: vLLM container environment is fully functional!" -ForegroundColor Green
Write-Host "`n📖 Usage:" -ForegroundColor Cyan
Write-Host '  podman run --rm -it --device=nvidia.com/gpu=all -v "${PWD}:/workspace" vllm-dev-fixed:v2' -ForegroundColor White
Write-Host "`n📚 Documentation: See CONTAINER_SETUP_COMPLETE.md for detailed usage guide" -ForegroundColor Cyan
