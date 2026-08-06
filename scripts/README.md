# Automation Scripts

- `preflight.ps1` validates local tooling, Azure authentication, provider registration, and Flex Consumption region support.
- `bootstrap-databricks.ps1` performs idempotent Unity Catalog account/workspace bootstrap after Azure resources and RBAC are deployed.
- `validate-contract.ps1` validates all checked-in event examples against the v1 JSON Schema.

Phase 5 will add ordered deployment, verification, and teardown orchestration.