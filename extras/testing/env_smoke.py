#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Capture a minimal environment sanity report for container/image validation."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = Path(__file__).resolve().parent


def _normalized_path(entry: str) -> Path:
    return Path(entry or os.getcwd()).resolve()


sys.path[:] = [
    entry for entry in sys.path
    if _normalized_path(entry) not in {REPO_ROOT, SCRIPT_DIR}
]

if (importlib.util.find_spec("vllm") is None
        and str(REPO_ROOT) not in sys.path):
    sys.path.insert(0, str(REPO_ROOT))


def import_output(module: str, expression: str) -> str:
    try:
        namespace: dict[str, object] = {}
        exec(f"import {module}\nvalue = {expression}", namespace)
    except Exception as exc:
        return f"ERROR: {exc}"
    return str(namespace["value"]).strip()


def nvidia_smi_output() -> str:
    try:
        import subprocess

        completed = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"],
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
        "torch_version": import_output("torch", "torch.__version__"),
        "torch_cuda_available": import_output("torch", "torch.cuda.is_available()"),
        "torch_device_count": import_output("torch", "torch.cuda.device_count()"),
        "vllm_version": import_output(
            "vllm",
            "getattr(vllm, '__version__', 'unknown')",
        ),
        "nvidia_smi": nvidia_smi_output(),
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