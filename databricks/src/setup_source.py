# Databricks notebook source
from __future__ import annotations

import json
from pathlib import Path

from contract import validate_contract_location, validate_identifier


def widget(name: str, default: str) -> str:
    dbutils.widgets.text(name, default)
    return dbutils.widgets.get(name)


catalog_name = validate_identifier(widget("catalog_name", "poc_notifications"))
schema_name = validate_identifier(widget("schema_name", "main"))
table_name = validate_identifier(widget("table_name", "vehicle_signals"))
validate_contract_location(catalog_name, schema_name, table_name)
volume_name = validate_identifier(widget("volume_name", "streaming_state"))
checkpoint_path = widget(
    "checkpoint_path",
    f"/Volumes/{catalog_name}/{schema_name}/{volume_name}/cdf_publisher",
)
require_empty = widget("require_empty", "true").lower() == "true"

if not checkpoint_path.startswith(f"/Volumes/{catalog_name}/{schema_name}/{volume_name}/"):
    raise ValueError("checkpoint_path must be inside the POC streaming-state volume.")

qualified_schema = f"`{catalog_name}`.`{schema_name}`"
qualified_table = f"{qualified_schema}.`{table_name}`"

spark.sql(f"CREATE CATALOG IF NOT EXISTS `{catalog_name}`")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS {qualified_schema}")
spark.sql(
    f"CREATE VOLUME IF NOT EXISTS {qualified_schema}.`{volume_name}` "
    "COMMENT 'POC-owned Delta CDF streaming checkpoints'"
)
spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS {qualified_table} (
      signal_id STRING NOT NULL,
      vehicle_id STRING NOT NULL,
      signal_type STRING NOT NULL,
      signal_value DOUBLE NOT NULL,
      event_timestamp TIMESTAMP NOT NULL,
      updated_at TIMESTAMP NOT NULL
    )
    USING DELTA
    TBLPROPERTIES (
      'delta.enableChangeDataFeed' = 'true',
      'poc.purpose' = 'delta-change-notification'
    )
    """
)
spark.sql(
    f"ALTER TABLE {qualified_table} SET TBLPROPERTIES ('delta.enableChangeDataFeed' = 'true')"
)

table_properties = {
    row.key: row.value for row in spark.sql(f"SHOW TBLPROPERTIES {qualified_table}").collect()
}
if "delta.constraints.valid_signal_id" not in table_properties:
    spark.sql(
        f"ALTER TABLE {qualified_table} ADD CONSTRAINT valid_signal_id "
        "CHECK (signal_id RLIKE '^[A-Za-z0-9._-]+$')"
    )

metrics = spark.sql(
    f"""
    SELECT
      COUNT(*) AS row_count,
      COUNT_IF(signal_id IS NULL OR signal_id = '') AS invalid_key_count,
      COUNT(DISTINCT signal_id) AS distinct_key_count
    FROM {qualified_table}
    """
).first()

if metrics.invalid_key_count:
    raise ValueError("vehicle_signals contains a null or empty signal_id.")
if metrics.row_count != metrics.distinct_key_count:
    raise ValueError("vehicle_signals contains duplicate signal_id values.")
if require_empty and metrics.row_count:
    raise ValueError(
        "setup_source requires an empty table. Use a new signal environment or perform the documented full reset."
    )

checkpoint_directory = Path(checkpoint_path)
if require_empty and checkpoint_directory.exists() and any(checkpoint_directory.iterdir()):
    raise ValueError(
        "setup_source found an empty table with a non-empty publisher checkpoint. "
        "Stop the publisher and reset the table and checkpoint together."
    )

dbutils.fs.mkdirs(checkpoint_path)
result = {
    "table": f"{catalog_name}.{schema_name}.{table_name}",
    "checkpoint_path": checkpoint_path,
    "row_count": metrics.row_count,
    "cdf_enabled": True,
}
dbutils.notebook.exit(json.dumps(result, separators=(",", ":")))