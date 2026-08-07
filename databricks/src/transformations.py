from __future__ import annotations

from typing import Any

from contract import (
    PAYLOAD_FIELDS,
    SOURCE_NAME,
    SUPPORTED_CHANGE_TYPES,
    validate_contract_location,
)


def build_event_dataframe(
    changes: Any,
    *,
    catalog_name: str,
    schema_name: str,
    table_name: str,
) -> Any:
    validate_contract_location(catalog_name, schema_name, table_name)
    from pyspark.sql import functions as sql

    publishable = changes.where(sql.col("_change_type").isin(sorted(SUPPORTED_CHANGE_TYPES)))
    event_id = sql.concat(
        sql.lit(f"{table_name}-"),
        sql.col("signal_id"),
        sql.lit("-v"),
        sql.col("_commit_version").cast("string"),
        sql.lit("-"),
        sql.col("_change_type"),
    )
    payload = sql.struct(*(sql.col(field).alias(field) for field in PAYLOAD_FIELDS))
    envelope = sql.struct(
        event_id.alias("event_id"),
        sql.lit(SOURCE_NAME).alias("source"),
        sql.lit(catalog_name).alias("catalog"),
        sql.lit(schema_name).alias("schema"),
        sql.lit(table_name).alias("table"),
        sql.col("signal_id").cast("string").alias("primary_key"),
        sql.col("_change_type").alias("change_type"),
        sql.col("_commit_version").cast("long").alias("commit_version"),
        sql.col("_commit_timestamp").alias("commit_timestamp"),
        payload.alias("payload"),
    )

    return publishable.select(
        sql.col("signal_id").cast("string").alias("key"),
        sql.to_json(
            envelope,
            options={
                "ignoreNullFields": "false",
                "timestampFormat": "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            },
        ).alias("value"),
    )