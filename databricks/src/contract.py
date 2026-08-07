from __future__ import annotations

import json
import math
import re
from collections.abc import Iterable, Mapping
from datetime import UTC, datetime
from typing import Any

CATALOG_NAME = "poc_notifications"
SCHEMA_NAME = "main"
TABLE_NAME = "vehicle_signals"
SOURCE_NAME = "azure-databricks"
SUPPORTED_CHANGE_TYPES = frozenset({"insert", "update_postimage"})
PAYLOAD_FIELDS = (
    "signal_id",
    "vehicle_id",
    "signal_type",
    "signal_value",
    "event_timestamp",
    "updated_at",
)
ENVELOPE_FIELDS = (
    "event_id",
    "source",
    "catalog",
    "schema",
    "table",
    "primary_key",
    "change_type",
    "commit_version",
    "commit_timestamp",
    "payload",
)
_KEY_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def validate_identifier(value: str) -> str:
    if not _IDENTIFIER_PATTERN.fullmatch(value):
        raise ValueError(f"Invalid SQL identifier: {value!r}")
    return value


def validate_signal_id(signal_id: str) -> str:
    if not signal_id or not _KEY_PATTERN.fullmatch(signal_id):
        raise ValueError("signal_id must match ^[A-Za-z0-9._-]+$.")
    return signal_id


def validate_contract_location(catalog_name: str, schema_name: str, table_name: str) -> None:
    actual = (catalog_name, schema_name, table_name)
    expected = (CATALOG_NAME, SCHEMA_NAME, TABLE_NAME)
    if actual != expected:
        raise ValueError(
            "The v1 contract requires poc_notifications.main.vehicle_signals; "
            f"received {'.'.join(actual)}."
        )


def deterministic_event_id(
    signal_id: str,
    commit_version: int,
    change_type: str,
    table_name: str = TABLE_NAME,
) -> str:
    validate_signal_id(signal_id)
    if isinstance(commit_version, bool) or not isinstance(commit_version, int) or commit_version < 0:
        raise ValueError("commit_version must be a non-negative integer.")
    if change_type not in SUPPORTED_CHANGE_TYPES:
        raise ValueError(f"Unsupported CDF change type: {change_type!r}")
    validate_identifier(table_name)
    return f"{table_name}-{signal_id}-v{commit_version}-{change_type}"


def contract_timestamp(value: datetime | str) -> str:
    timestamp = value
    if isinstance(timestamp, str):
        timestamp = datetime.fromisoformat(timestamp)
    if timestamp.tzinfo is None or timestamp.utcoffset() is None:
        raise ValueError("Contract timestamps must include a UTC offset.")
    return timestamp.astimezone(UTC).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def build_envelope(
    row: Mapping[str, Any],
    *,
    catalog_name: str = CATALOG_NAME,
    schema_name: str = SCHEMA_NAME,
    table_name: str = TABLE_NAME,
) -> dict[str, Any]:
    validate_contract_location(catalog_name, schema_name, table_name)
    signal_id = _required_string(row, "signal_id")
    vehicle_id = _required_string(row, "vehicle_id")
    signal_type = _required_string(row, "signal_type")
    change_type = _required_string(row, "_change_type")
    commit_version = row.get("_commit_version")
    signal_value = row.get("signal_value")

    if isinstance(signal_value, bool) or not isinstance(signal_value, (int, float)):
        raise TypeError("signal_value must be numeric.")
    if not math.isfinite(float(signal_value)):
        raise ValueError("signal_value must be finite.")

    event_id = deterministic_event_id(
        signal_id,
        commit_version,
        change_type,
        table_name,
    )
    return {
        "event_id": event_id,
        "source": SOURCE_NAME,
        "catalog": catalog_name,
        "schema": schema_name,
        "table": table_name,
        "primary_key": signal_id,
        "change_type": change_type,
        "commit_version": commit_version,
        "commit_timestamp": contract_timestamp(row["_commit_timestamp"]),
        "payload": {
            "signal_id": signal_id,
            "vehicle_id": vehicle_id,
            "signal_type": signal_type,
            "signal_value": signal_value,
            "event_timestamp": contract_timestamp(row["event_timestamp"]),
            "updated_at": contract_timestamp(row["updated_at"]),
        },
    }


def canonical_json(envelope: Mapping[str, Any]) -> str:
    return json.dumps(envelope, ensure_ascii=True, separators=(",", ":"), allow_nan=False)


def validate_envelope(envelope: Mapping[str, Any]) -> None:
    _validate_exact_fields(envelope, ENVELOPE_FIELDS, "envelope")

    source = _required_string(envelope, "source")
    catalog_name = _required_string(envelope, "catalog")
    schema_name = _required_string(envelope, "schema")
    table_name = _required_string(envelope, "table")
    primary_key = validate_signal_id(_required_string(envelope, "primary_key"))
    change_type = _required_string(envelope, "change_type")
    commit_version = envelope.get("commit_version")
    validate_contract_location(catalog_name, schema_name, table_name)

    if source != SOURCE_NAME:
        raise ValueError(f"source must be {SOURCE_NAME!r}.")

    expected_event_id = deterministic_event_id(
        primary_key,
        commit_version,
        change_type,
        table_name,
    )
    if envelope.get("event_id") != expected_event_id:
        raise ValueError("event_id does not match the deterministic contract value.")
    contract_timestamp(envelope["commit_timestamp"])

    payload = envelope.get("payload")
    if not isinstance(payload, Mapping):
        raise TypeError("payload must be an object.")
    _validate_exact_fields(payload, PAYLOAD_FIELDS, "payload")
    signal_id = validate_signal_id(_required_string(payload, "signal_id"))
    _required_string(payload, "vehicle_id")
    _required_string(payload, "signal_type")
    if signal_id != primary_key:
        raise ValueError("primary_key must equal payload.signal_id.")

    signal_value = payload.get("signal_value")
    if isinstance(signal_value, bool) or not isinstance(signal_value, (int, float)):
        raise TypeError("payload.signal_value must be numeric.")
    if not math.isfinite(float(signal_value)):
        raise ValueError("payload.signal_value must be finite.")
    contract_timestamp(payload["event_timestamp"])
    contract_timestamp(payload["updated_at"])


def filter_publishable_changes(rows: Iterable[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    return [row for row in rows if row.get("_change_type") in SUPPORTED_CHANGE_TYPES]


def validate_unique_signal_ids(rows: Iterable[Mapping[str, Any]]) -> None:
    seen: set[str] = set()
    for row in rows:
        signal_id = row.get("signal_id")
        if not isinstance(signal_id, str) or not signal_id:
            raise ValueError("signal_id must be non-null and non-empty.")
        if signal_id in seen:
            raise ValueError(f"Duplicate signal_id: {signal_id}")
        seen.add(signal_id)


def _required_string(row: Mapping[str, Any], key: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string.")
    return value


def _validate_exact_fields(
    value: Mapping[str, Any],
    expected_fields: tuple[str, ...],
    label: str,
) -> None:
    actual = set(value)
    expected = set(expected_fields)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValueError(f"{label} fields do not match the v1 contract; missing={missing}, extra={extra}.")