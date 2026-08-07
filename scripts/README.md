# Automation Scripts

- `preflight.ps1` validates local tooling, Azure authentication, provider registration, and Flex Consumption region support.
- `test-local.ps1` runs Bicep/contract validation, receiver build/tests, Ruff, Python compilation, and Spark 4.1 tests.
- `deploy.ps1` executes the approved dependency order from Azure preflight through nonblocking publisher start.
- `verify-poc.ps1` runs the resumable Phase 6 insert, update, restart, replay, telemetry, configuration, and RBAC proof.
- `bootstrap-databricks.ps1` performs idempotent `Account`, `Workspace`, or `All` Unity Catalog bootstrap phases.
- `teardown.ps1` drains the publisher, destroys bundle state, deletes only ownership-verified Unity Catalog objects, and runs `azd down --purge`.
- `validate-contract.ps1` validates all checked-in event examples against the v1 JSON Schema.
- `phase5-common.ps1` contains shared environment/output and CLI helpers.

## Deploy

```powershell
$env:DATABRICKS_ACCOUNT_PROFILE = 'ACCOUNT_ADMIN_PROFILE'
$env:DATABRICKS_CONFIG_PROFILE = 'WORKSPACE_PROFILE' # optional; host is validated when set
$env:DATABRICKS_JOB_RUN_PRINCIPAL = 'user-or-service-principal-name'
./scripts/deploy.ps1 -EnvironmentName dev
```

Deployment stages are idempotent where the underlying platform permits. To resume after a partial failure, rerun the command and use the narrow skip switches only for stages already proven complete:

- `-SkipLocalValidation`
- `-SkipProvision`
- `-SkipSmokeTest`
- `-SkipReceiverDeploy`
- `-SkipBundleDeploy`
- `-SkipSetup`
- `-SkipPublisherStart`

The smoke stage partially deploys only `kafka_smoke`, sends one deterministic event through `databricks.serviceCredential`, and then the full bundle deployment follows.

## Verify

Deploy the current Bicep and bundle first so the Phase 6 identity outputs and `replay_event` job exist, then run:

```powershell
./scripts/verify-poc.ps1 -EnvironmentName dev
```

The verifier runs local checks, uses Azure CLI login authentication for Blob and Log Analytics reads, invokes Databricks jobs through unified authentication, and writes ignored JSON/Markdown evidence under `evidence/`. It never deploys infrastructure.

If a job, Blob, or telemetry poll fails after state is saved, resume the same proof without creating another source change:

```powershell
./scripts/verify-poc.ps1 -EnvironmentName dev -Resume
```

Use `-SkipLocalValidation` or `-SkipAzdPreview` only when those checks have already passed independently. Run the cloud-free helper tests with `./scripts/verify-poc.ps1 -EnvironmentName self-test -SelfTest`.

## Teardown

Always preview first:

```powershell
./scripts/teardown.ps1 -EnvironmentName dev -DryRun
```

Execute after reviewing the dry run:

```powershell
./scripts/teardown.ps1 -EnvironmentName dev -ConfirmUnityCatalogDelete -Confirm:$false
```

The explicit Unity Catalog switch is required in addition to PowerShell confirmation. No force-delete flags are used for catalogs, schemas, external locations, or credentials; unexpected references stop cleanup. For Azure-only retry after Databricks cleanup succeeded, pass `-SkipPublisherDrain -SkipBundleDestroy -SkipUnityCatalogCleanup`.