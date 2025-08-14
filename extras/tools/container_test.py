#!/usr/bin/env python3
"""
vLLM Container Test Script
Run this inside the container to verify everything works
"""

def test_basic_functionality():
    """Test basic vLLM import and GPU detection"""
    print("🔍 Testing vLLM Container Environment...")
    print("=" * 50)
    
    # Test PyTorch and CUDA
    import torch
    print(f"✅ PyTorch {torch.__version__}")
    print(f"✅ CUDA Available: {torch.cuda.is_available()}")
    
    if torch.cuda.is_available():
        gpu_name = torch.cuda.get_device_name(0)
        gpu_memory = torch.cuda.get_device_properties(0).total_memory // (1024**3)
        print(f"✅ GPU: {gpu_name} ({gpu_memory}GB)")
    
    # Test vLLM import (from a clean environment)
    try:
        import vllm
        print(f"✅ vLLM {vllm.__version__}")
        
        # Test core classes
        from vllm import LLM, SamplingParams
        print("✅ vLLM Core Classes Available")
        
        print("\n🎉 SUCCESS: vLLM environment is fully functional!")
        print("\nTo test with a model, try:")
        print("  llm = LLM(model='facebook/opt-125m')")
        print("  outputs = llm.generate(['Hello world'], SamplingParams())")
        
        return True
        
    except Exception as e:
        print(f"❌ vLLM Error: {e}")
        return False

if __name__ == "__main__":
    test_basic_functionality()
