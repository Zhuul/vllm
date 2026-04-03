#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Prime or verify a local model cache for smoke testing."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="Model identifier to cache.")
    parser.add_argument(
        "--provider",
        choices=("auto", "modelscope", "huggingface"),
        default="auto",
        help="Model backend to use when resolving the model snapshot.",
    )
    parser.add_argument("--revision", help="Optional model revision.")
    parser.add_argument("--cache-dir", help="Optional cache directory override.")
    parser.add_argument(
        "--allow-network",
        action="store_true",
        help="Allow network access to download the model if it is not cached.",
    )
    parser.add_argument("--output", help="Optional path to write JSON results.")
    return parser


def choose_provider(name: str) -> str:
    if name != "auto":
        return name
    if os.getenv("VLLM_USE_MODELSCOPE"):
        return "modelscope"
    return "huggingface"


def resolve_snapshot(
    model: str,
    provider: str,
    cache_dir: str | None,
    revision: str | None,
    allow_network: bool,
) -> str:
    if provider == "modelscope":
        from modelscope.hub.snapshot_download import (  # type: ignore[import-not-found]
            snapshot_download,
        )

        return snapshot_download(
            model_id=model,
            cache_dir=cache_dir,
            revision=revision,
            local_files_only=not allow_network,
        )

    from huggingface_hub import snapshot_download  # type: ignore[import-not-found]

    return snapshot_download(
        repo_id=model,
        cache_dir=cache_dir,
        revision=revision,
        local_files_only=not allow_network,
    )


def main() -> int:
    args = build_parser().parse_args()
    provider = choose_provider(args.provider)
    cache_dir = args.cache_dir
    if provider == "modelscope" and not cache_dir:
        cache_dir = os.getenv("MODELSCOPE_CACHE") or os.getenv("MODELSCOPE_HOME")

    resolved = resolve_snapshot(
        model=args.model,
        provider=provider,
        cache_dir=cache_dir,
        revision=args.revision,
        allow_network=args.allow_network,
    )
    payload = {
        "model": args.model,
        "provider": provider,
        "revision": args.revision,
        "allow_network": args.allow_network,
        "cache_dir": cache_dir,
        "resolved_path": resolved,
        "exists": Path(resolved).exists(),
    }
    print(json.dumps(payload, indent=2))
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"Wrote cache report to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())