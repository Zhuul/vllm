#!/bin/bash
# check-venv.sh
# Helper script to verify virtual environment setup in the container

echo "=== Python Virtual Environment Check ==="
echo

# Check if we're in a virtual environment
if [[ -n "$VIRTUAL_ENV" ]]; then
    echo "✅ Virtual environment is active: $VIRTUAL_ENV"
else
    echo "❌ No virtual environment detected"
    echo "💡 Activating virtual environment..."
    source /home/vllmuser/venv/bin/activate
    if [[ -n "$VIRTUAL_ENV" ]]; then
        echo "✅ Virtual environment activated: $VIRTUAL_ENV"
    else
        echo "❌ Failed to activate virtual environment"
        exit 1
    fi
fi

echo
echo "=== Python Information ==="
echo "Python executable: $(which python)"
echo "Python version: $(python --version)"
echo "Pip version: $(pip --version)"
echo

echo "=== Key Packages ==="
python -c "
try:
    import torch
    print(f'✅ PyTorch: {torch.__version__} (CUDA: {torch.cuda.is_available()})')
except ImportError:
    print('❌ PyTorch not found')

try:
    import vllm
    print(f'✅ vLLM: {vllm.__version__}')
except ImportError:
    print('⚠️  vLLM not installed (this is expected before running pip install -e .)')

try:
    import transformers
    print(f'✅ Transformers: {transformers.__version__}')
except ImportError:
    print('❌ Transformers not found')
"

echo
echo "=== CUDA Information ==="
if command -v nvidia-smi &> /dev/null; then
    echo "GPU Status:"
    nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits
else
    echo "⚠️  nvidia-smi not available or no GPU detected"
fi

echo
if [[ -n "$VIRTUAL_ENV" ]]; then
    echo "🎉 Virtual environment setup looks good!"
    echo "💡 To manually activate: source /home/vllmuser/venv/bin/activate"
else
    echo "❌ Virtual environment setup needs attention"
fi
