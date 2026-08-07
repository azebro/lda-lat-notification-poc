## Plan: Azure Delta Change Notification POC

Build a fully self-contained Azure POC that proves a synthetic insert or update to a Delta table becomes a replayable changed-row event and is captured by an Azure Function. Follow the research recommendation: Delta Change Data Feed (CDF) -> Azure Databricks Structured Streaming -> Azure Event Hubs Kafka endpoint -> .NET isolated Azure Function -> Application Insights plus an idempotent Blob audit copy. Deploy Azure resources with `azd`/Bicep and Databricks workloads with Databricks Asset Bundles.

**Architecture**
- Source: Unity Catalog Delta table `poc_notifications.main.vehicle_signals` on ADLS Gen2 with CDF enabled.
- Publisher: Azure Databricks Runtime 18 LTS Structured Streaming job, 5-second micro-batches, durable ADLS checkpoint.
- Transport: Event Hubs Standard namespace, event hub `delta-changes`, two partitions, dedicated consumer group `notification-receiver`, Kafka endpoint on port 9093.
- Receiver: Azure Functions v4 on Linux Flex Consumption, .NET 10 isolated worker, Event Hub trigger configured for one event per invocation during the POC.
- Evidence: structured receiver events in Application Insights and one conditionally created JSON blob per deterministic `event_id`; duplicate executions are allowed, duplicate audit blobs are not.
- Identity: Azure Databricks Access Connector managed identity exposed as a Unity Catalog service credential and assigned `Azure Event Hubs Data Sender`; a pre-created Function user-assigned managed identity handles host/deployment storage, receives from Event Hubs, and writes to a separate audit storage account. No Event Hubs SAS policies or connection strings in application settings.
- Network: secured public PaaS endpoints with TLS and Entra RBAC. Private endpoints, custom VNets, and private DNS are intentionally excluded.

**Steps**

### Phase 1: Repository and contracts
1. Create the requested plan artefact at `c:/Github/lda-lat-notification-poc/plan/azure-delta-notification-poc-plan.md` from this approved plan, and add a concise root README that links the research, architecture, deployment, validation, and teardown instructions.
2. Define one versioned JSON event contract shared by publisher, receiver, tests, and documentation. Required fields: `event_id`, `source`, `catalog`, `schema`, `table`, `primary_key`, `change_type`, `commit_version`, `commit_timestamp`, and `payload`. Use synthetic table columns `signal_id`, `vehicle_id`, `signal_type`, `signal_value`, `event_timestamp`, and `updated_at`; define and validate the POC invariant that `signal_id` is non-null and unique, and use it as the Event Hubs partition key.
3. Define deterministic identity as `vehicle_signals-{signal_id}-v{commit_version}-{change_type}`, matching the research. Publish only CDF `insert` and `update_postimage` rows; exclude `update_preimage` and deletes. Treat Event Hubs as at-least-once and make the Blob sink idempotent by using `event_id` as the blob name with an `If-None-Match: *` create condition. A Blob `412 ConditionNotMet` from the failed create condition, or SDK create-only `409 BlobAlreadyExists`, is a successful duplicate outcome; all other persistence failures are retriable.

### Phase 2: Azure infrastructure
4. Scaffold `azure.yaml` and modular Bicep. Parameterize environment name, subscription, region, globally unique name token, Databricks SKU/VM size, and tags; do not hardcode a subscription or region. Preflight provider registration, Flex Consumption region support, Databricks workspace/VM availability, Event Hubs availability, quota, deployment role-assignment permission, and Databricks account/workspace administration.
5. Provision these resources in one `azd` environment:
   - Premium Azure Databricks workspace and Azure Databricks Access Connector with managed identity.
   - ADLS Gen2 storage account for the Unity Catalog managed location, Delta table, and streaming checkpoint.
   - General-purpose v2 storage account for Function host state, deployment package, and Event Hubs trigger checkpoints; deployment uses Flex `functionAppConfig.deployment.storage` rather than legacy run-from-package settings.
   - Separate general-purpose v2 audit storage account with container `delta-change-audit` so receiver evidence permissions stay isolated from Function host state.
   - Event Hubs Standard namespace at one throughput unit, event hub `delta-changes` with two partitions and one-day retention, and consumer group `notification-receiver`.
   - Log Analytics workspace and workspace-based Application Insights.
   - User-assigned managed identity created before the Function app.
   - Linux Functions Flex Consumption plan with 2,048 MB instances, zero always-ready instances, conservative maximum scale, Functions runtime v4, and .NET 10 isolated worker app. Configure runtime, deployment storage, and scaling through Flex `functionAppConfig`, avoiding deprecated app settings.
6. Add identity-based configuration and RBAC in Bicep before creating dependent data-plane resources:
   - Access Connector identity: Storage Blob Data Contributor on the POC data lake and Azure Event Hubs Data Sender on `delta-changes`.
   - Function user-assigned identity: Azure Event Hubs Data Receiver on `delta-changes`; the documented Blob Data Owner, Queue Data Contributor, and Table Data Contributor roles required for identity-based Function host/deployment storage; and Storage Blob Data Contributor scoped to `delta-change-audit` on the audit account. Add Monitoring Metrics Publisher only if the selected Application Insights path requires it.
   - Function settings: `EventHubConnection__fullyQualifiedNamespace`, `EventHubConnection__credential=managedidentity`, `EventHubConnection__clientId`, dedicated consumer group, identity-based `AzureWebJobsStorage__*` settings, audit Blob service URI/container, and Application Insights configuration. No `AzureWebJobsStorage` or Event Hubs connection-string setting.
   - Use capability-based retries with bounded timeouts for RBAC propagation instead of fixed sleeps.
7. Treat Unity Catalog metastore availability as an account-level prerequisite, not a POC-owned resource: preflight an existing or automatically provisioned regional metastore and have an account admin assign the isolated workspace if needed; stop with instructions if none exists. Never create or delete a metastore in POC automation. Split bootstrap into account-plane workspace assignment/binding and workspace-plane creation of the ADLS storage credential, managed location, dedicated catalog/schema, and Event Hubs service credential backed by the Access Connector. Bind the service credential to the workspace and grant the Databricks job run principal `ACCESS` plus the required catalog/schema/table/volume privileges.

### Phase 3: Receiver
8. Create a .NET 10 isolated Functions project using Functions Worker 2.x, the Event Hubs trigger extension, Azure Blob SDK, Azure Identity, System.Text.Json, and one direct worker OpenTelemetry/Azure Monitor export path. Pin compatible stable package versions and commit the lock file; do not also relay the same worker logs through a second telemetry path.
9. Implement the Event Hub-triggered receiver as a small orchestration over testable services and set `maxEventBatchSize=1` for POC clarity:
   - Deserialize each `EventData` body into the event contract and reject missing/invalid required metadata.
   - Emit a named structured processing event containing `event_id`, catalog/schema/table, primary key, change type, commit version, Event Hubs partition, offset, sequence number, and `duplicate` status.
   - Persist the original canonical JSON to `events/{catalog}/{schema}/{table}/{yyyy/MM/dd}/{event_id}.json` using the user-assigned identity and conditional create.
   - Catch only Blob `412 ConditionNotMet` from `If-None-Match: *`, plus SDK create-only `409 BlobAlreadyExists`, as successfully handled duplicates; propagate malformed messages and all other storage failures into the configured bounded retry policy. After retries are exhausted, the Event Hubs partition pointer advances, so poison-event quarantine remains explicitly outside the POC scope.
10. Configure Application Insights so receiver custom events have one unambiguous emission path and can be queried independently of host trigger telemetry. Keep poison handling explicit: the POC logs and retries, while a production quarantine/DLQ strategy remains out of scope because Event Hubs has no native DLQ.
11. Add unit tests for valid/invalid envelope parsing, deterministic audit paths, conditional-create duplicate behavior including `412 ConditionNotMet` and `409 BlobAlreadyExists`, structured metadata extraction, and cancellation/error propagation. Use an interface around Blob persistence so normal unit tests require no Azure services.

### Phase 4: Databricks workloads
12. Create a Databricks Asset Bundle with a development target, workspace variables sourced from Bicep outputs, and three jobs/notebooks:
   - `setup_source`: idempotently creates catalog `poc_notifications`, schema `main`, the stable checkpoint path, and empty CDF-enabled table `poc_notifications.main.vehicle_signals`; it validates the non-null/unique `signal_id` invariant.
   - `cdf_publisher`: continuous Structured Streaming job on a single-node, cost-conscious Databricks Runtime 18 LTS job cluster, deliberately kept running only during the demonstration window so a source write causes notification without a manual publisher invocation.
   - `drive_change`: parameterized validation notebook with deterministic `insert` and single-row `update` operations over synthetic rows. After each commit, query Delta history and return JSON job output containing `signal_id`, `commit_version`, `change_type`, and expected `event_id` for the verifier.
13. In the publisher, read the table with `readChangeFeed=true`, filter to `insert` and `update_postimage`, build the standard envelope with the complete changed row under `payload`, serialize UTF-8 canonical JSON, and project columns exactly as `CAST(signal_id AS STRING) AS key` and `CAST(envelope_json AS STRING) AS value`; the topic is a writer option. This keeps changes for the same row on one partition.
14. Write the stream to the Event Hubs Kafka endpoint on port 9093 with `databricks.serviceCredential`, topic `delta-changes`, append mode, a 5-second processing trigger, and a stable checkpoint path under the POC ADLS location. Per current Azure Databricks guidance for Runtime 16.1+, do not combine `databricks.serviceCredential` with manual `kafka.sasl.*` options. Keep table, endpoint, service credential, and checkpoint values parameterized through bundle variables, and run a one-message batch-write smoke test through the same service credential before starting the stream.
15. Make reset behavior deliberate: setup starts with an empty table before the first publisher run; a clean reset stops the publisher and removes both the table data and its checkpoint together. Never clear a checkpoint independently of the source and Event Hubs evidence because that would intentionally replay CDF rows.
16. Add PySpark-facing tests for the pure envelope transformation, deterministic ID, unique-key invariant, and CDF change-type filter using small local/static DataFrames where practical. Validate the deployed notebook/job definitions with `databricks bundle validate` and a setup job run.

### Phase 5: Deployment orchestration
17. Configure `azd` hooks or PowerShell orchestration with this dependency order: validate local tools/providers/region/SKU/quota/permissions -> Bicep provision -> capability-poll RBAC -> account-plane workspace/metastore preflight and assignment -> `databricks bundle validate` -> workspace-plane Unity Catalog/service-credential bootstrap and privilege grants -> one-message Kafka credential smoke test -> build/test/deploy Function -> bundle deploy -> run `setup_source` -> start `cdf_publisher` without waiting for its continuous run to terminate.
18. Surface Bicep outputs into `azd` environment values and bundle variables without writing credentials to source files. Fail early with actionable messages for missing providers, unsupported region/SKU, absent role-assignment or Log Analytics/Blob verification rights, absent Databricks account/workspace administration, unavailable Flex quota, or failed data-plane capability polls.
19. Provide ownership-aware, retryable teardown with a dry run and explicit phases: stop the stream and wait for cluster shutdown; destroy bundle jobs/files; remove only tagged POC table/schema/catalog, managed location/storage credential, and service credential objects; verify no references remain; then run `azd down --purge`. Never delete or unassign the account metastore. Require explicit confirmation before destructive Unity Catalog cleanup and support rerunning after partial failure.

### Phase 6: Verification and proof
20. Run static/local checks before Azure deployment: Bicep build/lint, `azd` environment validation/preview where supported, .NET restore/build/unit tests, Databricks bundle validation, and Python lint/unit tests for pure transformations.
21. Execute the insert proof with a unique `signal_id`: run `drive_change` in `insert` mode, read its returned commit metadata/expected ID, poll Blob evidence for up to five minutes, and assert exactly one unique audit blob exists for that `event_id`; its body has `change_type=insert`, the expected primary key, full synthetic payload, and matching commit metadata. Poll Application Insights separately for up to ten minutes and assert at least one processing event with matching partition/sequence dimensions; duplicate executions/logs are valid.
22. Execute the update proof against the same row: run `drive_change` in `update` mode with a changed value, consume its returned commit metadata, then assert one new unique audit blob with `change_type=update_postimage`, a strictly greater `commit_version`, the new payload value, and no `update_preimage` audit blob.
23. Execute checkpoint/idempotency proof: stop and restart `cdf_publisher` with the same checkpoint and no source change, then assert no new unique audit blob appears. A duplicate delivery/log is allowed and must resolve as `duplicate=true`. Independently resend one already captured envelope through a test helper and assert the blob count remains one while telemetry records the duplicate.
24. Execute security/configuration proof: inspect Function settings and Databricks job configuration to confirm no Event Hubs connection string, SAS key, or manual Kafka secret is present; verify the Access Connector and Function user-assigned identities have only the selected sender/receiver/host/audit data roles at their documented scopes.
25. Capture a concise evidence record containing the two source commits, corresponding event IDs, unique Blob paths, KQL query/results, any duplicate execution observations, measured end-to-end latency, publisher checkpoint path, deployed resource names, and security assertions. This is the POC completion artefact.

**Relevant files**
- `c:/Github/lda-lat-notification-poc/research/research.md` — source recommendation and patterns; preserve unchanged.
- `c:/Github/lda-lat-notification-poc/plan/azure-delta-notification-poc-plan.md` — requested approved plan artefact.
- `c:/Github/lda-lat-notification-poc/azure.yaml` — `azd` services, environment variables, and ordered hooks.
- `c:/Github/lda-lat-notification-poc/infra/main.bicep` — composition root and outputs.
- `c:/Github/lda-lat-notification-poc/infra/modules/databricks.bicep` — workspace and Access Connector.
- `c:/Github/lda-lat-notification-poc/infra/modules/messaging.bicep` — Event Hubs namespace, hub, and consumer group.
- `c:/Github/lda-lat-notification-poc/infra/modules/storage.bicep` — ADLS and Function/audit storage.
- `c:/Github/lda-lat-notification-poc/infra/modules/receiver.bicep` — Flex Consumption Function, monitoring, settings, and identities.
- `c:/Github/lda-lat-notification-poc/infra/modules/rbac.bicep` — narrowly scoped role assignments.
- `c:/Github/lda-lat-notification-poc/databricks/databricks.yml` — bundle targets and variables.
- `c:/Github/lda-lat-notification-poc/databricks/resources/jobs.yml` — setup, publisher, and change-driver jobs.
- `c:/Github/lda-lat-notification-poc/databricks/src/setup_source.py` — catalog/schema/table/CDF bootstrap.
- `c:/Github/lda-lat-notification-poc/databricks/src/publish_cdf.py` — CDF filtering, envelope creation, and Kafka sink.
- `c:/Github/lda-lat-notification-poc/databricks/src/drive_change.py` — parameterized synthetic insert/update notebook.
- `c:/Github/lda-lat-notification-poc/src/receiver/DeltaNotificationReceiver.csproj` — .NET 10 isolated Function project.
- `c:/Github/lda-lat-notification-poc/src/receiver/Functions/DeltaChangeReceiver.cs` — Event Hub trigger orchestration.
- `c:/Github/lda-lat-notification-poc/src/receiver/Models/DeltaChangeEnvelope.cs` — shared receiver contract.
- `c:/Github/lda-lat-notification-poc/src/receiver/Services/BlobAuditWriter.cs` — managed-identity conditional Blob persistence.
- `c:/Github/lda-lat-notification-poc/tests/receiver/` — receiver unit tests.
- `c:/Github/lda-lat-notification-poc/tests/databricks/` — envelope/filter transformation tests.
- `c:/Github/lda-lat-notification-poc/scripts/bootstrap-databricks.ps1` — idempotent Unity Catalog/service credential setup.
- `c:/Github/lda-lat-notification-poc/scripts/verify-poc.ps1` — insert/update, Blob, KQL, checkpoint, and RBAC assertions.
- `c:/Github/lda-lat-notification-poc/scripts/teardown.ps1` — ordered, ownership-aware cleanup.

**Verification**
1. `az bicep build --file infra/main.bicep` and configured Bicep lint checks succeed.
2. `dotnet restore`, `dotnet build --no-restore`, and `dotnet test --no-build` succeed for the receiver and its tests.
3. Python transformation tests and lint checks succeed without Azure dependencies.
4. `databricks bundle validate -t dev` succeeds, followed by successful `setup_source` and continuous publisher starts.
5. The deployed insert, update, restart, idempotency, telemetry, Blob evidence, and RBAC assertions in steps 21-24 pass.
6. Teardown removes POC-owned resources and Unity Catalog objects without touching any pre-existing account-level metastore.

**Decisions**
- Fully isolated Azure POC workspace, data, messaging, receiver, and monitoring resources; no dependency on an existing Delta table or workspace. An account-level regional Unity Catalog metastore is the sole shared prerequisite because Azure Databricks permits account-level metastore ownership outside the POC resource group.
- Event Hubs and an Event Hub-triggered Function, matching the research recommendation. Logic Apps, Event Grid, and Service Bus are excluded.
- Application Insights plus durable Blob evidence.
- One unique logical event/audit blob per update by publishing only `update_postimage`; duplicate deliveries or Function executions remain valid under at-least-once semantics.
- Standard envelope plus complete synthetic row payload.
- Parameterized Databricks notebook/job drives inserts and updates.
- `azd`/Bicep for Azure infrastructure and Databricks Asset Bundles for workspace workloads.
- Entra identity-first authentication; Unity Catalog service credential for Databricks and a Function user-assigned managed identity; no Event Hubs SAS.
- Secured public endpoints for the POC.
- Receiver implemented in .NET 10 isolated worker on Flex Consumption.
- JSON only, one sample table, at-least-once transport with idempotent capture.

**Scope boundaries**
- Included: repeatable deployment and teardown, synthetic insert/update, CDF, Event Hubs, Function receiver, durable evidence, telemetry, focused tests, and security assertions.
- Excluded: deletes, schema evolution, Schema Registry/Avro, real or sensitive data, private networking, production DLQ/quarantine, Service Bus fan-out, Logic Apps, CI/CD pipelines, load/performance testing, multi-region DR, and production SLOs.

**Prerequisites and risks**
- Required locally: Azure CLI, Azure Developer CLI, Bicep, .NET 10 SDK, Azure Functions Core Tools 4, current Databricks CLI, PowerShell 7, and Python tooling used by tests.
- Required permissions: subscription/resource-group deployment and role-assignment rights; Blob Data Reader and Log Analytics Reader for the verifier; and Databricks account-admin/workspace-admin rights for metastore assignment, workspace binding, service credentials, and grants.
- The selected Azure region must support Databricks, the chosen VM SKU, and Functions Flex Consumption, and the subscription must have quota and an available Unity Catalog regional metastore.
- Event Hubs is at-least-once and has no native DLQ; deterministic IDs and conditional Blob creation handle duplicates, but poison-message quarantine is deliberately deferred.
- One-day Event Hubs retention is sufficient only for a fresh POC run; restart evidence must be completed within that window or the environment must be reset cleanly.
- A continuous Databricks job is the dominant POC cost. Use a single-node job cluster, stop it when not demonstrating, and run teardown promptly.
- POC-created Unity Catalog objects require ownership tags and ordered cleanup; automation must never delete or unassign the shared regional metastore.

**Alignment record (10/10)**
1. Fully self-contained POC.
2. Event Hub-triggered Function receiver.
3. Application Insights plus Blob audit evidence.
4. Update post-image only.
5. Full row nested in the standard envelope.
6. Databricks validation notebook/job drives changes.
7. `azd`/Bicep plus Databricks Asset Bundles.
8. Entra identity-first authentication.
9. Secured public endpoints.
10. .NET isolated worker receiver.