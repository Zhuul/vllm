# Extras Testing Harness

Utilities in this directory wrap common test and benchmark flows without
touching upstream `tests/` or `benchmarks/` content.

- `test_matrix.yaml` defines named suites and the commands they execute.
- `run_tests.py` executes suites for a profile (`baseline` or `patched`) and
  writes structured JSON results under `extras/testing/results/`.
- `compare_results.py` diff-checks two result files to highlight regressions.
- `env_smoke.py` captures a minimal runtime report for validating an image or
  container baseline before model-specific tests.
- `deepseek_smoke.py` runs a small offline DeepSeek generation check inside a
  prepared vLLM environment.
- `prime_model_cache.py` primes or verifies a local model cache before offline
  smoke runs.
- `run_container_smoke.py` launches one or more container images, runs a named
  suite inside each image, and can compare the resulting JSON outputs.

## Standard Smoke Baseline

The current smoke flow is intentionally close to the common baseline used for
model-serving validation:

- capture environment/runtime metadata first;
- resolve a locally cached model path before inference when offline mode is on;
- run deterministic short-prompt generation with low temperature;
- require non-empty, non-verbatim, minimum-length outputs;
- keep broader quality evaluation separate from smoke regression checks.

This keeps the harness generic enough for other models later, such as Qwen,
without tying the test logic to one model family.

## Suggested Split

- `image-validation` profile:
  verifies CUDA/runtime basics and then runs a small DeepSeek smoke check.
- `edit-mode` profile:
  keeps focus on editable vLLM behavior and patch-sensitive smoke coverage.

This separation keeps infrastructure drift distinct from regressions caused by
experimental patches.

## Example

```bash
# Baseline run
python extras/testing/run_tests.py --profile baseline

# Patched run (after applying overlay)
python extras/testing/run_tests.py --profile patched

# Compare
python extras/testing/compare_results.py \
  --baseline extras/testing/results/20251103-120000-baseline.json \
  --patched extras/testing/results/20251103-121500-patched.json

# Run a DeepSeek smoke suite in the default dev image.
python extras/testing/run_container_smoke.py

# Compare dev image against a control image.
python extras/testing/run_container_smoke.py \
  --image dev=vllm-dev:latest \
  --image control=my-control-image:latest

# Run the image-validation profile manually inside a prepared container.
python extras/testing/run_tests.py --profile image-validation

# Prime the default smoke model cache with network access once.
./extras/podman/run.ps1 -PrimeModelCache -AllowNetwork

# Run offline image validation. This now prepares the editable install
# automatically before running the profile.
./extras/podman/run.ps1 -ImageValidation

# Run the edit-mode profile with the same automatic editable-setup flow.
./extras/podman/run.ps1 -EditMode

# Run cache verification plus both validation profiles in one command.
# Add -AllowNetwork if you want the cache to be re-primed online first.
./extras/podman/run.ps1 -ValidateAll

# Run the edit-mode profile manually inside a prepared container.
python extras/testing/run_tests.py --profile edit-mode

# Prime a model cache once, then return to offline runs.
python extras/testing/prime_model_cache.py \
  --model deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B \
  --allow-network
```

## Reports

- `run_tests.py` now writes both a JSON result file and a readable `.txt`
  summary next to it.
- Per-command artifacts such as `env_smoke.py` and `deepseek_smoke.py` payloads
  are written under a sibling `*-artifacts/` directory.
