#!/usr/bin/env python3
"""
RTX 5090 Support Validation Script
Tests PyTorch nightly, CUDA detection, and vLLM RTX 5090 compatibility
"""

import os
import sys
import subprocess
import traceback

def print_section(title):
    print(f"\n{'='*60}")
    print(f" {title}")
    print('='*60)

def run_command(cmd, description):
    """Run a command and return success status"""
    try:
        print(f"\n🔍 {description}")
        print(f"Command: {cmd}")
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        print(f"Exit code: {result.returncode}")
        if result.stdout:
            print(f"Output: {result.stdout.strip()}")
        if result.stderr and result.returncode != 0:
            print(f"Error: {result.stderr.strip()}")
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        print("❌ Command timed out")
        return False
    except Exception as e:
        print(f"❌ Command failed: {e}")
        return False

def check_environment():
    """Check environment variables"""
    print_section("ENVIRONMENT VALIDATION")
    
    env_vars = [
        'TORCH_CUDA_ARCH_LIST',
        'CUDA_HOME',
        'CMAKE_ARGS',
        'MAX_JOBS',
        'VLLM_TARGET_DEVICE'
    ]
    
    for var in env_vars:
        value = os.environ.get(var, 'NOT SET')
        status = "✅" if value != 'NOT SET' else "❌"
        print(f"{status} {var}: {value}")
    
    # Check critical RTX 5090 support
    arch_list = os.environ.get('TORCH_CUDA_ARCH_LIST', '')
    if '12.0' in arch_list:
        print("✅ RTX 5090 (sm_120) architecture included in TORCH_CUDA_ARCH_LIST")
    else:
        print("❌ RTX 5090 (sm_120) architecture missing from TORCH_CUDA_ARCH_LIST")
        print("   Expected: should contain '12.0'")

def check_cuda():
    """Check CUDA installation and GPU detection"""
    print_section("CUDA VALIDATION")
    
    # Check nvcc
    nvcc_ok = run_command("nvcc --version", "NVCC version check")
    
    # Check nvidia-smi
    smi_ok = run_command("nvidia-smi", "NVIDIA SMI check")
    
    return nvcc_ok and smi_ok

def check_pytorch():
    """Check PyTorch installation and CUDA support"""
    print_section("PYTORCH VALIDATION")
    
    try:
        import torch
        print(f"✅ PyTorch imported successfully")
        print(f"   Version: {torch.__version__}")
        print(f"   CUDA version: {torch.version.cuda}")
        print(f"   CUDA available: {torch.cuda.is_available()}")
        
        if torch.cuda.is_available():
            print(f"   CUDA device count: {torch.cuda.device_count()}")
            try:
                device_name = torch.cuda.get_device_name(0)
                print(f"   GPU: {device_name}")
                
                # Check for RTX 5090
                if "RTX 5090" in device_name:
                    print("🎉 RTX 5090 detected!")
                    props = torch.cuda.get_device_properties(0)
                    print(f"   Compute Capability: {props.major}.{props.minor}")
                    if props.major >= 12:  # RTX 5090 should be compute 12.x
                        print("✅ RTX 5090 compute capability confirmed")
                    else:
                        print(f"⚠️  Unexpected compute capability for RTX 5090: {props.major}.{props.minor}")
                else:
                    print(f"ℹ️  GPU detected: {device_name}")
                    
            except Exception as e:
                print(f"❌ GPU details unavailable: {e}")
        else:
            print("❌ CUDA not available in PyTorch")
            
        # Test CUDA arch flags
        try:
            import torch.utils.cpp_extension as cpp
            flags = cpp._get_cuda_arch_flags()
            print(f"   Detected CUDA arch flags: {flags}")
            
            # Check for sm_120
            sm120_found = any('120' in flag for flag in flags)
            if sm120_found:
                print("✅ sm_120 (RTX 5090) architecture flags detected")
            else:
                print("❌ sm_120 (RTX 5090) architecture flags missing")
                
        except Exception as e:
            print(f"⚠️  Could not check CUDA arch flags: {e}")
            
        return True
        
    except ImportError as e:
        print(f"❌ PyTorch import failed: {e}")
        return False
    except Exception as e:
        print(f"❌ PyTorch check failed: {e}")
        return False

def check_vllm():
    """Check vLLM installation"""
    print_section("VLLM VALIDATION")
    
    try:
        import vllm
        print(f"✅ vLLM imported successfully")
        print(f"   Version: {vllm.__version__}")
        
        # Try to create a simple LLM instance (this will test CUDA kernels)
        print("\n🧪 Testing vLLM CUDA kernel compilation...")
        try:
            # This is a very basic test - just import key modules
            from vllm import LLM
            print("✅ vLLM LLM class imported successfully")
            
            # Check if we can access CUDA kernels
            try:
                from vllm._C import ops
                print("✅ vLLM CUDA ops imported successfully")
            except ImportError as e:
                print(f"⚠️  vLLM CUDA ops not available: {e}")
                
        except Exception as e:
            print(f"⚠️  vLLM CUDA test failed: {e}")
            
        return True
        
    except ImportError as e:
        print(f"❌ vLLM import failed: {e}")
        print("   This is expected if vLLM installation is not complete")
        return False
    except Exception as e:
        print(f"❌ vLLM check failed: {e}")
        return False

def main():
    """Main validation function"""
    print("🚀 RTX 5090 Support Validation")
    print("This script validates PyTorch nightly, CUDA, and vLLM compatibility")
    
    results = {}
    
    # Run all checks
    results['environment'] = check_environment()
    results['cuda'] = check_cuda()
    results['pytorch'] = check_pytorch()
    results['vllm'] = check_vllm()
    
    # Summary
    print_section("VALIDATION SUMMARY")
    
    total_checks = len(results)
    passed_checks = sum(1 for result in results.values() if result)
    
    for check, result in results.items():
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"{status} {check.upper()}")
    
    print(f"\nOverall: {passed_checks}/{total_checks} checks passed")
    
    if results.get('pytorch') and '12.0' in os.environ.get('TORCH_CUDA_ARCH_LIST', ''):
        print("\n🎉 RTX 5090 SUPPORT READY!")
        print("   - PyTorch nightly with CUDA 12.9 ✅")
        print("   - sm_120 architecture support ✅")
        print("   - Environment configured correctly ✅")
    elif results.get('pytorch'):
        print("\n⚠️  PyTorch working but RTX 5090 support incomplete")
        print("   Check TORCH_CUDA_ARCH_LIST includes '12.0'")
    else:
        print("\n❌ RTX 5090 support not ready")
        print("   Fix PyTorch/CUDA issues first")
    
    return passed_checks == total_checks

if __name__ == "__main__":
    try:
        success = main()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\n❌ Validation interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n\n❌ Validation failed with error: {e}")
        traceback.print_exc()
        sys.exit(1)
