#!/usr/bin/env python3
"""KDG test harness.

Runs both reference parsers over the test vectors and examples and checks the
results against expected outputs. Zero dependencies beyond Python 3 and Node
(for the JavaScript parser).

Usage:
    python3 tests/run_tests.py
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

IMPLS = [
    ("python", ["python3", str(ROOT / "implementations" / "kdg.py")]),
    ("node", ["node", str(ROOT / "implementations" / "kdg.js")]),
]

VALID_DIR = ROOT / "tests" / "vectors" / "valid"
INVALID_DIR = ROOT / "tests" / "vectors" / "invalid"
EXPECTED_DIR = ROOT / "tests" / "vectors" / "expected"
EXAMPLES_DIR = ROOT / "examples"


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def check_valid(vector_path):
    expected_path = EXPECTED_DIR / (vector_path.stem + ".json")
    if not expected_path.exists():
        return [(vector_path.name + ": missing expected JSON " + expected_path.name, False)]

    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    results = []

    for name, cmd in IMPLS:
        proc = run(cmd + ["parse", str(vector_path)])
        if proc.returncode != 0:
            results.append((name + " parse " + vector_path.name + ": exit " + str(proc.returncode) + ": " + proc.stderr.strip(), False))
            continue
        try:
            actual = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            results.append((name + " parse " + vector_path.name + ": invalid JSON output: " + str(exc), False))
            continue
        if actual != expected:
            results.append((name + " parse " + vector_path.name + ": output mismatch", False))
        else:
            results.append((name + " parse " + vector_path.name + ": ok", True))

    return results


def check_invalid(vector_path):
    sidecar = vector_path.with_suffix(".expected")
    expected_err = sidecar.read_text(encoding="utf-8").strip() if sidecar.exists() else None
    results = []

    for name, cmd in IMPLS:
        proc = run(cmd + ["validate", str(vector_path)])
        if proc.returncode == 0:
            results.append((name + " validate " + vector_path.name + ": expected failure but passed", False))
            continue
        combined = proc.stdout + proc.stderr
        if expected_err and expected_err not in combined:
            results.append((name + " validate " + vector_path.name + ": expected error containing " + repr(expected_err) + ", got: " + proc.stderr.strip(), False))
        else:
            results.append((name + " validate " + vector_path.name + ": ok", True))

    return results


def check_example(path):
    results = []
    for name, cmd in IMPLS:
        proc = run(cmd + ["validate", str(path)])
        if proc.returncode != 0:
            results.append((name + " validate " + path.name + ": exit " + str(proc.returncode) + ": " + proc.stderr.strip(), False))
        else:
            results.append((name + " validate " + path.name + ": ok", True))
    return results


def check_convert(vector_path):
    expected_path = EXPECTED_DIR / (vector_path.stem + ".json")
    if not expected_path.exists():
        return []

    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    results = []

    for name, cmd in IMPLS:
        proc = run(cmd + ["convert", str(vector_path), "json"])
        if proc.returncode != 0:
            results.append((name + " convert-json " + vector_path.name + ": exit " + str(proc.returncode) + ": " + proc.stderr.strip(), False))
            continue
        try:
            actual = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            results.append((name + " convert-json " + vector_path.name + ": invalid JSON: " + str(exc), False))
            continue
        if actual != expected:
            results.append((name + " convert-json " + vector_path.name + ": output mismatch", False))
        else:
            results.append((name + " convert-json " + vector_path.name + ": ok", True))

        proc_csv = run(cmd + ["convert", str(vector_path), "csv"])
        if proc_csv.returncode != 0:
            results.append((name + " convert-csv " + vector_path.name + ": exit " + str(proc_csv.returncode) + ": " + proc_csv.stderr.strip(), False))
        else:
            results.append((name + " convert-csv " + vector_path.name + ": ok", True))

    return results


def main():
    checks = []

    for path in sorted(VALID_DIR.glob("*.kdg")):
        checks.extend(check_valid(path))

    for path in sorted(INVALID_DIR.glob("*.kdg")):
        checks.extend(check_invalid(path))

    for path in sorted(EXAMPLES_DIR.glob("*.kdg")):
        checks.extend(check_example(path))

    for path in sorted(VALID_DIR.glob("*.kdg")):
        checks.extend(check_convert(path))

    failed = [msg for msg, ok in checks if not ok]
    passed = sum(1 for _, ok in checks if ok)

    for msg, ok in checks:
        print(("PASS" if ok else "FAIL") + "  " + msg)

    print()
    print(str(passed) + "/" + str(len(checks)) + " checks passed")

    if failed:
        print()
        print(str(len(failed)) + " failed:")
        for msg in failed:
            print("  - " + msg)
        return 1

    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
