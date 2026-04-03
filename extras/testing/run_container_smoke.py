#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Run the extras testing smoke suite inside one or more container images."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
WORKSPACE_DIR = BASE_DIR.parent.parent
RESULTS_DIR = BASE_DIR / "results"
DEFAULT_RUNTIME = "podman"
DEFAULT_IMAGES = ["dev=vllm-dev:latest"]
DEFAULT_PASSTHROUGH_ENV = [
    "MODELSCOPE_CACHE",
    "MODELSCOPE_HOME",
    "VLLM_USE_MODELSCOPE",
    "HF_HUB_OFFLINE",
    "HF_DATASETS_OFFLINE",
    "TRANSFORMERS_OFFLINE",
    "TRANSFORMERS_NO_ADVISORY_WARNINGS",
    "TORCH_CUDA_ARCH_LIST",
    "CUDAARCHS",
]


def parse_image_spec(spec: str) -> tuple[str, str]:
    if "=" in spec:
        label, image = spec.split("=", 1)
    else:
        image = spec
        label = image.replace(":", "-").replace("/", "-")
    label = label.strip()
    image = image.strip()
    if not label or not image:
        raise SystemExit(f"Invalid image spec: {spec!r}")
    return label, image


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runtime",
        choices=("podman", "docker"),
        default=DEFAULT_RUNTIME,
    )
    parser.add_argument(
        "--image",
        action="append",
        default=None,
        help="Image spec as label=image. Repeatable.",
    )
    parser.add_argument(
        "--suite",
        default="deepseek_smoke",
        help="Suite from extras/testing/test_matrix.yaml to run inside each image.",
    )
    parser.add_argument(
        "--model",
        default="deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B",
        help="Model id exposed to the in-container smoke suite.",
    )
    parser.add_argument(
        "--extra-env",
        action="append",
        default=[],
        help="Extra KEY=VALUE environment variables to pass through to the container.",
    )
    parser.add_argument(
        "--compare",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Run extras/testing/compare_results.py when exactly two images are tested.",
    )
    return parser


def container_base_command(runtime: str) -> list[str]:
    cmd = [runtime, "run", "--rm", "--shm-size", "8g", "-w", "/workspace"]
    if runtime == "podman":
        cmd.extend(["--security-opt=label=disable", "--device", "nvidia.com/gpu=all"])
        mount_suffix = ":Z"
    else:
        cmd.extend(["--gpus", "all"])
        mount_suffix = ""
    cmd.extend(["-v", f"{WORKSPACE_DIR}:/workspace{mount_suffix}"])
    return cmd


def build_env_args(extra_env: list[str]) -> list[str]:
    env_args: list[str] = []
    for key in DEFAULT_PASSTHROUGH_ENV:
        value = os.getenv(key)
        if value:
            env_args.extend(["--env", f"{key}={value}"])
    for item in extra_env:
        if "=" not in item:
            raise SystemExit(f"Invalid --extra-env entry: {item!r}")
        env_args.extend(["--env", item])
    return env_args


def run_suite(runtime: str, image_label: str, image_name: str, suite: str, model: str, extra_env: list[str]) -> Path:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    result_path = RESULTS_DIR / f"{image_label}-{suite}.json"
    cmd = container_base_command(runtime)
    cmd.extend(build_env_args(extra_env))
    cmd.append(image_name)
    cmd.extend(
        [
            "python",
            "/workspace/extras/testing/run_tests.py",
            "--profile",
            image_label,
            "--suite",
            suite,
            "--output",
            f"/workspace/extras/testing/results/{result_path.name}",
        ]
    )
    env = os.environ.copy()
    env["DEEPSEEK_SMOKE_MODEL"] = model
    print(f"[container-smoke] running {image_label} -> {image_name}")
    subprocess.run(cmd, cwd=WORKSPACE_DIR, env=env, check=True)
    return result_path


def maybe_compare(result_paths: list[Path]) -> None:
    if len(result_paths) != 2:
        return
    compare_cmd = [
        sys.executable,
        str(BASE_DIR / "compare_results.py"),
        "--baseline",
        str(result_paths[0]),
        "--patched",
        str(result_paths[1]),
    ]
    subprocess.run(compare_cmd, cwd=WORKSPACE_DIR, check=True)


def main() -> int:
    args = build_parser().parse_args()
    image_specs = args.image or DEFAULT_IMAGES
    parsed_images = [parse_image_spec(spec) for spec in image_specs]
    result_paths: list[Path] = []
    for label, image in parsed_images:
        result_paths.append(
            run_suite(args.runtime, label, image, args.suite, args.model, args.extra_env)
        )
    if args.compare:
        maybe_compare(result_paths)
    for path in result_paths:
        print(f"[container-smoke] result -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())