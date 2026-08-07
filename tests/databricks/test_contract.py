from __future__ import annotations

import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

SOURCE_PATH = Path(__file__).resolve().parents[2] / "databricks" / "src"
sys.path.insert(0, str(SOURCE_PATH))

from contract import (  # noqa: E402
    build_envelope,
    canonical_json,
    deterministic_event_id,
    filter_publishable_changes,
    validate_contract_location,
    validate_identifier,
    validate_signal_id,
    validate_unique_signal_ids,
)


class ContractTests(unittest.TestCase):
    def test_deterministic_event_id(self) -> None:
        self.assertEqual(
            deterministic_event_id("signal-001", 42, "update_postimage"),
            "vehicle_signals-signal-001-v42-update_postimage",
        )

    def test_unsupported_change_type_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unsupported CDF change type"):
            deterministic_event_id("signal-001", 42, "update_preimage")

    def test_build_envelope_produces_exact_contract_and_canonical_json(self) -> None:
        envelope = build_envelope(self.valid_row())
        encoded = canonical_json(envelope)

        self.assertNotIn(" ", encoded)
        self.assertEqual(
            list(json.loads(encoded)),
            [
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
            ],
        )
        self.assertEqual(envelope["primary_key"], envelope["payload"]["signal_id"])
        self.assertEqual(envelope["commit_timestamp"], "2026-08-05T12:34:56.000Z")

    def test_filter_publishable_changes_excludes_preimages_and_deletes(self) -> None:
        rows = [
            {"_change_type": "insert"},
            {"_change_type": "update_preimage"},
            {"_change_type": "update_postimage"},
            {"_change_type": "delete"},
        ]

        filtered = filter_publishable_changes(rows)

        self.assertEqual(
            [row["_change_type"] for row in filtered],
            ["insert", "update_postimage"],
        )

    def test_unique_signal_ids_accept_unique_rows(self) -> None:
        validate_unique_signal_ids([{"signal_id": "a"}, {"signal_id": "b"}])

    def test_unique_signal_ids_reject_null_and_duplicates(self) -> None:
        with self.assertRaisesRegex(ValueError, "non-null"):
            validate_unique_signal_ids([{"signal_id": None}])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            validate_unique_signal_ids([{"signal_id": "a"}, {"signal_id": "a"}])

    def test_sql_identifier_validation(self) -> None:
        self.assertEqual(validate_identifier("vehicle_signals"), "vehicle_signals")
        with self.assertRaisesRegex(ValueError, "Invalid SQL identifier"):
            validate_identifier("main; DROP SCHEMA main")

    def test_contract_location_rejects_incompatible_override(self) -> None:
        validate_contract_location("poc_notifications", "main", "vehicle_signals")
        with self.assertRaisesRegex(ValueError, "v1 contract requires"):
            validate_contract_location("other", "main", "vehicle_signals")

    def test_signal_id_validation_rejects_contract_unsafe_value(self) -> None:
        self.assertEqual(validate_signal_id("signal-001"), "signal-001")
        with self.assertRaisesRegex(ValueError, "signal_id must match"):
            validate_signal_id("signal/001")

    @staticmethod
    def valid_row() -> dict[str, object]:
        return {
            "signal_id": "signal-001",
            "vehicle_id": "vehicle-001",
            "signal_type": "temperature",
            "signal_value": 12.5,
            "event_timestamp": datetime(2026, 8, 5, 12, 30, tzinfo=timezone.utc),
            "updated_at": datetime(2026, 8, 5, 12, 34, 55, tzinfo=timezone.utc),
            "_change_type": "insert",
            "_commit_version": 42,
            "_commit_timestamp": datetime(2026, 8, 5, 12, 34, 56, tzinfo=timezone.utc),
        }


if __name__ == "__main__":
    unittest.main()