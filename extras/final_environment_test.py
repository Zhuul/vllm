#!/usr/bin/env python3
"""
vLLM Development Environment - Final Verification Test
This script verifies that the complete vLLM development environment is working correctly.
"""

import sys
import os

def main():
    print("=" * 60)
    print("🚀 vLLM Development Environment - Final Test")
    print("=" * 60)
    print(f"Python: {sys.version}")
    print(f"Working directory: {os.getcwd()}")
    
    # Test 1: GPU and PyTorch
    print("\n1️⃣ Testing GPU and PyTorch...")
    try:
        import torch
        print(f"   ✅ PyTorch: {torch.__version__}")
        print(f"   ✅ CUDA available: {torch.cuda.is_available()}")
        if torch.cuda.is_available():
            print(f"   ✅ GPU: {torch.cuda.get_device_name(0)}")
            print(f"   ✅ Memory: {torch.cuda.get_device_properties(0).total_memory // (1024**3)}GB")
            gpu_ok = True
        else:
            print("   ❌ No GPU detected")
            gpu_ok = False
    except Exception as e:
        print(f"   ❌ PyTorch/CUDA error: {e}")
        gpu_ok = False

    # Test 2: vLLM Import
    print("\n2️⃣ Testing vLLM Installation...")
    try:
        import vllm
        print(f"   ✅ vLLM imported: {vllm.__version__}")
        print(f"   ✅ Location: {vllm.__file__}")
        vllm_ok = True
    except Exception as e:
        print(f"   ❌ vLLM import failed: {e}")
        vllm_ok = False

    # Test 3: vLLM Core Classes
    if vllm_ok:
        print("\n3️⃣ Testing vLLM Core Classes...")
        try:
            from vllm import LLM, SamplingParams
            print("   ✅ LLM class imported")
            print("   ✅ SamplingParams class imported")
            classes_ok = True
        except Exception as e:
            print(f"   ❌ vLLM classes failed: {e}")
            classes_ok = False
    else:
        classes_ok = False

    # Final Results
    print("\n" + "="*60)
    print("📊 FINAL RESULTS:")
    print(f"   GPU/PyTorch: {'✅ PASS' if gpu_ok else '❌ FAIL'}")
    print(f"   vLLM Import: {'✅ PASS' if vllm_ok else '❌ FAIL'}")
    print(f"   vLLM Classes: {'✅ PASS' if classes_ok else '❌ FAIL'}")
    
    all_ok = gpu_ok and vllm_ok and classes_ok
    
    if all_ok:
        print("\n🎉 SUCCESS: vLLM development environment is ready!")
        print("\n📋 Next Steps:")
        print("   • Load a model: llm = vllm.LLM('facebook/opt-125m')")
        print("   • Generate text: outputs = llm.generate(['Hello!'])")
        print("   • Start API server: python -m vllm.entrypoints.openai.api_server")
        return 0
    else:
        print("\n❌ FAILED: Environment has issues that need to be resolved")
        return 1

if __name__ == "__main__":
    sys.exit(main())
