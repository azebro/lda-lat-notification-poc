from __future__ import annotations

import json
import os
import socketserver
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

if not hasattr(socketserver, "UnixStreamServer"):
    socketserver.UnixStreamServer = socketserver.TCPServer  # type: ignore[attr-defined]

from pyspark.sql import SparkSession
from pyspark.sql.types import (
    DoubleType,
    LongType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = REPOSITORY_ROOT / "databricks" / "src"
sys.path.insert(0, str(SOURCE_PATH))

from transformations import build_event_dataframe  # noqa: E402


class TransformationTests(unittest.TestCase):
    spark: SparkSession

    @classmethod
    def setUpClass(cls) -> None:
        os.environ.setdefault("SPARK_LOCAL_IP", "127.0.0.1")
        test_path = str(Path(__file__).parent)
        existing_python_path = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = (
            f"{test_path}{os.pathsep}{existing_python_path}"
            if existing_python_path
            else test_path
        )
        cls.spark = (
            SparkSession.builder.master("local[1]")
            .appName("delta-notification-tests")
            .config("spark.ui.enabled", "false")
            .config("spark.sql.session.timeZone", "UTC")
            .getOrCreate()
        )
        cls.spark.sparkContext.setLogLevel("ERROR")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.spark.stop()

    def test_build_event_dataframe_filters_and_emits_schema_valid_events(self) -> None:
        timestamp = datetime(2026, 8, 5, 12, 34, 56, tzinfo=timezone.utc)
        schema = StructType(
            [
                StructField("signal_id", StringType(), False),
                StructField("vehicle_id", StringType(), False),
                StructField("signal_type", StringType(), False),
                StructField("signal_value", DoubleType(), False),
                StructField("event_timestamp", TimestampType(), False),
                StructField("updated_at", TimestampType(), False),
                StructField("_change_type", StringType(), False),
                StructField("_commit_version", LongType(), False),
                StructField("_commit_timestamp", TimestampType(), False),
            ]
        )
        rows = [
            ("signal-001", "vehicle-001", "temperature", 12.5, timestamp, timestamp, change_type, 42, timestamp)
            for change_type in ("insert", "update_preimage", "update_postimage", "delete")
        ]
        changes = self.spark.createDataFrame(rows, schema)

        events = build_event_dataframe(
            changes,
            catalog_name="poc_notifications",
            schema_name="main",
            table_name="vehicle_signals",
        )
        actual = [(row.key, json.loads(row.value)) for row in events.collect()]

        self.assertEqual(events.schema["key"].dataType, StringType())
        self.assertEqual(events.schema["value"].dataType, StringType())
        self.assertEqual(len(actual), 2)
        self.assertEqual({key for key, _ in actual}, {"signal-001"})
        self.assertEqual(
            {event["change_type"] for _, event in actual},
            {"insert", "update_postimage"},
        )
        self.assertEqual(
            {event["event_id"] for _, event in actual},
            {
                "vehicle_signals-signal-001-v42-insert",
                "vehicle_signals-signal-001-v42-update_postimage",
            },
        )

        contract = json.loads(
            (REPOSITORY_ROOT / "contracts" / "delta-change-envelope.v1.schema.json").read_text()
        )
        validator = Draft202012Validator(contract, format_checker=FormatChecker())
        for _, event in actual:
            validator.validate(event)


if __name__ == "__main__":
    unittest.main()