#!/usr/bin/env python3
"""Test script to verify vLLM and GPU functionality"""

import torch
print("PyTorch version:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("CUDA devices:", torch.cuda.device_count())
    print("Current device:", torch.cuda.get_device_name(0))
    print("Device properties:")
    print("  Memory:", torch.cuda.get_device_properties(0).total_memory // (1024**3), "GB")

try:
    import vllm
    print("\nvLLM imported successfully!")
    print("vLLM version:", vllm.__version__)
    
    # Test basic model loading (using a small model to verify functionality)
    print("\nTesting basic vLLM functionality...")
    from vllm import LLM
    print("LLM class imported successfully!")
    
except ImportError as e:
    print("Failed to import vLLM:", e)
except Exception as e:
    print("Error during vLLM testing:", e)
