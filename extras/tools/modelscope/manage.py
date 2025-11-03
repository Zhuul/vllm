#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""ModelScope helper CLI for vLLM development workflows."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "model_profiles.yaml"


def _load_yaml() -> Mapping[str, object]:
    try:
        import yaml  # type: ignore
    except ImportError as exc:  # pragma: no cover - dependency guard
        raise SystemExit(
            "PyYAML is required. Install it with 'pip install pyyaml'."
        ) from exc

    if not CONFIG_PATH.exists():
        raise SystemExit(f"Config not found: {CONFIG_PATH}")

    data = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, Mapping):
        raise SystemExit(f"Invalid config root in {CONFIG_PATH}")
    return data


def load_profiles() -> Mapping[str, Mapping[str, object]]:
    raw = _load_yaml()
    profiles = raw.get("profiles")
    if not isinstance(profiles, Mapping):
        raise SystemExit(f"'profiles' section missing in {CONFIG_PATH}")
    output: dict[str, Mapping[str, object]] = {}
    for name, payload in profiles.items():
        if not isinstance(payload, Mapping):
            raise SystemExit(f"Profile '{name}' payload must be a mapping")
        output[str(name)] = payload  # ensure str keys
    return output


def ensure_profile(name: str) -> Mapping[str, object]:
    profiles = load_profiles()
    if name not in profiles:
        options = ", ".join(sorted(profiles))
        raise SystemExit(f"Unknown profile '{name}'. Available: {options}")
    return profiles[name]


def shlex_join(cmd: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in cmd)


def apply_env(base: Mapping[str, str], overrides: Iterable[str]) -> Mapping[str, str]:
    env = dict(os.environ)
    env.update({k: str(v) for k, v in base.items()})
    for item in overrides:
        if "=" not in item:
            raise SystemExit(f"Invalid env override '{item}', expected KEY=VALUE")
        key, value = item.split("=", 1)
        if not key:
            raise SystemExit(f"Invalid env override '{item}', missing key")
        env[key] = value
    return env


def run_subprocess(cmd: Sequence[str], **kwargs) -> None:
    print(f"[exec] {shlex_join(cmd)}")
    subprocess.run(cmd, check=True, **kwargs)


# ------------------------------
# serve sub-command
# ------------------------------


def handle_serve(args: argparse.Namespace) -> int:
    profile = ensure_profile(args.profile)
    serve_section = profile.get("serve", {})
    if not isinstance(serve_section, Mapping):
        raise SystemExit(f"Profile '{args.profile}' missing 'serve' mapping")

    entrypoint = serve_section.get(
        "entrypoint", "python -m vllm.entrypoints.openai.api_server"
    )
    if not isinstance(entrypoint, str):
        raise SystemExit("serve.entrypoint must be a string")

    try:
        cmd: list[str] = shlex.split(entrypoint)
    except ValueError as exc:
        raise SystemExit(f"Failed to parse entrypoint: {exc}") from exc

    serve_args = serve_section.get("args", [])
    if serve_args:
        if not isinstance(serve_args, Sequence):
            raise SystemExit("serve.args must be a sequence")
        for item in serve_args:
            if not isinstance(item, str):
                raise SystemExit("serve.args entries must be strings")
            cmd.extend(shlex.split(item))

    for extra in args.extra_arg:
        cmd.extend(shlex.split(extra))

    env_data: dict[str, str] = {}
    for block in (profile.get("env"), serve_section.get("env")):
        if not block:
            continue
        if not isinstance(block, Mapping):
            raise SystemExit("serve.env/profile.env must be mappings")
        env_data.update({str(k): str(v) for k, v in block.items()})

    env = apply_env(env_data, args.env or [])

    if args.print_command or args.dry_run:
        print(shlex_join(cmd))
    if args.dry_run:
        return 0

    run_subprocess(cmd, env=env)
    return 0


# ------------------------------
# kv-calibrate sub-command
# ------------------------------


def _ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def _write_default_calib(calib_path: Path, samples: int, template: str) -> None:
    _ensure_dir(calib_path.parent)
    with calib_path.open("w", encoding="utf-8") as handle:
        for idx in range(samples):
            payload = {"text": template.format(i=idx)}
            handle.write(json.dumps(payload, ensure_ascii=False))
            handle.write("\n")
    print(f"[kv-calibrate] wrote calibration set -> {calib_path}")


def _download_model(model_id: str, cache_dir: Path) -> Path:
    try:
        from modelscope import snapshot_download  # type: ignore
    except ImportError as exc:  # pragma: no cover - dependency guard
        raise SystemExit(
            "ModelScope is required. Install it with 'pip install modelscope'."
        ) from exc

    cache_dir = cache_dir.expanduser().resolve()
    _ensure_dir(cache_dir)
    target = snapshot_download(model_id, cache_dir=str(cache_dir))
    if not target:
        raise SystemExit(f"ModelScope download returned empty path for {model_id}")
    model_path = Path(target).resolve()
    print(f"[kv-calibrate] using model path {model_path}")
    return model_path


def _synthesize_transformer_files(model_dir: Path) -> None:
    import glob

    cfg = model_dir / "config.json"
    if not cfg.exists():
        picked = None
        for candidate in sorted(glob.glob(str(model_dir / "*.json"))):
            try:
                with open(candidate, encoding="utf-8") as handle:
                    payload = json.load(handle)
            except Exception:
                continue
            if isinstance(payload, dict) and (
                "model_type" in payload or "architectures" in payload
            ):
                picked = payload
                break
        if picked is None:
            picked = {}
        _ensure_dir(cfg.parent)
        cfg.write_text(json.dumps(picked, ensure_ascii=False), encoding="utf-8")
        print(f"[kv-calibrate] synthesized {cfg.name}")

    tokenizer_cfg = model_dir / "tokenizer_config.json"
    if not tokenizer_cfg.exists():
        payload = {}
        if (model_dir / "tokenizer.json").exists():
            payload["tokenizer_file"] = "tokenizer.json"
        elif (model_dir / "tokenizer.model").exists():
            payload["model_max_length"] = 32768
        tokenizer_cfg.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )

    for name in (
        "special_tokens_map.json",
        "generation_config.json",
        "preprocessor_config.json",
        "added_tokens.json",
    ):
        target = model_dir / name
        if target.exists():
            continue
        default_obj = [] if "added_tokens" in name else {}
        target.write_text(
            json.dumps(default_obj, ensure_ascii=False),
            encoding="utf-8",
        )


def _ensure_llm_compressor(repo_path: Path) -> None:
    if repo_path.exists():
        return
    print(f"[kv-calibrate] cloning llm-compressor into {repo_path}")
    run_subprocess(
        [
            "git",
            "clone",
            "--depth",
            "1",
            "https://github.com/vllm-project/llm-compressor",
            str(repo_path),
        ]
    )


def _install_llm_compressor_deps(repo_path: Path) -> None:
    uninstall_cmd = ["python3", "-m", "pip", "uninstall", "-y", "compressed-tensors"]
    subprocess.run(uninstall_cmd, check=False)

    install_cmd = [
        "python3",
        "-m",
        "pip",
        "install",
        "--no-cache-dir",
        "-q",
        "--upgrade",
        "--pre",
        "loguru>=0.7,<1",
        "datasets>=4.0.0,<5",
        "compressed-tensors>=0.12.3a2,<0.13",
    ]
    run_subprocess(install_cmd)

    editable_cmd = [
        "python3",
        "-m",
        "pip",
        "install",
        "--no-cache-dir",
        "-q",
        "--no-deps",
        "-e",
        str(repo_path),
    ]
    run_subprocess(editable_cmd)

    check_code = "\n".join(
        [
            "import compressed_tensors",
            "import datasets",
            "print('[deps] compressed_tensors =', compressed_tensors.__version__)",
            "print('[deps] datasets           =', datasets.__version__)",
        ]
    )
    check_cmd = ["python3", "-c", check_code]
    run_subprocess(check_cmd)


def handle_kv_calibrate(args: argparse.Namespace) -> int:
    profile = ensure_profile(args.profile)
    section = profile.get("kv_calibration")
    if not isinstance(section, Mapping):
        message = f"Profile '{args.profile}' missing 'kv_calibration' mapping"
        raise SystemExit(message)

    model_id = section.get("model_id")
    if not isinstance(model_id, str):
        raise SystemExit("kv_calibration.model_id must be provided")

    default_output = Path.home() / "kvdata" / "kv_cache_scales.json"
    output = Path(section.get("output", str(default_output))).resolve()
    _ensure_dir(output.parent)
    if output.exists() and not args.force:
        print(f"[kv-calibrate] reuse existing scales -> {output}")
        return 0

    default_calib = Path.home() / "kvdata" / "calib" / "snippets.jsonl"
    calib_path = Path(section.get("calib_data", str(default_calib))).resolve()
    if not calib_path.exists():
        samples = int(section.get("samples", 128))
        template = str(
            section.get(
                "dataset_prompt", "Calibration sample {i}. Short text for KV scales."
            )
        )
        _write_default_calib(calib_path, samples, template)

    cache_default = Path.home() / ".cache" / "modelscope"
    cache_dir = Path(
        section.get("cache_dir", os.environ.get("MODELSCOPE_CACHE", str(cache_default)))
    )
    model_dir = _download_model(model_id, cache_dir)
    _synthesize_transformer_files(model_dir)

    repo_path = Path(
        section.get("llm_compressor_repo", "/opt/llm-compressor")
    ).resolve()
    _ensure_llm_compressor(repo_path)

    if not args.skip_deps:
        _install_llm_compressor_deps(repo_path)

    seq_len = int(section.get("seq_len", 4096))
    quant_script_rel = section.get(
        "quantization_script",
        "examples/quantization_non_uniform/quantization_multiple_modifiers.py",
    )
    quant_script = (repo_path / quant_script_rel).resolve()
    if not quant_script.exists():
        raise SystemExit(f"Quantization script not found: {quant_script}")

    quant_args = section.get("quant_args", [])
    if quant_args:
        if not isinstance(quant_args, Sequence):
            raise SystemExit("kv_calibration.quant_args must be a sequence")
        for item in quant_args:
            if not isinstance(item, str):
                raise SystemExit("kv_calibration.quant_args entries must be strings")
    else:
        quant_args = []

    env = dict(os.environ)
    env.setdefault("PYTHONPATH", str(repo_path / "src"))

    cmd = [
        "python3",
        str(quant_script),
        "--model",
        str(model_dir),
        "--output",
        str(output),
        "--kv-only",
        "true",
        "--seq-len",
        str(seq_len),
        "--calib-data",
        str(calib_path),
    ] + list(quant_args)

    run_subprocess(cmd, env=env)
    print(f"[kv-calibrate] completed -> {output}")
    return 0


# ------------------------------
# Entry point
# ------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="Launch vLLM API for a profile")
    serve.add_argument(
        "--profile",
        required=True,
        help="Profile name from model_profiles.yaml",
    )
    serve.add_argument(
        "--print-command",
        action="store_true",
        help="Print command before execution",
    )
    serve.add_argument(
        "--dry-run",
        action="store_true",
        help="Only print command and exit",
    )
    serve.add_argument(
        "--extra-arg",
        action="append",
        default=[],
        help="Additional CLI argument (repeatable). Parsed with shlex.",
    )
    serve.add_argument(
        "--env",
        action="append",
        default=[],
        help="Additional environment variable KEY=VALUE (repeatable).",
    )
    serve.set_defaults(func=handle_serve)

    kv = sub.add_parser("kv-calibrate", help="Generate KV cache scales for a profile")
    kv.add_argument(
        "--profile",
        required=True,
        help="Profile name from model_profiles.yaml",
    )
    kv.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing output file",
    )
    kv.add_argument(
        "--skip-deps",
        action="store_true",
        help="Skip pip dependency installation for llm-compressor",
    )
    kv.set_defaults(func=handle_kv_calibrate)

    sub.add_parser(
        "list",
        help="List available profiles",
    ).set_defaults(func=handle_list)

    return parser


def handle_list(args: argparse.Namespace) -> int:
    profiles = load_profiles()
    for name, payload in sorted(profiles.items()):
        summary = payload.get("description", "")
        print(f"{name}: {summary}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    func = getattr(args, "func", None)
    if func is None:
        parser.print_help()
        return 1
    return func(args)


if __name__ == "__main__":
    sys.exit(main())
