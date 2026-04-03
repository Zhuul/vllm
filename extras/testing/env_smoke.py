#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Capture a minimal environment sanity report for container/image validation."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path


def command_output(command: list[str]) -> str:
    try:
        completed = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except Exception as exc:
        return f"ERROR: {exc}"
    return completed.stdout.strip()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="Optional path to write JSON results.")
    return parser


def main() -> int:
    args = build_parser().parse_args()

    payload = {
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "cuda_visible_devices": os.getenv("CUDA_VISIBLE_DEVICES"),
        "torch_cuda_arch_list": os.getenv("TORCH_CUDA_ARCH_LIST"),
        "cudaarchs": os.getenv("CUDAARCHS"),
        "vllm_use_modelscope": os.getenv("VLLM_USE_MODELSCOPE"),
        "torch_version": command_output([
            sys.executable,
            "-c",
            "import torch; print(torch.__version__)",
        ]),
        "torch_cuda_available": command_output([
            sys.executable,
            "-c",
            "import torch; print(torch.cuda.is_available())",
        ]),
        "torch_device_count": command_output([
            sys.executable,
            "-c",
            "import torch; print(torch.cuda.device_count())",
        ]),
        "vllm_version": command_output([
            sys.executable,
            "-c",
            "import vllm; print(getattr(vllm, '__version__', 'unknown'))",
        ]),
        "nvidia_smi": command_output(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"]),
    }

    print(json.dumps(payload, indent=2))
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"Wrote env report to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())