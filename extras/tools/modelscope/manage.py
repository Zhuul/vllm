#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""ModelScope helper CLI for vLLM development workflows."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
from datetime import datetime
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "model_profiles.yaml"
DEFAULT_MODELSCOPE_CACHE = Path.home() / ".cache" / "modelscope"
DEFAULT_HF_HOME = Path.home() / ".cache" / "hf"
RUNNER_FILENAME = "_modelscope_runner.py"
DEFAULT_KV_ROOT = Path.home() / "kvdata"
KV_CACHE_FILENAME = "kv_cache_scales.json"
MODEL_VOLUME_PREFIX = "model-"
KV_VOLUME_PREFIX = "kv-"

OFFLINE_ENV_DEFAULTS: dict[str, str] = {
    "VLLM_USE_MODELSCOPE": "True",
    "HF_HUB_OFFLINE": "1",
    "HF_DATASETS_OFFLINE": "1",
    "TRANSFORMERS_OFFLINE": "1",
    "TRANSFORMERS_NO_ADVISORY_WARNINGS": "1",
}


def _apply_offline_defaults(
    env: dict[str, str], *, cache_dir: Path | None = None
) -> None:
    for key, value in OFFLINE_ENV_DEFAULTS.items():
        env.setdefault(key, value)

    cache_value = env.get("MODELSCOPE_CACHE")
    if cache_value:
        cache_path = Path(cache_value).expanduser()
        cache_str = str(cache_path)
        env["MODELSCOPE_CACHE"] = cache_str
        env.setdefault("MODELSCOPE_HOME", cache_str)
    else:
        cache_path = (cache_dir or DEFAULT_MODELSCOPE_CACHE).expanduser()
        cache_str = str(cache_path)
        env["MODELSCOPE_CACHE"] = cache_str
        env["MODELSCOPE_HOME"] = cache_str

    hf_home = Path(env.setdefault("HF_HOME", str(DEFAULT_HF_HOME.expanduser())))
    env.setdefault("TRANSFORMERS_CACHE", str(hf_home / "transformers"))
    env.setdefault("HF_DATASETS_CACHE", str(hf_home / "datasets"))


def _resolve_model_root(base_dir: Path) -> Path:
    base_dir = base_dir.expanduser().resolve()
    if not base_dir.exists():
        return base_dir

    try:
        for name in ("config.json", "configuration.json", "model_index.json"):
            try:
                candidates = sorted(
                    base_dir.rglob(name),
                    key=lambda p: (len(p.parts), str(p)),
                )
            except Exception:
                candidates = []
            if not candidates:
                continue
            chosen = candidates[0].parent
            if chosen != base_dir:
                print(f"[kv-calibrate] nested model directory detected -> {chosen}")
            cfg_target = chosen / "config.json"
            if name != "config.json" and not cfg_target.exists():
                try:
                    content = candidates[0].read_text(encoding="utf-8")
                except Exception:
                    content = "{}"
                cfg_target.parent.mkdir(parents=True, exist_ok=True)
                cfg_target.write_text(content, encoding="utf-8")
                print(f"[kv-calibrate] mirrored {name} -> config.json")
            return chosen
    except Exception as exc:
        print(f"[kv-calibrate] warning: failed to resolve nested model dir ({exc})")

    return base_dir


def _normalize_model_id(model_id: str) -> str:
    return model_id.strip()


def _safe_model_key(model_id: str) -> str:
    normalized = _normalize_model_id(model_id)
    safe = "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in normalized)
    return safe


def _model_cache_root(model_id: str, base: Path | None = None) -> Path:
    base_dir = Path(base or DEFAULT_MODELSCOPE_CACHE)
    return base_dir / _safe_model_key(model_id)


def _kv_model_root(model_id: str, base: Path | None = None) -> Path:
    base_dir = Path(base or DEFAULT_KV_ROOT)
    return base_dir / _safe_model_key(model_id)


def _metadata_path(cache_root: Path) -> Path:
    return cache_root / ".modelscope-manage.json"


def _write_snapshot_metadata(cache_root: Path, model_id: str, snapshot_path: Path) -> None:
    payload = {
        "model_id": _normalize_model_id(model_id),
        "cache_root": str(cache_root),
        "snapshot_path": str(snapshot_path),
        "updated_at": datetime.utcnow().isoformat(timespec="seconds") + "Z",
    }
    cache_root.mkdir(parents=True, exist_ok=True)
    _metadata_path(cache_root).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def _read_snapshot_metadata(cache_root: Path) -> Mapping[str, object] | None:
    meta_file = _metadata_path(cache_root)
    if not meta_file.exists():
        return None
    try:
        return json.loads(meta_file.read_text(encoding="utf-8"))
    except Exception:
        return None


def _clean_cache_root(cache_root: Path) -> None:
    if not cache_root.exists():
        return
    if cache_root == cache_root.anchor:
        raise SystemExit(f"Refusing to remove root directory: {cache_root}")
    shutil.rmtree(cache_root, ignore_errors=True)


def _volume_name(prefix: str, model_id: str) -> str:
    safe = _safe_model_key(model_id)
    return f"{prefix}{safe}"


def _run_podman(args: Sequence[str]) -> tuple[bool, str]:
    podman = shutil.which("podman")
    if podman is None:
        return False, "podman CLI not found"
    proc = subprocess.run([podman, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        message = proc.stderr.strip() or proc.stdout.strip()
        return False, message
    return True, proc.stdout.strip()


def _ensure_podman_volume(name: str) -> None:
    ok, _ = _run_podman(["volume", "inspect", name])
    if ok:
        print(f"[volume] reuse existing Podman volume '{name}'")
        return
    ok, message = _run_podman(["volume", "create", name])
    if ok:
        print(f"[volume] created Podman volume '{name}'")
    else:
        print(f"[volume] warning: unable to ensure volume '{name}': {message}")


def _remove_podman_volume(name: str) -> None:
    ok, message = _run_podman(["volume", "inspect", name])
    if not ok:
        print(f"[volume] volume '{name}' not found (skip removal)")
        return
    ok, message = _run_podman(["volume", "rm", name])
    if ok:
        print(f"[volume] removed Podman volume '{name}'")
    else:
        print(f"[volume] warning: unable to remove volume '{name}': {message}")


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

    _apply_offline_defaults(env_data)

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
    cache_dir = cache_dir.expanduser().resolve()
    _ensure_dir(cache_dir)

    # Force ModelScope to operate entirely within the profile-specific cache.
    cache_str = str(cache_dir)
    os.environ["MODELSCOPE_CACHE"] = cache_str
    os.environ["MODELSCOPE_HOME"] = cache_str
    os.environ.setdefault("VLLM_USE_MODELSCOPE", "True")

    try:
        from modelscope import snapshot_download  # type: ignore
    except ImportError as exc:  # pragma: no cover - dependency guard
        raise SystemExit(
            "ModelScope is required. Install it with 'pip install modelscope'."
        ) from exc

    target = snapshot_download(model_id, cache_dir=str(cache_dir))
    if not target:
        raise SystemExit(f"ModelScope download returned empty path for {model_id}")
    raw_path = Path(target).resolve()
    model_path = _resolve_model_root(raw_path)
    if model_path != raw_path:
        print(f"[kv-calibrate] using nested model path {model_path}")
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
        print(f"[kv-calibrate] synthesized {tokenizer_cfg.name}")

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
        print(f"[kv-calibrate] synthesized {target.name}")

    _normalize_tokenizer_artifacts(model_dir)
    _sanitize_config_for_offline(model_dir)


def _normalize_tokenizer_artifacts(model_dir: Path) -> None:
    added_tokens = model_dir / "added_tokens.json"
    if added_tokens.exists():
        try:
            raw = json.loads(added_tokens.read_text(encoding="utf-8"))
        except Exception:
            raw = None
        if isinstance(raw, list):
            mapping = {
                token: idx for idx, token in enumerate(raw) if isinstance(token, str)
            }
            added_tokens.write_text(
                json.dumps(mapping, ensure_ascii=False), encoding="utf-8"
            )
            print("[kv-calibrate] normalized added_tokens.json to mapping form")

    tokenizer_cfg = model_dir / "tokenizer_config.json"
    if tokenizer_cfg.exists():
        try:
            cfg_data = json.loads(tokenizer_cfg.read_text(encoding="utf-8"))
        except Exception:
            cfg_data = {}
    else:
        cfg_data = {}

    if "tokenizer_file" not in cfg_data and (model_dir / "tokenizer.json").exists():
        cfg_data["tokenizer_file"] = "tokenizer.json"
        tokenizer_cfg.write_text(
            json.dumps(cfg_data, ensure_ascii=False), encoding="utf-8"
        )
        print("[kv-calibrate] updated tokenizer_config.json tokenizer_file entry")


def _sanitize_config_for_offline(model_dir: Path) -> None:
    config_path = model_dir / "config.json"
    if not config_path.exists():
        return
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:
        return

    changed = False
    sentinel_keys = ("base_model_name_or_path", "_name_or_path")
    for key in sentinel_keys:
        val = data.get(key)
        if isinstance(val, str) and val.strip():
            if "meta-llama" in val or val.startswith("hf://") or "/" in val:
                data[key] = "."
                changed = True

    auto_map = data.get("auto_map")
    if isinstance(auto_map, dict):
        for map_key, map_val in list(auto_map.items()):
            if isinstance(map_val, str) and "meta-llama" in map_val:
                auto_map[map_key] = map_val.replace("meta-llama/Meta-Llama-3-8B-Instruct", ".")
                changed = True

    if changed:
        config_path.write_text(
            json.dumps(data, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )


def _ensure_llm_compressor(repo_path: Path) -> None:
    if repo_path.exists():
        return
    repo_path.parent.mkdir(parents=True, exist_ok=True)
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


def _ensure_llm_compressor_runner(repo_path: Path) -> Path:
    runner_path = repo_path / RUNNER_FILENAME
    if runner_path.exists():
        return runner_path

    runner_source = """#!/usr/bin/env python3
import functools
import json
import os
import runpy
import sys
from pathlib import Path

MODEL_DIR = os.environ.get("MODEL_DIR")
MODEL_ID_MS = os.environ.get("MODEL_ID_MS")
CALIB_DATA_PATH = os.environ.get("CALIB_DATA_PATH")
SEQ_LEN = int(os.environ.get("KV_CALIB_SEQ_LEN", "0") or 0)
CALIB_SAMPLES = int(os.environ.get("KV_CALIB_SAMPLES", "0") or 0)


def _resolve_identifier(identifier):
    if not isinstance(identifier, str):
        return identifier
    normalized = identifier.strip()
    if MODEL_DIR and os.path.isdir(MODEL_DIR):
        if normalized == MODEL_DIR:
            return MODEL_DIR
        if MODEL_ID_MS:
            ms_norm = MODEL_ID_MS.strip().rstrip("/")
            target_norm = normalized.removeprefix("hf://").rstrip("/")
            if target_norm == ms_norm:
                return MODEL_DIR
    return identifier


def _patch_huggingface_hub() -> None:
    try:
        from huggingface_hub.utils import _validators  # type: ignore[attr-defined]
        from huggingface_hub import file_download  # type: ignore
    except Exception:
        return

    validate_repo_id = getattr(_validators, "validate_repo_id", None)
    if validate_repo_id is not None:

        def _validate_repo_id(repo_id: str, *args, **kwargs):  # type: ignore[override]
            resolved = _resolve_identifier(repo_id)
            if isinstance(resolved, str) and os.path.isdir(resolved):
                return repo_id
            return validate_repo_id(repo_id, *args, **kwargs)  # type: ignore[misc]

        _validators.validate_repo_id = _validate_repo_id  # type: ignore[attr-defined]

    cached_files = getattr(file_download, "cached_files", None)
    if cached_files is not None:
        original_cached_files = cached_files

        def _cached_files(path_or_repo_id, filenames=None, **kwargs):  # type: ignore[override]
            resolved = _resolve_identifier(path_or_repo_id)
            if isinstance(resolved, str) and os.path.isdir(resolved) and filenames:
                resolved_files = []
                for name in filenames:
                    candidate = os.path.join(resolved, name)
                    if os.path.exists(candidate):
                        resolved_files.append(candidate)
                if resolved_files:
                    return resolved_files
            return original_cached_files(path_or_repo_id, filenames=filenames, **kwargs)  # type: ignore[misc]

        file_download.cached_files = _cached_files  # type: ignore[attr-defined]

    hf_download = getattr(file_download, "hf_hub_download", None)
    if hf_download is not None:
        original_hf_download = hf_download

        def _hf_hub_download(path_or_repo_id, filename=None, **kwargs):  # type: ignore[override]
            resolved = _resolve_identifier(path_or_repo_id)
            if isinstance(resolved, str) and os.path.isdir(resolved) and filename:
                candidate = os.path.join(resolved, filename)
                if os.path.exists(candidate):
                    return candidate
            if MODEL_DIR and os.path.isdir(MODEL_DIR):
                kwargs.setdefault("local_files_only", True)
            return original_hf_download(path_or_repo_id, filename=filename, **kwargs)  # type: ignore[misc]

        file_download.hf_hub_download = _hf_hub_download  # type: ignore[attr-defined]


def _patch_transformers() -> None:
    try:
        from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer  # type: ignore
    except Exception:
        return

    if not (MODEL_DIR and os.path.isdir(MODEL_DIR)):
        return

    def _wrap(cm, *, is_tokenizer: bool = False):  # type: ignore
        func = cm.__func__  # type: ignore[attr-defined]

        @functools.wraps(func)  # type: ignore[misc]
        def wrapper(cls, pretrained_model_name_or_path=None, *args, **kwargs):  # type: ignore[override]
            resolved = _resolve_identifier(pretrained_model_name_or_path)  # type: ignore[arg-type]
            if not (isinstance(resolved, str) and os.path.isdir(resolved)):
                resolved = MODEL_DIR
            resolved_path = Path(resolved)
            kwargs.setdefault("local_files_only", True)
            kwargs.setdefault("trust_remote_code", True)
            if (
                is_tokenizer
                and resolved_path is not None
                and (resolved_path / "tokenizer.json").exists()
            ):
                kwargs.setdefault(
                    "tokenizer_file", str(resolved_path / "tokenizer.json")
                )
            return func(cls, resolved, *args, **kwargs)

        return classmethod(wrapper)

    AutoConfig.from_pretrained = _wrap(AutoConfig.from_pretrained)
    AutoModelForCausalLM.from_pretrained = _wrap(
        AutoModelForCausalLM.from_pretrained
    )
    AutoTokenizer.from_pretrained = _wrap(
        AutoTokenizer.from_pretrained, is_tokenizer=True
    )


def _patch_datasets() -> None:
    if not (CALIB_DATA_PATH and os.path.exists(CALIB_DATA_PATH)):
        return
    try:
        import datasets  # type: ignore
    except Exception:
        return

    original_load_dataset = datasets.load_dataset

    def _load_dataset(path, *args, **kwargs):  # type: ignore[override]
        if os.path.exists(CALIB_DATA_PATH):
            with open(CALIB_DATA_PATH, "r", encoding="utf-8") as handle:
                rows = []
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        payload = {"text": line}
                    text = payload.get("text") or ""
                    if not isinstance(text, str):
                        text = str(text)
                rows.append(
                    {
                        "messages": [
                            {
                                "role": "user",
                                "content": text,
                            }
                        ]
                    }
                )
            if not rows:
                raise SystemExit(f"Calibration dataset empty: {CALIB_DATA_PATH}")
            if CALIB_SAMPLES > 0 and len(rows) < CALIB_SAMPLES:
                repeats = (CALIB_SAMPLES + len(rows) - 1) // len(rows)
                rows = (rows * repeats)[:CALIB_SAMPLES]
            dataset = datasets.Dataset.from_list(rows)
            if SEQ_LEN > 0:
                dataset = dataset
            return dataset
        return original_load_dataset(path, *args, **kwargs)

    datasets.load_dataset = _load_dataset


def _extract_custom_args(argv: list[str]) -> list[str]:
    mapping = {
        "--model": "MODEL_DIR",
        "--output": "KV_CALIB_OUTPUT",
        "--seq-len": "KV_CALIB_SEQ_LEN",
        "--calib-data": "CALIB_DATA_PATH",
    }
    bool_flags = {"--kv-only": "KV_CALIB_KV_ONLY"}

    result: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in mapping and i + 1 < len(argv):
            os.environ[mapping[arg]] = argv[i + 1]
            i += 2
            continue
        if arg in bool_flags:
            value = "true"
            if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
                value = argv[i + 1]
                i += 1
            os.environ[bool_flags[arg]] = value
            i += 1
            continue
        result.append(arg)
        i += 1
    return result


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: _modelscope_runner.py <script> [args...]")
        sys.exit(1)
    target = sys.argv[1]
    if not os.path.isabs(target):
        target = os.path.abspath(target)
    if not os.path.exists(target):
        raise SystemExit(f"Target script not found: {target}")

    remaining_args = _extract_custom_args(sys.argv[2:])
    sys.argv = [target] + remaining_args
    _patch_huggingface_hub()
    _patch_transformers()
    _patch_datasets()
    runpy.run_path(target, run_name="__main__")


if __name__ == "__main__":
    main()
"""
    runner_path.write_text(runner_source, encoding="utf-8")
    runner_path.chmod(0o755)
    return runner_path


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
        "accelerate>=0.32,<1",
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


def _locate_snapshot(cache_root: Path) -> Path | None:
    metadata = _read_snapshot_metadata(cache_root)
    if metadata:
        snap = metadata.get("snapshot_path")
        if isinstance(snap, str):
            candidate = Path(snap).expanduser().resolve()
            if candidate.exists():
                return candidate

    if not cache_root.exists():
        return None

    candidates = sorted(
        (path.parent for path in cache_root.rglob("config.json")),
        key=lambda p: (len(p.parts), str(p)),
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def _print_snapshot_info(model_id: str, cache_root: Path, snapshot_dir: Path | None) -> None:
    print(f"Model ID    : {model_id}")
    print(f"Cache root  : {cache_root}")
    if snapshot_dir is None:
        print("Snapshot    : <missing>")
        return
    print(f"Snapshot    : {snapshot_dir}")
    meta = _read_snapshot_metadata(cache_root)
    if meta and meta.get("updated_at"):
        print(f"Updated at  : {meta['updated_at']}")
    try:
        size_bytes = sum(p.stat().st_size for p in snapshot_dir.rglob("*") if p.is_file())
        size_mb = size_bytes / (1024 * 1024)
        print(f"Disk usage  : {size_mb:.2f} MB")
    except Exception:
        pass
    cfg = snapshot_dir / "config.json"
    if cfg.exists():
        try:
            payload = json.loads(cfg.read_text(encoding="utf-8"))
            model_type = payload.get("model_type", "<unknown>")
            arch = payload.get("architectures")
            if isinstance(arch, list):
                arch = ", ".join(str(item) for item in arch)
        except Exception:
            model_type = "<unknown>"
            arch = None
        print(f"Model type  : {model_type}")
        if arch:
            print(f"Architectures: {arch}")


def handle_install_model(args: argparse.Namespace) -> int:
    model_id = _normalize_model_id(args.model_id)
    cache_root = Path(args.cache_dir or _model_cache_root(model_id)).expanduser().resolve()
    with_volume = not getattr(args, "no_volume", False)
    with_kv_volume = not getattr(args, "no_kv_volume", False)
    if with_volume:
        _ensure_podman_volume(_volume_name(MODEL_VOLUME_PREFIX, model_id))
    if with_kv_volume:
        _ensure_podman_volume(_volume_name(KV_VOLUME_PREFIX, model_id))
    model_dir = _download_model(model_id, cache_root)
    _synthesize_transformer_files(model_dir)
    _write_snapshot_metadata(cache_root, model_id, model_dir)
    if with_kv_volume:
        kv_root = _kv_model_root(model_id)
        kv_root.mkdir(parents=True, exist_ok=True)
    print(f"[install] snapshot ready -> {model_dir}")
    if with_volume:
        print(
            f"[install] podman mount suggestion: -v {_volume_name(MODEL_VOLUME_PREFIX, model_id)}:{cache_root}:U"
        )
    if with_kv_volume:
        kv_root = _kv_model_root(model_id)
        print(
            f"[install] podman mount suggestion: -v {_volume_name(KV_VOLUME_PREFIX, model_id)}:{kv_root}:U"
        )
    return 0


def handle_model_info(args: argparse.Namespace) -> int:
    model_id = _normalize_model_id(args.model_id)
    cache_root = Path(args.cache_dir or _model_cache_root(model_id)).expanduser().resolve()
    snapshot_dir = _locate_snapshot(cache_root)
    if snapshot_dir is None:
        print(f"[info] snapshot missing for {model_id} in {cache_root}")
        return 1
    _print_snapshot_info(model_id, cache_root, snapshot_dir)
    return 0


def handle_model_check(args: argparse.Namespace) -> int:
    model_id = _normalize_model_id(args.model_id)
    cache_root = Path(args.cache_dir or _model_cache_root(model_id)).expanduser().resolve()
    snapshot_dir = _locate_snapshot(cache_root)
    if snapshot_dir is None:
        print(f"[check] snapshot missing for {model_id}")
        return 1

    _print_snapshot_info(model_id, cache_root, snapshot_dir)

    try:
        from transformers import AutoConfig, AutoTokenizer  # type: ignore
    except ImportError as exc:
        raise SystemExit("Transformers is required for 'check'. Install it inside the container.") from exc

    try:
        cfg = AutoConfig.from_pretrained(snapshot_dir, trust_remote_code=True, local_files_only=True)
        print(f"[check] AutoConfig OK -> {cfg.__class__.__name__}")
        tok = AutoTokenizer.from_pretrained(snapshot_dir, trust_remote_code=True, local_files_only=True)
        added = len(getattr(tok, "added_tokens_encoder", {}) or {})
        print(f"[check] AutoTokenizer OK -> {tok.__class__.__name__} (added tokens: {added})")
    except Exception as exc:  # pylint: disable=broad-except
        raise SystemExit(f"[check] failed to load snapshot: {exc}") from exc
    return 0


def handle_model_delete(args: argparse.Namespace) -> int:
    model_id = _normalize_model_id(args.model_id)
    cache_root = Path(args.cache_dir or _model_cache_root(model_id)).expanduser().resolve()
    snapshot_dir = _locate_snapshot(cache_root)
    if not cache_root.exists():
        print(f"[delete] cache root missing -> {cache_root}")
    else:
        if not args.force:
            confirm = input(f"Remove snapshot at {cache_root}? [y/N]: ").strip().lower()
            if confirm not in ("y", "yes"):
                print("[delete] cancelled")
                return 1
        _clean_cache_root(cache_root)
        print(f"[delete] removed cache root -> {cache_root}")

    meta = _metadata_path(cache_root)
    if meta.exists():
        meta.unlink()

    if args.remove_volume:
        _remove_podman_volume(_volume_name(MODEL_VOLUME_PREFIX, model_id))
    if args.remove_kv:
        kv_root = _kv_model_root(model_id)
        if kv_root.exists():
            _clean_cache_root(kv_root)
            print(f"[delete] removed kv data -> {kv_root}")
        _remove_podman_volume(_volume_name(KV_VOLUME_PREFIX, model_id))
    return 0
def handle_kv_calibrate(args: argparse.Namespace) -> int:
    if not getattr(args, "profile", None) and not getattr(args, "model", None):
        raise SystemExit("kv-calibrate requires --profile or --model")

    volumes_enabled = not getattr(args, "no_volumes", False)

    if getattr(args, "profile", None):
        profile = ensure_profile(args.profile)
        section = profile.get("kv_calibration")
        if not isinstance(section, Mapping):
            raise SystemExit(f"Profile '{args.profile}' missing 'kv_calibration' mapping")
        model_id = _normalize_model_id(str(section.get("model_id", "")))
        if not model_id:
            raise SystemExit("kv_calibration.model_id must be provided")
        cache_default = Path.home() / ".cache" / "modelscope"
        cache_dir = Path(
            section.get("cache_dir", os.environ.get("MODELSCOPE_CACHE", str(cache_default)))
        ).expanduser().resolve()
        quant_args = section.get("quant_args", [])
    else:
        model_id = _normalize_model_id(args.model)
        cache_dir = Path(args.cache_dir or _model_cache_root(model_id)).expanduser().resolve()
        output_default = _kv_model_root(model_id) / KV_CACHE_FILENAME
        calib_default = _kv_model_root(model_id) / "calib" / "snippets.jsonl"
        section = {
            "model_id": model_id,
            "output": str(Path(args.output or output_default).expanduser().resolve()),
            "calib_data": str(Path(args.calib_data or calib_default).expanduser().resolve()),
            "samples": args.samples or 512,
            "seq_len": args.seq_len or 4096,
            "dataset_prompt": args.dataset_prompt
            or "Calibration sample {i}. Short text for KV scales.",
            "cache_dir": str(cache_dir),
            "llm_compressor_repo": str(
                Path(args.llm_compressor_repo or (Path.home() / ".local" / "share" / "llm-compressor"))
                .expanduser()
                .resolve()
            ),
            "quantization_script": args.quant_script
            or "examples/quantization_non_uniform/quantization_multiple_modifiers.py",
            "quant_args": list(args.quant_arg or []),
        }
        quant_args = section["quant_args"]

    if volumes_enabled:
        _ensure_podman_volume(_volume_name(MODEL_VOLUME_PREFIX, model_id))
        _ensure_podman_volume(_volume_name(KV_VOLUME_PREFIX, model_id))

    output = Path(section.get("output", str(DEFAULT_KV_ROOT / KV_CACHE_FILENAME))).expanduser().resolve()
    _ensure_dir(output.parent)
    if output.exists() and not args.force:
        print(f"[kv-calibrate] reuse existing scales -> {output}")
        return 0

    calib_path = Path(section.get("calib_data", str(DEFAULT_KV_ROOT / "calib" / "snippets.jsonl"))).expanduser().resolve()
    if not calib_path.exists():
        samples = int(section.get("samples", 512))
        template = str(
            section.get(
                "dataset_prompt", "Calibration sample {i}. Short text for KV scales."
            )
        )
        _write_default_calib(calib_path, samples, template)

    cache_dir = Path(section.get("cache_dir", str(DEFAULT_MODELSCOPE_CACHE))).expanduser().resolve()
    model_dir = _download_model(model_id, cache_dir)
    _synthesize_transformer_files(model_dir)
    _write_snapshot_metadata(cache_dir, model_id, model_dir)

    repo_path = Path(section.get("llm_compressor_repo", str(Path.home() / ".local" / "share" / "llm-compressor"))).resolve()
    _ensure_llm_compressor(repo_path)
    runner_path = _ensure_llm_compressor_runner(repo_path)

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

    quant_args_list: list[str] = []
    if quant_args:
        if not isinstance(quant_args, Sequence):
            raise SystemExit("kv_calibration.quant_args must be a sequence")
        for item in quant_args:
            if not isinstance(item, str):
                raise SystemExit("kv_calibration.quant_args entries must be strings")
            quant_args_list.append(item)

    env = dict(os.environ)
    cache_str = str(cache_dir)
    env["MODELSCOPE_CACHE"] = cache_str
    env["MODELSCOPE_HOME"] = cache_str
    _apply_offline_defaults(env, cache_dir=cache_dir)
    for key in ("HF_HOME", "TRANSFORMERS_CACHE", "HF_DATASETS_CACHE"):
        try:
            _ensure_dir(Path(env[key]))
        except Exception:
            continue
    env.setdefault("PYTHONPATH", str(repo_path / "src"))
    env.setdefault("MODEL_ID_MS", model_id)
    env["MODEL_DIR"] = str(model_dir)
    env["CALIB_DATA_PATH"] = str(calib_path)
    env["KV_CALIB_SEQ_LEN"] = str(seq_len)
    env["KV_CALIB_SAMPLES"] = str(section.get("samples", 512))

    cmd = [
        "python3",
        str(runner_path),
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
    ] + quant_args_list

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

    install = sub.add_parser("install", help="Download a ModelScope snapshot")
    install.add_argument("model_id", help="ModelScope model identifier (e.g. org/name)")
    install.add_argument(
        "--cache-dir",
        help="Custom cache root (defaults to ~/.cache/modelscope/<model>)",
    )
    install.add_argument(
        "--no-volume",
        action="store_true",
        help="Do not create a Podman volume for this model",
    )
    install.add_argument(
        "--no-kv-volume",
        action="store_true",
        help="Do not create a Podman volume for calibrated KV data",
    )
    install.set_defaults(func=handle_install_model)

    info = sub.add_parser("info", help="Show snapshot details for a model")
    info.add_argument("model_id", help="ModelScope model identifier")
    info.add_argument(
        "--cache-dir",
        help="Custom cache root (defaults to ~/.cache/modelscope/<model>)",
    )
    info.set_defaults(func=handle_model_info)

    check = sub.add_parser("check", help="Validate local snapshot files")
    check.add_argument("model_id", help="ModelScope model identifier")
    check.add_argument(
        "--cache-dir",
        help="Custom cache root (defaults to ~/.cache/modelscope/<model>)",
    )
    check.set_defaults(func=handle_model_check)

    delete = sub.add_parser("delete", help="Remove a local snapshot and volumes")
    delete.add_argument("model_id", help="ModelScope model identifier")
    delete.add_argument(
        "--cache-dir",
        help="Custom cache root (defaults to ~/.cache/modelscope/<model>)",
    )
    delete.add_argument(
        "--force",
        action="store_true",
        help="Remove without interactive confirmation",
    )
    delete.add_argument(
        "--remove-volume",
        action="store_true",
        help="Remove associated Podman cache volume",
    )
    delete.add_argument(
        "--remove-kv",
        action="store_true",
        help="Remove KV data and associated volume",
    )
    delete.set_defaults(func=handle_model_delete)

    kv = sub.add_parser("kv-calibrate", help="Generate KV cache scales for a profile")
    kv.add_argument(
        "--profile",
        help="Profile name from model_profiles.yaml (optional when --model is used)",
    )
    kv.add_argument(
        "--model",
        help="ModelScope identifier used for ad-hoc calibration",
    )
    kv.add_argument(
        "--cache-dir",
        help="Override cache directory for the snapshot",
    )
    kv.add_argument(
        "--output",
        help="Path to write KV scales (defaults to ~/kvdata/<model>/kv_cache_scales.json)",
    )
    kv.add_argument(
        "--calib-data",
        help="Path to calibration JSONL (defaults to ~/kvdata/<model>/calib/snippets.jsonl)",
    )
    kv.add_argument(
        "--samples",
        type=int,
        help="Number of calibration samples (defaults to profile or 512)",
    )
    kv.add_argument(
        "--seq-len",
        type=int,
        help="Sequence length for calibration (defaults to profile or 4096)",
    )
    kv.add_argument(
        "--dataset-prompt",
        help="Template for synthesized calibration data",
    )
    kv.add_argument(
        "--quant-script",
        help="Relative path to the llm-compressor quantization script",
    )
    kv.add_argument(
        "--quant-arg",
        action="append",
        default=[],
        help="Additional argument passed to the quantization script (repeatable)",
    )
    kv.add_argument(
        "--llm-compressor-repo",
        help="Path to the llm-compressor repository checkout",
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
    kv.add_argument(
        "--no-volumes",
        action="store_true",
        help="Do not create Podman volumes automatically",
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
