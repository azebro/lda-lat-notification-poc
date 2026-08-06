# Azure Infrastructure

The subscription-scoped [main.bicep](main.bicep) creates one POC resource group and composes resource-specific modules.

## Modules

| Module | Resources |
|---|---|
| `identity.bicep` | Function user-assigned managed identity |
| `storage.bicep` | ADLS Gen2, Function host/deployment storage, and audit storage |
| `monitoring.bicep` | Log Analytics and workspace-based Application Insights |
| `messaging.bicep` | Event Hubs Standard namespace, `delta-changes`, and `notification-receiver` consumer group |
| `databricks.bicep` | Premium Azure Databricks workspace and Access Connector |
| `rbac.bicep` | Data-plane sender, receiver, storage, monitoring, and verifier roles |
| `rbac-gate.bicep` | Bounded, identity-based data-plane check that waits for Flex deployment-container access |
| `receiver.bicep` | Linux Flex Consumption plan and .NET 10 isolated Function App hosting |

Azure Verified Modules are pinned to explicit versions. Storage local authentication and Event Hubs local authentication are disabled. The Function uses a user-assigned identity for Flex deployment storage, host storage, Event Hubs, audit storage, and Application Insights.

## Validate

```powershell
az bicep build --file infra/main.bicep
```

`main.parameters.json` maps the standard `AZURE_ENV_NAME` and `AZURE_LOCATION` values supplied by `azd`.

## Outputs

Deployment outputs expose resource names, workspace identifiers, Event Hubs endpoints, identity IDs, monitoring targets, and the parameterized Databricks node type needed by later phases. No storage key, SAS token, or Event Hubs connection string is emitted.

## Databricks Boundary

Bicep deploys the Azure workspace and Access Connector. Unity Catalog metastore assignment, credentials, external location, workspace bindings, and grants are configured by [../scripts/bootstrap-databricks.ps1](../scripts/bootstrap-databricks.ps1) because those operations use Databricks account/workspace APIs rather than Azure Resource Manager.

The bootstrap never creates, deletes, or unassigns a regional metastore.