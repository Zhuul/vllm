## Extras Testing Harness

Utilities in this directory wrap common test and benchmark flows without
touching upstream `tests/` or `benchmarks/` content.

- `test_matrix.yaml` defines named suites and the commands they execute.
- `run_tests.py` executes suites for a profile (`baseline` or `patched`) and
  writes structured JSON results under `extras/testing/results/`.
- `compare_results.py` diff-checks two result files to highlight regressions.

### Example

```bash
# Baseline run
python extras/testing/run_tests.py --profile baseline

# Patched run (after applying overlay)
python extras/testing/run_tests.py --profile patched

# Compare
python extras/testing/compare_results.py \
  --baseline extras/testing/results/20251103-120000-baseline.json \
  --patched extras/testing/results/20251103-121500-patched.json
```
