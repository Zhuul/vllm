#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Run a small offline model smoke test with a default DeepSeek model."""

from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
from pathlib import Path
from collections.abc import Sequence

from vllm import LLM, SamplingParams


DEFAULT_MODEL = "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B"
DEFAULT_PROMPTS = [
    "Explain in one short paragraph why KV cache matters for LLM serving.",
    "List three practical checks for validating a fresh CUDA inference image.",
]


def is_offline_mode() -> bool:
    return any(
        os.getenv(name, "").lower() in {"1", "true", "yes", "on"}
        for name in ("HF_HUB_OFFLINE", "HF_DATASETS_OFFLINE", "TRANSFORMERS_OFFLINE")
    )


def resolve_model_reference(model: str, download_dir: str | None) -> str:
    candidate = Path(model)
    if (candidate.exists() or not os.getenv("VLLM_USE_MODELSCOPE")
            or not is_offline_mode()):
        return model

    cache_dir = (download_dir or os.getenv("MODELSCOPE_CACHE")
                 or os.getenv("MODELSCOPE_HOME"))
    try:
        from modelscope.hub.snapshot_download import (  # type: ignore[import-not-found]
            snapshot_download,
        )

        resolved = snapshot_download(
            model_id=model,
            cache_dir=cache_dir,
            local_files_only=True,
        )
    except Exception:
        return model

    resolved_path = Path(resolved)
    if resolved_path.exists():
        return str(resolved_path)
    return model


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument(
        "--prompt",
        action="append",
        dest="prompts",
        help="Prompt to run. Repeat to add more prompts.",
    )
    parser.add_argument("--max-model-len", type=int, default=1024)
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--tensor-parallel-size", type=int, default=1)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--gpu-memory-utilization", type=float, default=0.50)
    parser.add_argument("--dtype", default="auto")
    parser.add_argument("--seed", type=int, default=1234)
    parser.add_argument("--trust-remote-code", action="store_true")
    parser.add_argument("--enforce-eager", action="store_true")
    parser.add_argument("--download-dir")
    parser.add_argument("--output", help="Optional path to write JSON results.")
    parser.add_argument(
        "--min-output-chars",
        type=int,
        default=16,
        help="Minimum number of non-whitespace characters expected per output.",
    )
    return parser


def build_payload(
    args: argparse.Namespace,
    outputs: list[dict[str, str]],
    elapsed: float,
) -> dict[str, object]:
    return {
        "model": args.model,
        "resolved_model": getattr(args, "resolved_model", args.model),
        "elapsed_s": elapsed,
        "dtype": args.dtype,
        "tensor_parallel_size": args.tensor_parallel_size,
        "max_model_len": args.max_model_len,
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "trust_remote_code": args.trust_remote_code,
        "enforce_eager": args.enforce_eager,
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "cuda_visible_devices": os.getenv("CUDA_VISIBLE_DEVICES"),
        "vllm_use_modelscope": os.getenv("VLLM_USE_MODELSCOPE"),
        "prompt_count": len(outputs),
        "min_output_chars": args.min_output_chars,
        "outputs": outputs,
    }


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    args.resolved_model = resolve_model_reference(args.model, args.download_dir)
    prompts = list(args.prompts or DEFAULT_PROMPTS)
    sampling_params = SamplingParams(
        temperature=args.temperature,
        top_p=args.top_p,
        max_tokens=args.max_tokens,
        seed=args.seed,
    )

    llm_args: dict[str, object] = {
        "model": args.resolved_model,
        "tensor_parallel_size": args.tensor_parallel_size,
        "max_model_len": args.max_model_len,
        "dtype": args.dtype,
        "gpu_memory_utilization": args.gpu_memory_utilization,
        "trust_remote_code": args.trust_remote_code,
        "enforce_eager": args.enforce_eager,
    }
    if args.download_dir:
        llm_args["download_dir"] = args.download_dir

    start = time.perf_counter()
    llm = LLM(**llm_args)
    results = llm.generate(prompts, sampling_params)
    elapsed = time.perf_counter() - start

    outputs: list[dict[str, str]] = []
    for result in results:
        text = result.outputs[0].text.strip() if result.outputs else ""
        if not text:
            raise SystemExit(
                f"Smoke test produced empty output for prompt: {result.prompt!r}"
            )
        if len(text) < args.min_output_chars:
            raise SystemExit(
                "Smoke test output was shorter than the configured minimum "
                f"({args.min_output_chars} chars) for prompt: {result.prompt!r}"
            )
        if text == result.prompt.strip():
            raise SystemExit(
                "Smoke test output matched the prompt verbatim for prompt: "
                f"{result.prompt!r}"
            )
        entry = {
            "prompt": result.prompt,
            "text": text,
            "char_count": len(text),
        }
        outputs.append(entry)
        print("-" * 60)
        print(f"Prompt: {result.prompt}")
        print(f"Output: {text}")
        print(f"Output chars: {len(text)}")

    payload = build_payload(args, outputs, elapsed)
    print("-" * 60)
    print(f"Smoke test finished in {elapsed:.2f}s for model {args.model}")

    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"Wrote smoke payload to {output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())