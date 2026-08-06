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
- [Teardown design](plan.md#phase-5-deployment-orchestration)

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
| 3. Receiver | Planned | .NET 10 isolated Azure Function |
| 4. Databricks workloads | Planned | Asset Bundle, source setup, CDF publisher, change driver |
| 5. Deployment orchestration | Planned | Ordered deployment and teardown automation |
| 6. Verification | Planned | Insert, update, restart, idempotency, telemetry, and RBAC evidence |

## Deployment Boundary

The POC provisions isolated Azure resources. A regional Unity Catalog metastore is the only shared prerequisite and is never created, deleted, or unassigned by this repository.

No Event Hubs SAS key or secret-bearing application connection string is part of the design. Workload access uses Microsoft Entra identities and Azure RBAC.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with Bicep
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Databricks CLI](https://learn.microsoft.com/azure/databricks/dev-tools/cli/install)
- PowerShell 7
- .NET 10 SDK
- Azure subscription deployment and role-assignment permissions
- Databricks account/workspace administration and access to a regional Unity Catalog metastore

The current machine is missing `azd` and the Databricks CLI. Install them before provisioning.

## Phase 2 Validation

```powershell
az bicep build --file infra/main.bicep
./scripts/validate-contract.ps1
./scripts/preflight.ps1
```

After prerequisites and Azure authentication are ready:

```powershell
azd auth login
azd up
```

The Databricks bootstrap is intentionally a separate account/workspace-plane operation. Load the `azd` outputs, set `DATABRICKS_JOB_RUN_PRINCIPAL`, and run:

```powershell
./scripts/bootstrap-databricks.ps1
```

See [infra/README.md](infra/README.md) for module boundaries and deployment outputs.

Phase 5 will add the executable ownership-aware teardown script. Until then, follow the ordered teardown design in [plan.md](plan.md#phase-5-deployment-orchestration); do not delete the shared regional Unity Catalog metastore.