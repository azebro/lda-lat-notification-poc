# Databricks notebook source
from __future__ import annotations

import json

from contract import (
    canonical_json,
    validate_contract_location,
    validate_envelope,
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
envelope_json = widget("envelope_json", "{}")

if not event_hub_namespace_fqdn.endswith(".servicebus.windows.net"):
    raise ValueError("event_hub_namespace_fqdn must be an Azure Event Hubs namespace FQDN.")
if not event_hub_name or not service_credential_name:
    raise ValueError("event_hub_name and service_credential_name are required.")

envelope = json.loads(envelope_json)
if not isinstance(envelope, dict):
    raise TypeError("envelope_json must contain a JSON object.")
validate_envelope(envelope)

kafka_options = {
    "kafka.bootstrap.servers": f"{event_hub_namespace_fqdn}:9093",
    "topic": event_hub_name,
    "databricks.serviceCredential": service_credential_name,
}
spark.createDataFrame(
    [(envelope["primary_key"], canonical_json(envelope))],
    "key STRING, value STRING",
).write.format("kafka").options(**kafka_options).save()

dbutils.notebook.exit(
    json.dumps(
        {
            "event_id": envelope["event_id"],
            "event_hub": event_hub_name,
            "status": "replayed",
        },
        separators=(",", ":"),
    )
)