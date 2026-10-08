#!/usr/bin/env python3
"""KDG test harness.

Runs every reference parser over the test vectors and examples and checks the
results against expected outputs. Zero dependencies beyond Python 3 and each
implementation's toolchain (Node, Go, cc, Bash, GHC/runghc, PowerShell, R, and
CBQN). An implementation whose toolchain is not installed is SKIPPED with a
note, never treated as a failure, so contributors can run the suite with
whatever is on their machine.

Usage:
    python3 tests/run_tests.py
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMPL_DIR = ROOT / "implementations"
C_BINARY = Path(tempfile.gettempdir()) / "kdg-c"

# Each entry: (name, run_prefix, build_command_or_None).
# run_prefix is a list; the harness appends [subcommand, file] to it.
# When build_command is present (compiled implementations), it is run once if
# its compiler is available, and on success the run_prefix (the built binary)
# is used.
IMPL_SPECS = [
    ("python", ["python3", str(IMPL_DIR / "kdg.py")], None),
    ("node", ["node", str(IMPL_DIR / "kdg.js")], None),
    ("go", ["go", "run", str(IMPL_DIR / "kdg.go")], None),
    ("bash", ["bash", str(IMPL_DIR / "kdg.sh")], None),
    ("haskell", ["runghc", str(IMPL_DIR / "kdg.hs")], None),
    ("powershell", ["pwsh", "-NoProfile", "-File", str(IMPL_DIR / "kdg.ps1")], None),
    ("r", ["Rscript", str(IMPL_DIR / "kdg.R")], None),
    ("bqn", ["bqn", str(IMPL_DIR / "kdg.bqn")], None),
    ("c", [str(C_BINARY)], ["cc", "-O2", "-o", str(C_BINARY), str(IMPL_DIR / "kdg.c")]),
]

VALID_DIR = ROOT / "tests" / "vectors" / "valid"
INVALID_DIR = ROOT / "tests" / "vectors" / "invalid"
EXPECTED_DIR = ROOT / "tests" / "vectors" / "expected"
EXAMPLES_DIR = ROOT / "examples"


def available_impls():
    """Return (name, run_prefix) pairs whose toolchain is present and buildable."""
    ready = []
    for name, run_prefix, build_cmd in IMPL_SPECS:
        probe = build_cmd if build_cmd else run_prefix
        if shutil.which(probe[0]) is None:
            print("SKIP  " + name + ": " + probe[0] + " not found")
            continue
        if build_cmd:
            proc = subprocess.run(build_cmd, capture_output=True, text=True)
            if proc.returncode != 0:
                print("SKIP  " + name + ": build failed: " + proc.stderr.strip())
                continue
        ready.append((name, run_prefix))
    return ready


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def check_valid(vector_path, impls):
    expected_path = EXPECTED_DIR / (vector_path.stem + ".json")
    if not expected_path.exists():
        return [(vector_path.name + ": missing expected JSON " + expected_path.name, False)]

    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    results = []

    for name, cmd in impls:
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


def check_invalid(vector_path, impls):
    sidecar = vector_path.with_suffix(".expected")
    expected_err = sidecar.read_text(encoding="utf-8").strip() if sidecar.exists() else None
    results = []

    for name, cmd in impls:
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


def check_example(path, impls):
    results = []
    for name, cmd in impls:
        proc = run(cmd + ["validate", str(path)])
        if proc.returncode != 0:
            results.append((name + " validate " + path.name + ": exit " + str(proc.returncode) + ": " + proc.stderr.strip(), False))
        else:
            results.append((name + " validate " + path.name + ": ok", True))
    return results


def check_convert(vector_path, impls):
    expected_path = EXPECTED_DIR / (vector_path.stem + ".json")
    if not expected_path.exists():
        return []

    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    results = []

    for name, cmd in impls:
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
    impls = available_impls()
    if not impls:
        print("No implementations available.")
        return 1

    checks = []

    for path in sorted(VALID_DIR.glob("*.kdg")):
        checks.extend(check_valid(path, impls))

    for path in sorted(INVALID_DIR.glob("*.kdg")):
        checks.extend(check_invalid(path, impls))

    for path in sorted(EXAMPLES_DIR.glob("*.kdg")):
        checks.extend(check_example(path, impls))

    for path in sorted(VALID_DIR.glob("*.kdg")):
        checks.extend(check_convert(path, impls))

    failed = [msg for msg, ok in checks if not ok]
    passed = sum(1 for _, ok in checks if ok)

    for msg, ok in checks:
        print(("PASS" if ok else "FAIL") + "  " + msg)

    print()
    print(str(passed) + "/" + str(len(checks)) + " checks passed across " + str(len(impls)) + " implementation(s)")

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
