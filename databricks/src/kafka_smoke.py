# Databricks notebook source
from __future__ import annotations

import json
from datetime import UTC, datetime

from contract import (
    build_envelope,
    canonical_json,
    validate_contract_location,
    validate_identifier,
)


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

if not event_hub_namespace_fqdn.endswith(".servicebus.windows.net"):
    raise ValueError("event_hub_namespace_fqdn must be an Azure Event Hubs namespace FQDN.")
if not event_hub_name or not service_credential_name:
    raise ValueError("event_hub_name and service_credential_name are required.")

smoke_time = datetime(2000, 1, 1, tzinfo=UTC)
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
kafka_options = {
    "kafka.bootstrap.servers": f"{event_hub_namespace_fqdn}:9093",
    "topic": event_hub_name,
    "databricks.serviceCredential": service_credential_name,
}

spark.createDataFrame(
    [(smoke_row["signal_id"], smoke_value)],
    "key STRING, value STRING",
).write.format("kafka").options(**kafka_options).save()

dbutils.notebook.exit(
    json.dumps(
        {
            "event_id": "vehicle_signals-__kafka_smoke__-v0-insert",
            "event_hub": event_hub_name,
            "status": "sent",
        },
        separators=(",", ":"),
    )
)