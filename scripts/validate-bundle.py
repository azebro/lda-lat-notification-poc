from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

import regex
import yaml
from jsonschema import ValidationError, validators
from jsonschema.validators import validator_for


def validate_pattern(
    validator: Any,
    pattern: str,
    instance: Any,
    schema: dict[str, Any],
) -> tuple[()] | Any:
    del validator, schema
    if not isinstance(instance, str) or regex.search(pattern, instance):
        return ()
    return iter([ValidationError(f"{instance!r} does not match {pattern!r}")])


def main() -> int:
    repository_root = Path(__file__).resolve().parents[1]
    bundle_root = repository_root / "databricks"
    config = yaml.safe_load((bundle_root / "databricks.yml").read_text())
    config.update(yaml.safe_load((bundle_root / "resources" / "jobs.yml").read_text()))

    databricks_cli = os.environ.get("DATABRICKS_CLI_PATH", "databricks")
    schema = json.loads(
        subprocess.check_output(
            [databricks_cli, "bundle", "schema"],
            encoding="utf-8",
        )
    )
    bundle_validator = validators.extend(
        validator_for(schema),
        {"pattern": validate_pattern},
    )
    errors = sorted(
        bundle_validator(schema).iter_errors(config),
        key=lambda error: list(error.path),
    )
    for error in errors:
        print(f"{list(error.path)}: {error.message}")
    print(f"Bundle schema errors: {len(errors)}")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())