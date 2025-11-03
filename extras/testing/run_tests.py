#!/usr/bin/env python3
"""Curated test runner for vLLM extras workflows."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_MATRIX = BASE_DIR / "test_matrix.yaml"
RESULTS_DIR = BASE_DIR / "results"

MAX_OUTPUT_CHARS = 4000


def load_matrix(path: Path) -> Mapping[str, Any]:
    try:
        import yaml  # type: ignore
    except ImportError as exc:  # pragma: no cover
        raise SystemExit("PyYAML required. Install with 'pip install pyyaml'.") from exc

    if not path.exists():
        raise SystemExit(f"Test matrix not found: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, Mapping):
        raise SystemExit("Matrix root must be a mapping")
    return data


def collect_suites(matrix: Mapping[str, Any], profile: str, suites: Sequence[str] | None) -> List[str]:
    declared = matrix.get("profiles", {})
    default_order: Iterable[str]
    if isinstance(declared, Mapping) and profile in declared:
        payload = declared[profile]
        if isinstance(payload, Mapping):
            default_order = payload.get("suites", [])
        else:
            default_order = []
    else:
        default_order = []
    selected = list(suites or default_order or matrix.get("default_suites", []) or [])
    if not selected:
        selected = list((matrix.get("suites") or {}).keys())
    if not selected:
        raise SystemExit("No suites selected to run")
    return selected


def run_command(command: str, env: Mapping[str, str], workdir: Path | None, timeout: int | None) -> Dict[str, Any]:
    merged_env = dict(os.environ)
    merged_env.update({k: str(v) for k, v in env.items()})

    start = time.perf_counter()
    completed = subprocess.run(
        command,
        shell=True,
        executable="/bin/bash",
        cwd=str(workdir) if workdir else None,
        env=merged_env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    duration = time.perf_counter() - start

    def _tail(text: str) -> str:
        if len(text) <= MAX_OUTPUT_CHARS:
            return text
        return text[-MAX_OUTPUT_CHARS:]

    return {
        "returncode": completed.returncode,
        "duration_s": duration,
        "stdout": _tail(completed.stdout),
        "stderr": _tail(completed.stderr),
    }


def run_suite(suite_name: str, suite_cfg: Mapping[str, Any], profile: str) -> List[Dict[str, Any]]:
    commands = suite_cfg.get("commands")
    if not isinstance(commands, Sequence):
        raise SystemExit(f"Suite '{suite_name}' must contain a sequence of commands")

    results: List[Dict[str, Any]] = []
    for index, item in enumerate(commands):
        if not isinstance(item, Mapping):
            raise SystemExit(f"Suite '{suite_name}' command #{index} must be a mapping")

        name = item.get("name") or f"{suite_name}-{index}"
        command = item.get("cmd")
        if not isinstance(command, str):
            raise SystemExit(f"Suite '{suite_name}' command '{name}' missing 'cmd'")

        workdir = item.get("workdir")
        if workdir is not None and not isinstance(workdir, str):
            raise SystemExit(f"Suite '{suite_name}' command '{name}' has invalid workdir")
        workdir_path = Path(workdir).resolve() if workdir else None

        env = item.get("env") or {}
        if not isinstance(env, Mapping):
            raise SystemExit(f"Suite '{suite_name}' command '{name}' env must be a mapping")

        timeout = item.get("timeout")
        if timeout is not None:
            timeout = int(timeout)

        print(f"[suite:{suite_name}] running '{name}' -> {command}")
        start_ts = dt.datetime.utcnow().isoformat() + "Z"
        try:
            outcome = run_command(command, env, workdir_path, timeout)
            status = "passed" if outcome["returncode"] == 0 else "failed"
        except subprocess.TimeoutExpired:
            outcome = {
                "returncode": None,
                "duration_s": timeout,
                "stdout": "",
                "stderr": f"Command timed out after {timeout}s",
            }
            status = "timeout"

        record = {
            "profile": profile,
            "suite": suite_name,
            "name": name,
            "command": command,
            "timestamp": start_ts,
            "status": status,
            **outcome,
        }
        results.append(record)
        print(f"[suite:{suite_name}] {name} -> {status} ({outcome['duration_s']:.2f}s)")
    return results


def resolve_output_path(output: str | None, profile: str) -> Path:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    if output:
        path = Path(output)
        if path.is_dir():
            timestamp = dt.datetime.utcnow().strftime("%Y%m%d-%H%M%S")
            return path / f"{timestamp}-{profile}.json"
        return path
    timestamp = dt.datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    return RESULTS_DIR / f"{timestamp}-{profile}.json"


def write_results(path: Path, payload: Sequence[Mapping[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"[results] wrote {path}")


def summarise(results: Sequence[Mapping[str, Any]]) -> None:
    total = len(results)
    failures = sum(1 for item in results if item["status"] != "passed")
    print(f"[summary] total={total} failures={failures}")
    if failures:
        for item in results:
            if item["status"] == "passed":
                continue
            print(
                f"[summary] {item['suite']}::{item['name']} [{item['status']}] "
                f"rc={item.get('returncode')}"
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, help="profile name from test_matrix.yaml")
    parser.add_argument("--suite", action="append", help="suite to run (repeatable)")
    parser.add_argument("--matrix", default=str(DEFAULT_MATRIX), help="path to test matrix YAML")
    parser.add_argument("--output", help="path to write JSON results (file or directory)")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    matrix = load_matrix(Path(args.matrix))
    suites_cfg = matrix.get("suites")
    if not isinstance(suites_cfg, Mapping):
        raise SystemExit("Matrix missing 'suites' mapping")

    suites = collect_suites(matrix, args.profile, args.suite)

    results: List[Mapping[str, Any]] = []
    for suite in suites:
        cfg = suites_cfg.get(suite)
        if not isinstance(cfg, Mapping):
            raise SystemExit(f"Suite '{suite}' missing configuration")
        results.extend(run_suite(suite, cfg, args.profile))

    output_path = resolve_output_path(args.output, args.profile)
    write_results(output_path, results)
    summarise(results)
    return 0 if all(item["status"] == "passed" for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
