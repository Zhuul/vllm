#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Compare JSON outputs produced by run_tests.py."""

from __future__ import annotations

import argparse
import json
from collections.abc import Mapping, Sequence
from pathlib import Path


def load_results(path: Path) -> Mapping[tuple[str, str], Mapping[str, object]]:
    if not path.exists():
        raise SystemExit(f"Results file not found: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        raise SystemExit(f"Unexpected results format in {path}")
    index: dict[tuple[str, str], Mapping[str, object]] = {}
    for item in payload:
        if not isinstance(item, Mapping):
            raise SystemExit(f"Invalid entry in {path}")
        suite = str(item.get("suite", ""))
        name = str(item.get("name", ""))
        index[(suite, name)] = item
    return index


def describe(entry: Mapping[str, object]) -> str:
    status = entry.get("status", "?")
    duration = entry.get("duration_s", 0.0)
    rc = entry.get("returncode")
    return f"status={status} duration={float(duration):.2f}s rc={rc}"


def compare(
    baseline: Mapping[tuple[str, str], Mapping[str, object]],
    patched: Mapping[tuple[str, str], Mapping[str, object]],
) -> None:
    all_keys = sorted(set(baseline.keys()) | set(patched.keys()))
    regressions = 0
    for key in all_keys:
        base = baseline.get(key)
        patch = patched.get(key)
        suite, name = key
        header = f"{suite}::{name}"
        if base is None:
            print(f"[+] {header} added -> {describe(patch)}")
            continue
        if patch is None:
            print(f"[-] {header} missing in patched run")
            regressions += 1
            continue

        base_status = base.get("status")
        patch_status = patch.get("status")
        base_duration = float(base.get("duration_s", 0.0))
        patch_duration = float(patch.get("duration_s", 0.0))
        delta = patch_duration - base_duration

        if base_status == patch_status == "passed":
            if abs(delta) >= 1.0:
                flag = "slower" if delta > 0 else "faster"
                print(
                    f"[=] {header} passed; patched {flag} by {abs(delta):.2f}s "
                    f"(base {base_duration:.2f}s -> patched {patch_duration:.2f}s)"
                )
            continue

        if base_status != patch_status:
            print(
                f"[!] {header} status regression: base={base_status} "
                f"patched={patch_status} "
                f"(base {describe(base)} | patched {describe(patch)})"
            )
            regressions += 1
        elif patch_status != "passed":
            print(
                f"[~] {header} still failing: base={describe(base)} | "
                f"patched={describe(patch)}"
            )
            regressions += 1

    if regressions:
        print(f"[summary] regressions detected: {regressions}")
    else:
        print("[summary] no regressions detected")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline",
        required=True,
        help="JSON results from baseline run",
    )
    parser.add_argument(
        "--patched",
        required=True,
        help="JSON results from patched run",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    baseline = load_results(Path(args.baseline))
    patched = load_results(Path(args.patched))
    compare(baseline, patched)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
