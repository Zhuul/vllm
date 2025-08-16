#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import os
import sys

def load(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("a")
    p.add_argument("b")
    args = p.parse_args()

    A = load(args.a)
    B = load(args.b)

    # Placeholder comparison: print keys that differ
    diffs = sorted(set(A.keys()) ^ set(B.keys()))
    print(json.dumps({"diff_keys": diffs}))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
