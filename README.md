# Azure Delta Change Notification POC

This repository proves that an insert or update to an Azure Databricks Delta table can be published as a changed-row event through Azure Event Hubs and durably captured by an Azure Function.

## Documentation

- [Implementation plan](plan.md)
- [Architecture](architecture.md)
- [Research](research/research.md)
- [Versioned event contract](contracts/delta-change-envelope.v1.schema.json)
- [Stable plan artifact](plan/azure-delta-notification-poc-plan.md)
- [Azure deployment](infra/README.md)
- [Contract validation](scripts/validate-contract.ps1)
- [Databricks bootstrap](scripts/bootstrap-databricks.ps1)
- [Deployment and teardown](scripts/README.md)

## Repository Structure

```text
.
|-- contracts/                 Versioned event schemas and examples
|-- databricks/                Databricks Asset Bundle artifacts (Phase 4)
|-- evidence/                  POC execution evidence (Phase 6)
|-- infra/                     Azure Bicep infrastructure
|   `-- modules/               Resource-specific Bicep modules
|-- plan/                      Stable planning artifacts
|-- research/                  Architecture research
|-- scripts/                   Deployment, bootstrap, validation, and teardown
|-- src/receiver/              Azure Function receiver (Phase 3)
`-- tests/                     Receiver and Databricks tests
```

## Phase Status

| Phase | Status | Deliverables |
|---|---|---|
| 1. Repository and contracts | Implemented | Repository map, versioned JSON Schema, insert/update examples, stable plan artifact |
| 2. Azure infrastructure | Implemented | `azd` configuration, modular Bicep, preflight and Databricks bootstrap scripts |
| 3. Receiver | Implemented | .NET 10 isolated Azure Function, audit Blob idempotency, OpenTelemetry, unit tests |
| 4. Databricks workloads | Implemented | Asset Bundle, source setup, Kafka smoke, CDF publisher, change driver, Spark tests |
| 5. Deployment orchestration | Implemented | Ordered deployment, output handoff, local validation, publisher drain, ownership-aware teardown |
| 6. Verification | Implemented; live proof pending | Resumable insert/update/restart/replay verifier, telemetry and RBAC assertions, JSON/Markdown evidence |

## Deployment Boundary

The POC provisions isolated Azure resources. A regional Unity Catalog metastore is the only shared prerequisite and is never created, deleted, or unassigned by this repository.

No Event Hubs SAS key or secret-bearing application connection string is part of the design. Workload access uses Microsoft Entra identities and Azure RBAC.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with Bicep
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Databricks CLI](https://learn.microsoft.com/azure/databricks/dev-tools/cli/install)
- PowerShell 7
- .NET 10 SDK
- Python 3.11 and OpenJDK 17 for local Spark tests
- Azure subscription deployment and role-assignment permissions
- Databricks account/workspace administration and access to a regional Unity Catalog metastore

## Local Validation

```powershell
python -m pip install -r tests/databricks/requirements.txt
./scripts/test-local.ps1
```

## Deployment

Create/select an `azd` environment, authenticate Azure and Databricks CLI profiles, then set the Databricks job principal:

```powershell
azd auth login
azd env new dev --subscription '<subscription-id>' --location '<azure-region>'
$env:DATABRICKS_ACCOUNT_PROFILE = 'ACCOUNT_ADMIN_PROFILE'
# Optional when Azure CLI/unified auth can authenticate to the provisioned workspace:
$env:DATABRICKS_CONFIG_PROFILE = 'WORKSPACE_PROFILE'
$env:DATABRICKS_JOB_RUN_PRINCIPAL = 'user-or-service-principal-name'
# Optional; defaults to 18.x-scala2.13 and is validated against the workspace:
$env:POC_DATABRICKS_SPARK_VERSION = '18.x-scala2.13'
./scripts/deploy.ps1 -EnvironmentName dev
```

If a workspace profile is supplied, orchestration verifies that its host exactly matches the Bicep-created workspace before any workspace mutation.

The orchestrator provisions Azure, captures Bicep outputs through `azd`, assigns the existing regional metastore, validates and bootstraps Unity Catalog, runs the Kafka credential smoke test, deploys the Function and bundle, runs source setup, and starts the publisher without waiting.

## Verification

After deploying the current infrastructure and bundle, run the Phase 6 proof:

```powershell
./scripts/verify-poc.ps1 -EnvironmentName dev
```

Resume an interrupted proof with `-Resume`. The verifier writes ignored JSON and Markdown artefacts under `evidence/`; it does not deploy resources. No live cloud proof has been run as part of the implementation-only work in this repository.

## Teardown

```powershell
./scripts/teardown.ps1 -EnvironmentName dev -DryRun
./scripts/teardown.ps1 -EnvironmentName dev -ConfirmUnityCatalogDelete -Confirm:$false
```

Teardown never deletes or unassigns the shared regional Unity Catalog metastore. See [scripts/README.md](scripts/README.md) for resume and partial-failure options.