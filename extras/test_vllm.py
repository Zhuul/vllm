#!/usr/bin/env python3
# Simple test script to verify vLLM functionality

import sys
sys.path.insert(0, '/home/vllmuser/venv/lib/python3.9/site-packages')

import torch
print('PyTorch CUDA available:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('GPU:', torch.cuda.get_device_name(0))

import vllm
print('vLLM version:', vllm.__version__)

from vllm import LLM, SamplingParams
print('✅ vLLM core classes imported successfully!')

print('🎉 vLLM is ready for use!')
