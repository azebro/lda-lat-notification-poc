# Databricks notebook source
from __future__ import annotations

import json
from datetime import UTC, datetime

from contract import (
    contract_timestamp,
    deterministic_event_id,
    validate_contract_location,
    validate_identifier,
    validate_signal_id,
)
from delta.tables import DeltaTable
from pyspark.sql import functions as sql
from pyspark.sql.types import (
    DoubleType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)


def widget(name: str, default: str) -> str:
    dbutils.widgets.text(name, default)
    return dbutils.widgets.get(name)


catalog_name = validate_identifier(widget("catalog_name", "poc_notifications"))
schema_name = validate_identifier(widget("schema_name", "main"))
table_name = validate_identifier(widget("table_name", "vehicle_signals"))
validate_contract_location(catalog_name, schema_name, table_name)
mode = widget("mode", "insert").lower()
signal_id = validate_signal_id(widget("signal_id", "signal-demo-001"))
vehicle_id = widget("vehicle_id", "vehicle-demo-001")
signal_type = widget("signal_type", "temperature")
signal_value = float(widget("signal_value", "20.0"))

if mode not in {"insert", "update"}:
    raise ValueError("mode must be insert or update.")

spark.conf.set("spark.sql.session.timeZone", "UTC")
qualified_table = f"`{catalog_name}`.`{schema_name}`.`{table_name}`"
matches = spark.table(qualified_table).where(sql.col("signal_id") == signal_id)
match_count = matches.count()
now = datetime.now(UTC)

if mode == "insert":
    if match_count:
        raise ValueError(f"signal_id {signal_id!r} already exists; insert must be unique.")

    schema = StructType(
        [
            StructField("signal_id", StringType(), False),
            StructField("vehicle_id", StringType(), False),
            StructField("signal_type", StringType(), False),
            StructField("signal_value", DoubleType(), False),
            StructField("event_timestamp", TimestampType(), False),
            StructField("updated_at", TimestampType(), False),
        ]
    )
    spark.createDataFrame(
        [(signal_id, vehicle_id, signal_type, signal_value, now, now)],
        schema,
    ).write.mode("append").saveAsTable(qualified_table)
    change_type = "insert"
else:
    if match_count != 1:
        raise ValueError(f"signal_id {signal_id!r} must identify exactly one row for update.")
    current_value = matches.select("signal_value").first().signal_value
    if current_value == signal_value:
        raise ValueError("update signal_value must differ from the current value.")

    DeltaTable.forName(spark, f"{catalog_name}.{schema_name}.{table_name}").update(
        condition=sql.col("signal_id") == signal_id,
        set={
            "signal_value": sql.lit(signal_value),
            "updated_at": sql.lit(now),
        },
    )
    change_type = "update_postimage"

history = spark.sql(f"DESCRIBE HISTORY {qualified_table} LIMIT 1").first()
commit_version = int(history.version)
result = {
    "signal_id": signal_id,
    "commit_version": commit_version,
    "commit_timestamp": contract_timestamp(history.timestamp.replace(tzinfo=UTC)),
    "change_type": change_type,
    "expected_event_id": deterministic_event_id(
        signal_id,
        commit_version,
        change_type,
        table_name,
    ),
}
result_json = json.dumps(result, separators=(",", ":"))
dbutils.jobs.taskValues.set(key="change_result", value=result_json)
dbutils.notebook.exit(result_json)