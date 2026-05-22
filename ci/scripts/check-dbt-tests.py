#!/usr/bin/env python3
"""CI-check that every dbt mart-model has at least one test declared.

Sister script to `check-dbt-meta.py`. We can't run `dbt test` in CI without a
live Trino warehouse, so instead we verify *statically* that mart models
(domain `marts`, schemas `gold` + `sensitive`) carry at least one column- or
model-level test in their schema.yml. That gives a regression-floor against
"new mart shipped untested".

Staging models are softer — they're plumbing for marts, and the marts'
tests cover their data implicitly. We do warn about staging models without
tests but don't fail the build.

Exit 0 = OK; exit 1 = at least one mart-model missing tests.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterable

import yaml


def iter_schema_files(root: Path) -> Iterable[Path]:
    """All schema YAML files under dbt/models/, recursively."""
    for path in (root / "models").rglob("*.yml"):
        # Skip helper dbt-files (e.g. _sources.yml).
        if path.name == "_sources.yml":
            continue
        yield path


def collect_models_and_tests(schema: dict) -> dict[str, dict]:
    """Return {model_name: {'has_model_tests': bool, 'columns_with_tests': int, 'total_columns': int}}."""
    result: dict[str, dict] = {}
    for model in schema.get("models", []) or []:
        name = model.get("name")
        if not name:
            continue
        # Model-level tests live under either `tests` (dbt <1.7) or `data_tests`.
        model_tests = model.get("tests") or model.get("data_tests") or []
        columns = model.get("columns") or []
        col_with_tests = sum(
            1 for col in columns if (col.get("tests") or col.get("data_tests"))
        )
        result[name] = {
            "has_model_tests": bool(model_tests),
            "columns_with_tests": col_with_tests,
            "total_columns": len(columns),
        }
    return result


def is_mart_model(name: str, path: Path) -> bool:
    """Heuristic: mart models live under dbt/models/marts/ OR start with mart_/uc."""
    parts = path.parts
    if "marts" in parts:
        return True
    return name.startswith(("mart_", "uc0", "uc1", "uc2"))


def main() -> int:
    root = Path(__file__).resolve().parents[2] / "dbt"
    if not (root / "models").exists():
        print(f"FAIL: dbt models dir not found at {root}/models", file=sys.stderr)
        return 1

    mart_errors: list[str] = []
    staging_warnings: list[str] = []
    mart_count = 0
    staging_count = 0

    for path in iter_schema_files(root):
        with path.open() as f:
            try:
                schema = yaml.safe_load(f) or {}
            except yaml.YAMLError as exc:
                print(f"FAIL: {path}: YAML parse error: {exc}", file=sys.stderr)
                return 1

        for model_name, stats in collect_models_and_tests(schema).items():
            has_tests = stats["has_model_tests"] or stats["columns_with_tests"] > 0

            if is_mart_model(model_name, path):
                mart_count += 1
                if not has_tests:
                    mart_errors.append(
                        f"{path.relative_to(root.parent)}: mart model "
                        f"`{model_name}` has no tests "
                        f"(0/{stats['total_columns']} columns, no model-level tests)"
                    )
            else:
                staging_count += 1
                if not has_tests:
                    staging_warnings.append(
                        f"{path.relative_to(root.parent)}: staging/intermediate "
                        f"model `{model_name}` has no tests"
                    )

    if staging_warnings:
        print("--- staging/intermediate models without tests (warnings) ---")
        for w in staging_warnings:
            print(f"  warn: {w}")

    if mart_errors:
        print("--- mart models WITHOUT tests (errors) ---", file=sys.stderr)
        for e in mart_errors:
            print(f"  fail: {e}", file=sys.stderr)
        print(
            f"\n{len(mart_errors)} of {mart_count} mart models lack tests.",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: all {mart_count} mart models have at least one test "
        f"({staging_count} staging/intermediate models scanned, "
        f"{len(staging_warnings)} untested)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
