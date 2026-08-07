# Databricks Workloads

This Declarative Automation Bundle defines three single-node Databricks Runtime 18 LTS jobs:

- `setup_source` creates the CDF table and managed checkpoint volume, then validates the unique `signal_id` invariant.
- `cdf_publisher` performs a deterministic Kafka credential probe and continuously publishes inserts and update post-images.
- `drive_change` inserts or updates one synthetic signal and returns its commit metadata and expected event ID.

Phase 2 provides the account/workspace bootstrap in `../scripts/bootstrap-databricks.ps1`. After loading `azd` outputs, set these bundle variables:

```powershell
$workspaceUrl = $env:AZURE_DATABRICKS_WORKSPACE_URL -replace '^https://', ''
$env:DATABRICKS_HOST = "https://$workspaceUrl"
$env:BUNDLE_VAR_node_type_id = $env:AZURE_DATABRICKS_NODE_TYPE
$env:BUNDLE_VAR_event_hub_namespace_fqdn = $env:AZURE_EVENT_HUB_NAMESPACE_FQDN
$env:BUNDLE_VAR_service_credential_name = "delta_notification_event_hubs_$env:AZURE_NAME_TOKEN"
```

`DATABRICKS_JOB_RUN_PRINCIPAL` used by the bootstrap must identify the same user or service principal that deploys the bundle. The bootstrap verifies this before granting Unity Catalog privileges.

Then validate and deploy from this directory:

```powershell
databricks bundle validate -t dev
databricks bundle deploy -t dev
databricks bundle run setup_source -t dev
databricks bundle run cdf_publisher -t dev
```

The publisher's required one-message Kafka probe uses the stable event ID `vehicle_signals-__kafka_smoke__-v0-insert`; verification must classify this separately from Delta commit evidence. Restarts can produce only a duplicate outcome for that ID. Stop the continuous run when the demonstration is not active. Never delete the checkpoint unless the source table and Event Hubs/audit evidence are reset together.