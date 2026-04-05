# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import regex as re


def apply_git_patch(
    patch_file: Path, overlay_mode: bool = False, track_file: Path = None
):
    try:
        # Check if patch applies cleanly
        subprocess.run(
            ["git", "apply", "--check", str(patch_file)],
            check=True,
            capture_output=True,
        )
        # Apply the patch
        subprocess.run(
            ["git", "apply", str(patch_file)], check=True, capture_output=True
        )
        print(f"[patches] Applied {patch_file.name} successfully.")

        if overlay_mode and track_file:
            # Simple parsing of patched files
            with open(patch_file, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("+++ b/"):
                        filepath = line[6:].strip()
                        if filepath and filepath != "/dev/null":
                            with open(track_file, "a", encoding="utf-8") as tf:
                                tf.write(f"{filepath}\n")
        return True
    except subprocess.CalledProcessError:
        # Check if already applied
        try:
            subprocess.run(
                ["git", "apply", "--reverse", "--check", str(patch_file)],
                check=True,
                capture_output=True,
            )
            print(f"[patches] {patch_file.name} is already applied.")
            return True
        except subprocess.CalledProcessError:
            print(f"[patches] Failed to apply {patch_file.name} via git.")
            return False


def fallback_regex_replace(file_path: Path, pattern: str, replacement: str):
    if not file_path.exists():
        print(f"[patches] Fallback failed: {file_path} does not exist.")
        return False

    with open(file_path, encoding="utf-8") as f:
        content = f.read()

    if replacement in content:
        print(f"[patches] Fallback replacement already present in {file_path}.")
        return True

    new_content = re.sub(pattern, replacement, content)
    if new_content != content:
        with open(file_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(new_content)
        print(f"[patches] Applied regex fallback to {file_path}.")
        return True

    print(f"[patches] Regex pattern not found in {file_path}.")
    return False


def remove_regex_pattern(file_path: Path, pattern: str):
    if not file_path.exists():
        return False

    with open(file_path, encoding="utf-8") as f:
        content = f.read()

    new_content = re.sub(pattern, "", content)
    if new_content != content:
        with open(file_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(new_content)
        print(f"[patches] Removed pattern from {file_path}.")
        return True
    return False


def patch_fallback(name: str):
    print(f"[patches] Attempting programmatic fallback for {name}...")
    if name == "qutlass-fetchcontent-base":
        qutlass_file = Path("cmake/external_projects/qutlass.cmake")
        if not qutlass_file.exists():
            return False
        with open(qutlass_file, encoding="utf-8") as f:
            content = f.read()

        if "_qutlass_fetch_base" in content:
            print(
                "[patches] qutlass-fetchcontent-base is already applied via fallback."
            )
            return True

        # Insert variables at top
        new_content = content.replace(
            'set(CUTLASS_INCLUDE_DIR "${CUTLASS_INCLUDE_DIR}" '
            'CACHE PATH "Path to CUTLASS include/ directory")',
            'set(CUTLASS_INCLUDE_DIR "${CUTLASS_INCLUDE_DIR}" '
            'CACHE PATH "Path to CUTLASS include/ directory")\n\n'
            'set(_qutlass_fetch_base "")\n'
            "if(DEFINED FETCHCONTENT_BASE_DIR AND NOT "
            '"${FETCHCONTENT_BASE_DIR}" STREQUAL "")\n'
            '  set(_qutlass_fetch_base "${FETCHCONTENT_BASE_DIR}")\n'
            "elseif(DEFINED CMAKE_FETCHCONTENT_BASE_DIR AND NOT "
            '"${CMAKE_FETCHCONTENT_BASE_DIR}" STREQUAL "")\n'
            '  set(_qutlass_fetch_base "${CMAKE_FETCHCONTENT_BASE_DIR}")\n'
            "endif()\n\n"
            "if(NOT _qutlass_fetch_base)\n"
            '  set(_qutlass_fetch_base "${CMAKE_BINARY_DIR}/_deps")\n'
            "endif()\n\n"
            "set(_qutlass_default_source_dir "
            '"${_qutlass_fetch_base}/qutlass-src")\n'
            "set(_qutlass_default_binary_dir "
            '"${_qutlass_fetch_base}/qutlass-build")\n'
            "set(_qutlass_default_download_dir "
            '"${_qutlass_fetch_base}/qutlass-download")\n'
            "set(_qutlass_default_stamp_dir "
            '"${_qutlass_fetch_base}/qutlass-stamp")\n'
            "set(_qutlass_default_tmp_dir "
            '"${_qutlass_fetch_base}/qutlass-tmp")\n',
        )

        new_content = new_content.replace(
            "GIT_PROGRESS TRUE\n    CONFIGURE_COMMAND",
            "GIT_PROGRESS TRUE\n"
            '    SOURCE_DIR "${_qutlass_default_source_dir}"\n'
            '    BINARY_DIR "${_qutlass_default_binary_dir}"\n'
            '    DOWNLOAD_DIR "${_qutlass_default_download_dir}"\n'
            '    STAMP_DIR "${_qutlass_default_stamp_dir}"\n'
            '    TMP_DIR "${_qutlass_default_tmp_dir}"\n'
            "    CONFIGURE_COMMAND",
        )

        new_content = new_content.replace(
            'message(STATUS "[QUTLASS] QuTLASS is available at '
            '${qutlass_SOURCE_DIR}")\n',
            'message(STATUS "[QUTLASS] QuTLASS is available at '
            '${qutlass_SOURCE_DIR}")\n\n'
            "unset(_qutlass_fetch_base)\n"
            "unset(_qutlass_default_source_dir)\n"
            "unset(_qutlass_default_binary_dir)\n"
            "unset(_qutlass_default_download_dir)\n"
            "unset(_qutlass_default_stamp_dir)\n"
            "unset(_qutlass_default_tmp_dir)\n",
        )

        if new_content != content:
            with open(qutlass_file, "w", encoding="utf-8") as f:
                f.write(new_content)
            print("[patches] Applied fallback for qutlass-fetchcontent-base.")
            return True

    elif name == "cuda-optional-flags":
        cmakelists_file = Path("CMakeLists.txt")
        setup_file = Path("setup.py")
        cmake_applied = False
        setup_applied = False

        if cmakelists_file.exists():
            with open(cmakelists_file, encoding="utf-8") as f:
                c_content = f.read()
            if "VLLM_ENABLED_OPTIONAL_CUDA_LIBS" not in c_content:
                c_new = c_content.replace(
                    "include(${CMAKE_CURRENT_LIST_DIR}/cmake/utils.cmake)",
                    "include(${CMAKE_CURRENT_LIST_DIR}/cmake/utils.cmake)\n\n"
                    "set(_VLLM_OPTIONAL_CUDA_LIBS\n"
                    "  CUBLAS\n"
                    "  CUDNN\n"
                    "  CUFILE\n"
                    "  CUSPARSE\n"
                    "  CUSPARSELT\n"
                    "  CUDSS)\n"
                    "set(VLLM_ENABLED_OPTIONAL_CUDA_LIBS)\n"
                    "foreach(_lib ${_VLLM_OPTIONAL_CUDA_LIBS})\n"
                    '  set(_opt "USE_${_lib}")\n'
                    '  option(${_opt} "Enable optional CUDA '
                    'component ${_lib}" ON)\n'
                    "  if(${_opt})\n"
                    "    list(APPEND VLLM_ENABLED_OPTIONAL_CUDA_LIBS ${_lib})\n"
                    "  endif()\n"
                    "endforeach()\n"
                    "set(CAFFE2_USE_CUDNN ${USE_CUDNN})\n"
                    "set(CAFFE2_USE_CUSPARSELT ${USE_CUSPARSELT})\n"
                    "if(VLLM_ENABLED_OPTIONAL_CUDA_LIBS)\n"
                    "  list(JOIN VLLM_ENABLED_OPTIONAL_CUDA_LIBS "
                    '", " _vllm_enabled_cuda_libs_joined)\n'
                    '  message(STATUS "Optional CUDA components enabled: '
                    '${_vllm_enabled_cuda_libs_joined}")\n'
                    "else()\n"
                    '  message(STATUS "Optional CUDA components '
                    'enabled: (none)")\n'
                    "endif()\n",
                )
                if c_new != c_content:
                    with open(cmakelists_file, "w", encoding="utf-8") as f:
                        f.write(c_new)
                    cmake_applied = True
            else:
                print(
                    "[patches] fallback for cuda-optional-flags "
                    "(CMakeLists.txt) already applied."
                )
                cmake_applied = True

        if setup_file.exists():
            with open(setup_file, encoding="utf-8") as f:
                s_content = f.read()
            if "cuda_optional_envs" not in s_content:
                s_new = s_content.replace(
                    '        other_cmake_args = os.environ.get("CMAKE_ARGS")',
                    "        cuda_optional_envs = {\n"
                    '            "USE_CUBLAS": os.getenv("USE_CUBLAS"),\n'
                    '            "USE_CUDNN": os.getenv("USE_CUDNN"),\n'
                    '            "USE_CUFILE": os.getenv("USE_CUFILE"),\n'
                    '            "USE_CUSPARSE": os.getenv("USE_CUSPARSE"),\n'
                    '            "USE_CUSPARSELT": os.getenv("USE_CUSPARSELT"),\n'
                    '            "USE_CUDSS": os.getenv("USE_CUDSS"),\n'
                    "        }\n"
                    "        for key, value in cuda_optional_envs.items():\n"
                    "            if value is None:\n"
                    "                continue\n"
                    "            normalized = value.strip().lower()\n"
                    "            if not normalized:\n"
                    "                continue\n"
                    '            if normalized in {"1", "on", "true", "yes"}:\n'
                    '                cmake_args.append(f"-D{key}=ON")\n'
                    '            elif normalized in {"0", "off", "false", "no"}:\n'
                    '                cmake_args.append(f"-D{key}=OFF")\n'
                    "            else:\n"
                    '                cmake_args.append(f"-D{key}={value}")\n\n'
                    '        other_cmake_args = os.environ.get("CMAKE_ARGS")',
                )
                if s_new != s_content:
                    with open(setup_file, "w", encoding="utf-8") as f:
                        f.write(s_new)
                    setup_applied = True
            else:
                print(
                    "[patches] fallback for cuda-optional-flags "
                    "(setup.py) already applied."
                )
                setup_applied = True

        if cmake_applied and setup_applied:
            print("[patches] Applied fallback for cuda-optional-flags.")
            return True
        elif cmake_applied or setup_applied:
            print(
                "[patches] WARNING: Fallback for cuda-optional-flags partially applied."
            )
            return False

    elif name == "cuda-memcpy-batch-compat":
        cache_kernels_file = Path("csrc/cache_kernels.cu")
        if not cache_kernels_file.exists():
            return False

        with open(cache_kernels_file, encoding="utf-8") as f:
            content = f.read()

        if "CuMemcpyBatchAsyncV1" in content:
            print(
                "[patches] fallback for cuda-memcpy-batch-compat already applied."
            )
            return True

        new_content = content
        if "#include <type_traits>" not in new_content:
            new_content = new_content.replace(
                "#include <cfloat>\n",
                "#include <cfloat>\n#include <type_traits>\n",
            )

        old_block = (
            "  static_assert(sizeof(CUdeviceptr) == sizeof(int64_t));\n"
            "  static_assert(sizeof(size_t) == sizeof(int64_t));\n"
            "#if !defined(USE_ROCM) && defined(CUDA_VERSION) && CUDA_VERSION >= 12080\n"
            "  CUmemcpyAttributes attr = {};\n"
            "  attr.srcAccessOrder = CU_MEMCPY_SRC_ACCESS_ORDER_STREAM;\n"
            "  size_t attrs_idx = 0;\n"
            "  size_t fail_idx = 0;\n"
            "  CUresult result = cuMemcpyBatchAsync(\n"
            "      reinterpret_cast<CUdeviceptr*>(const_cast<int64_t*>(dst_data)),\n"
            "      reinterpret_cast<CUdeviceptr*>(const_cast<int64_t*>(src_data)),\n"
            "      reinterpret_cast<size_t*>(const_cast<int64_t*>(size_data)),\n"
            "      static_cast<size_t>(n), &attr, &attrs_idx, 1, &fail_idx,\n"
            "      static_cast<CUstream>(stream));\n"
            "  TORCH_CHECK(result == CUDA_SUCCESS, \"cuMemcpyBatchAsync failed at index \",\n"
            "              fail_idx, \" with error \", result);\n"
            "#else\n"
            "  // Fallback for CUDA < 12.8 and ROCm: individual async copies.\n"
            "  // cudaMemcpyDefault lets the driver infer direction from pointer types.\n"
            "  for (int64_t i = 0; i < n; i++) {\n"
            "    cudaMemcpyAsync(reinterpret_cast<void*>(dst_data[i]),\n"
            "                    reinterpret_cast<void*>(src_data[i]),\n"
            "                    static_cast<size_t>(size_data[i]), cudaMemcpyDefault,\n"
            "                    stream);\n"
            "  }\n"
            "#endif\n"
        )
        replacement_block = (
            "  static_assert(sizeof(CUdeviceptr) == sizeof(int64_t));\n"
            "  static_assert(sizeof(size_t) == sizeof(int64_t));\n"
            "#if !defined(USE_ROCM) && defined(CUDA_VERSION) && CUDA_VERSION >= 12080\n"
            "  auto fallback_memcpy_async = [&]() {\n"
            "    for (int64_t i = 0; i < n; i++) {\n"
            "      cudaMemcpyAsync(reinterpret_cast<void*>(dst_data[i]),\n"
            "                      reinterpret_cast<void*>(src_data[i]),\n"
            "                      static_cast<size_t>(size_data[i]), cudaMemcpyDefault,\n"
            "                      stream);\n"
            "    }\n"
            "  };\n\n"
            "  using CuMemcpyBatchAsyncV1 = CUresult(CUDAAPI *)(\n"
            "      CUdeviceptr*, CUdeviceptr*, size_t*, size_t, CUmemcpyAttributes*,\n"
            "      size_t*, size_t, CUstream);\n"
            "  using CuMemcpyBatchAsyncV2 = CUresult(CUDAAPI *)(\n"
            "      CUdeviceptr*, CUdeviceptr*, size_t*, size_t, CUmemcpyAttributes*,\n"
            "      size_t*, size_t, size_t*, CUstream);\n"
            "  struct CuMemcpyBatchAsyncCompat {\n"
            "    static CUresult call(CuMemcpyBatchAsyncV1 fn, CUdeviceptr* dsts,\n"
            "                         CUdeviceptr* srcs, size_t* sizes, size_t count,\n"
            "                         CUmemcpyAttributes* attrs, size_t* attrs_idx,\n"
            "                         size_t num_attrs, size_t* fail_idx,\n"
            "                         CUstream stream) {\n"
            "      if (fail_idx != nullptr) {\n"
            "        *fail_idx = 0;\n"
            "      }\n"
            "      return fn(dsts, srcs, sizes, count, attrs, attrs_idx, num_attrs,\n"
            "                stream);\n"
            "    }\n\n"
            "    static CUresult call(CuMemcpyBatchAsyncV2 fn, CUdeviceptr* dsts,\n"
            "                         CUdeviceptr* srcs, size_t* sizes, size_t count,\n"
            "                         CUmemcpyAttributes* attrs, size_t* attrs_idx,\n"
            "                         size_t num_attrs, size_t* fail_idx,\n"
            "                         CUstream stream) {\n"
            "      return fn(dsts, srcs, sizes, count, attrs, attrs_idx, num_attrs,\n"
            "                fail_idx, stream);\n"
            "    }\n\n"
            "    static CUresult call(...) {\n"
            "      return CUDA_ERROR_NOT_SUPPORTED;\n"
            "    }\n"
            "  };\n\n"
            "  constexpr auto cuMemcpyBatchAsyncPtr = &cuMemcpyBatchAsync;\n"
            "  CUmemcpyAttributes attr = {};\n"
            "  attr.srcAccessOrder = CU_MEMCPY_SRC_ACCESS_ORDER_STREAM;\n"
            "  size_t attrs_idx = 0;\n"
            "  size_t fail_idx = 0;\n"
            "  CUresult result = CuMemcpyBatchAsyncCompat::call(\n"
            "      cuMemcpyBatchAsyncPtr,\n"
            "      reinterpret_cast<CUdeviceptr*>(const_cast<int64_t*>(dst_data)),\n"
            "      reinterpret_cast<CUdeviceptr*>(const_cast<int64_t*>(src_data)),\n"
            "      reinterpret_cast<size_t*>(const_cast<int64_t*>(size_data)),\n"
            "      static_cast<size_t>(n), &attr, &attrs_idx, 1, &fail_idx,\n"
            "      static_cast<CUstream>(stream));\n"
            "  if (result == CUDA_ERROR_NOT_SUPPORTED) {\n"
            "    fallback_memcpy_async();\n"
            "  } else {\n"
            "    TORCH_CHECK(result == CUDA_SUCCESS, \"cuMemcpyBatchAsync failed at index \",\n"
            "                fail_idx, \" with error \", result);\n"
            "  }\n"
            "#else\n"
            "  // Fallback for CUDA < 12.8 and ROCm: individual async copies.\n"
            "  // cudaMemcpyDefault lets the driver infer direction from pointer types.\n"
            "  for (int64_t i = 0; i < n; i++) {\n"
            "    cudaMemcpyAsync(reinterpret_cast<void*>(dst_data[i]),\n"
            "                    reinterpret_cast<void*>(src_data[i]),\n"
            "                    static_cast<size_t>(size_data[i]), cudaMemcpyDefault,\n"
            "                    stream);\n"
            "  }\n"
            "#endif\n"
        )

        if old_block in new_content:
            new_content = new_content.replace(old_block, replacement_block)

        if new_content != content:
            with open(cache_kernels_file, "w", encoding="utf-8") as f:
                f.write(new_content)
            print("[patches] Applied fallback for cuda-memcpy-batch-compat.")
            return True

    return False


def reset_patches(track_file: Path):
    if not track_file.exists():
        print("[patches-reset] No track file found. Exiting.")
        return

    try:
        with open(track_file) as f:
            targets = set(line.strip() for line in f if line.strip())

        if not targets:
            track_file.unlink(missing_ok=True)
            print("[patches-reset] Track file is empty. Removed.")
            return

        print(f"[patches-reset] Reverting {len(targets)} file(s)")

        for target in targets:
            subprocess.run(
                ["git", "checkout", "--", target], check=True, capture_output=True
            )

        track_file.unlink(missing_ok=True)
        print("[patches-reset] Done.")

    except subprocess.CalledProcessError as e:
        print(f"[patches-reset] Failed to revert patches: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"[patches-reset] Error: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="vLLM Custom Patch Manager")
    parser.add_argument(
        "--config",
        type=str,
        default="extras/patches/patches.json",
        help="Path to patches configuration file.",
    )
    parser.add_argument(
        "--overlay-mode",
        action="store_true",
        help="Enable overlay mode (for containers).",
    )
    parser.add_argument(
        "--track-file",
        type=str,
        default="/opt/work/tmp/vllm_patched_files.txt",
        help="File to track patched files in overlay mode.",
    )
    parser.add_argument(
        "--reset", action="store_true", help="Reset patched files based on track file."
    )
    args = parser.parse_args()

    track_file = Path(args.track_file)

    if args.reset:
        reset_patches(track_file)
        sys.exit(0)

    # In legacy scripts: if overlay mode is set by env var:
    overlay_mode = (
        args.overlay_mode or os.environ.get("PYTHON_PATCH_OVERLAY", "0") == "1"
    )
    config_path = Path(args.config)

    if not config_path.exists():
        print(f"[patches] Config file not found: {config_path}")
        sys.exit(1)

    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)

    if overlay_mode:
        track_file.parent.mkdir(parents=True, exist_ok=True)
        track_file.touch(exist_ok=True)

    print(
        f"[patches] Applying {len(config['patches'])} patches "
        f"(Overlay Mode: {overlay_mode})"
    )

    for patch_info in config["patches"]:
        name = patch_info["name"]
        diff_file = Path("extras/patches") / patch_info["diff"]

        print(f"[patches] Processing {name} ({diff_file.name})")

        if (
            overlay_mode
            and patch_info.get("skip_in_overlay", False)
            and diff_file.name == "0001-cumem-alloc-env-fallback.diff"
        ):
            print(f"[patches] Skipping {name} in overlay mode.")
            continue

        success = apply_git_patch(
            diff_file, overlay_mode=overlay_mode, track_file=track_file
        )

        if not success:
            if (
                "fallback" in patch_info
                and patch_info["fallback"]["type"] == "regex_replace"
            ):
                print(f"[patches] Attempting configured fallback for {name}...")
                fallback = patch_info["fallback"]
                target_file = Path(fallback["file"])
                fallback_regex_replace(
                    target_file, fallback["pattern"], fallback["replacement"]
                )
            else:
                patch_fallback(name)

    # Post-patch actions
    if not overlay_mode:
        # Example of a post-patch script logic previously in bash script
        # Removing expandable_segments assert
        cumem_path = Path("vllm/device_allocator/cumem.py")
        pattern = (
            r'assert\s+"expandable_segments:True"[^\n]*\n(?:\s+\('
            r'"Expandable segments[\s\S]*?updates\."\)\n)?'
        )
        remove_regex_pattern(cumem_path, pattern)

    if overlay_mode and track_file.exists():
        # Clean up duplicates in track file
        try:
            with open(track_file) as f:
                lines = set(f.readlines())
            with open(track_file, "w") as f:
                f.writelines(sorted(list(lines)))
        except Exception as e:
            print(f"[patches] Warning: Could not deduplicate track file: {e}")

    print("[patches] Done.")


if __name__ == "__main__":
    main()
