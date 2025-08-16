# Testing and benchmarking harness

- Define a matrix of models/environments in `test_matrix.yaml`.
- Run via `python extras/testing/run_tests.py --output-dir extras/testing/results/$(date +%F_%H-%M)`.
- Store results in `results/` with timestamps for regression tracking.

This scaffolding is intentionally minimal; models and benchmarks can be added incrementally.
