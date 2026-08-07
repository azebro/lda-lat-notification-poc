# Databricks notebook source
from __future__ import annotations

from datetime import datetime, timezone

from contract import (
    build_envelope,
    canonical_json,
    validate_contract_location,
    validate_identifier,
)
from transformations import build_event_dataframe


def widget(name: str, default: str) -> str:
    dbutils.widgets.text(name, default)
    return dbutils.widgets.get(name)


catalog_name = validate_identifier(widget("catalog_name", "poc_notifications"))
schema_name = validate_identifier(widget("schema_name", "main"))
table_name = validate_identifier(widget("table_name", "vehicle_signals"))
validate_contract_location(catalog_name, schema_name, table_name)
event_hub_namespace_fqdn = widget("event_hub_namespace_fqdn", "")
event_hub_name = widget("event_hub_name", "delta-changes")
service_credential_name = widget("service_credential_name", "")
checkpoint_path = widget(
    "checkpoint_path",
    "/Volumes/poc_notifications/main/streaming_state/cdf_publisher",
)

if not event_hub_namespace_fqdn.endswith(".servicebus.windows.net"):
    raise ValueError("event_hub_namespace_fqdn must be an Azure Event Hubs namespace FQDN.")
if not event_hub_name or not service_credential_name:
    raise ValueError("event_hub_name and service_credential_name are required.")
if not checkpoint_path.startswith("/Volumes/"):
    raise ValueError("checkpoint_path must use a durable Unity Catalog volume.")

spark.conf.set("spark.sql.session.timeZone", "UTC")
qualified_table = f"`{catalog_name}`.`{schema_name}`.`{table_name}`"
kafka_options = {
    "kafka.bootstrap.servers": f"{event_hub_namespace_fqdn}:9093",
    "topic": event_hub_name,
    "databricks.serviceCredential": service_credential_name,
}

smoke_time = datetime(2000, 1, 1, tzinfo=timezone.utc)
smoke_row = {
    "signal_id": "__kafka_smoke__",
    "vehicle_id": "connectivity-probe",
    "signal_type": "connectivity",
    "signal_value": 0.0,
    "event_timestamp": smoke_time,
    "updated_at": smoke_time,
    "_change_type": "insert",
    "_commit_version": 0,
    "_commit_timestamp": smoke_time,
}
smoke_value = canonical_json(
    build_envelope(
        smoke_row,
        catalog_name=catalog_name,
        schema_name=schema_name,
        table_name=table_name,
    )
)
spark.createDataFrame(
    [(smoke_row["signal_id"], smoke_value)],
    "key STRING, value STRING",
).write.format("kafka").options(**kafka_options).save()

changes = spark.readStream.option("readChangeFeed", "true").table(qualified_table)
events = build_event_dataframe(
    changes,
    catalog_name=catalog_name,
    schema_name=schema_name,
    table_name=table_name,
)
query = (
    events.writeStream.format("kafka")
    .options(**kafka_options)
    .option("checkpointLocation", checkpoint_path)
    .outputMode("append")
    .queryName("delta_change_notification_publisher")
    .trigger(processingTime="5 seconds")
    .start()
)
query.awaitTermination()