[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspaceProfile = $env:DATABRICKS_CONFIG_PROFILE,
    [string]$AccountProfile = $env:DATABRICKS_ACCOUNT_PROFILE,
    [string]$WorkspaceId = $env:AZURE_DATABRICKS_WORKSPACE_ID,
    [string]$MetastoreId = $env:DATABRICKS_METASTORE_ID,
    [string]$AccessConnectorId = $env:AZURE_DATABRICKS_ACCESS_CONNECTOR_ID,
    [string]$StorageAccountName = $env:AZURE_DATA_LAKE_ACCOUNT_NAME,
    [string]$ContainerName = $env:AZURE_DATA_LAKE_CONTAINER_NAME,
    [string]$DatabricksNodeType = $env:AZURE_DATABRICKS_NODE_TYPE,
    [string]$NameToken = $env:AZURE_NAME_TOKEN,
    [string]$JobRunPrincipal = $env:DATABRICKS_JOB_RUN_PRINCIPAL,
    [string]$CatalogName = 'poc_notifications',
    [string]$SchemaName = 'main',
    [string]$StorageCredentialName = '',
    [string]$ExternalLocationName = '',
    [string]$ServiceCredentialName = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) {
    throw 'Databricks CLI is required.'
}

$requiredValues = @{
    WorkspaceId = $WorkspaceId
    AccessConnectorId = $AccessConnectorId
    StorageAccountName = $StorageAccountName
    ContainerName = $ContainerName
    DatabricksNodeType = $DatabricksNodeType
    NameToken = $NameToken
    JobRunPrincipal = $JobRunPrincipal
}

$StorageCredentialName = if ($StorageCredentialName) { $StorageCredentialName } else { "delta_notification_storage_$NameToken" }
$ExternalLocationName = if ($ExternalLocationName) { $ExternalLocationName } else { "delta_notification_location_$NameToken" }
$ServiceCredentialName = if ($ServiceCredentialName) { $ServiceCredentialName } else { "delta_notification_event_hubs_$NameToken" }
$ownershipMarker = "poc-owner:$NameToken"

$missingValues = @($requiredValues.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace($_.Value) } | ForEach-Object Key)
if ($missingValues.Count -gt 0) {
    throw "Missing required values: $($missingValues -join ', '). Load azd outputs and set DATABRICKS_JOB_RUN_PRINCIPAL."
}

$profileArgs = if ([string]::IsNullOrWhiteSpace($WorkspaceProfile)) { @() } else { @('--profile', $WorkspaceProfile) }

function Invoke-Databricks {
    param([string[]]$Arguments, [switch]$AllowFailure)

    & databricks @Arguments @profileArgs
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "Databricks command failed: databricks $($Arguments -join ' ')"
    }
}

function Test-DatabricksObject {
    param([string[]]$Arguments)
    & databricks @Arguments @profileArgs *> $null
    return $LASTEXITCODE -eq 0
}

function Get-DatabricksObject {
    param([string[]]$Arguments)

    $result = & databricks @Arguments @profileArgs --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return $result | ConvertFrom-Json
}

function Assert-OwnedObject {
    param(
        [string]$Description,
        [object]$Object
    )

    if ($Object -and $Object.comment -ne $ownershipMarker) {
        throw "$Description already exists but is not owned by this POC environment ($ownershipMarker). Refusing to mutate it."
    }
}

function Invoke-CapabilityRetry {
    param(
        [string]$Description,
        [scriptblock]$Operation,
        [int]$MaximumAttempts = 12
    )

    $delaySeconds = 5
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            & $Operation
            return
        }
        catch {
            if ($attempt -eq $MaximumAttempts) {
                throw "Timed out waiting for $Description after $MaximumAttempts attempts. $($_.Exception.Message)"
            }

            Write-Warning "$Description is not ready (attempt $attempt/$MaximumAttempts): $($_.Exception.Message)"
            Start-Sleep -Seconds $delaySeconds
            $delaySeconds = [Math]::Min($delaySeconds + 5, 30)
        }
    }
}

$currentUser = Invoke-Databricks @('current-user', 'me', '--output', 'json') | ConvertFrom-Json
if ($JobRunPrincipal -ne $currentUser.userName) {
    throw "DATABRICKS_JOB_RUN_PRINCIPAL must identify the bundle deployment identity ($($currentUser.userName)) because Phase 4 jobs run as the current bundle user."
}

if (-not (Test-DatabricksObject @('metastores', 'current'))) {
    if ([string]::IsNullOrWhiteSpace($AccountProfile) -or [string]::IsNullOrWhiteSpace($MetastoreId)) {
        throw 'The workspace has no metastore assignment. Set DATABRICKS_ACCOUNT_PROFILE and DATABRICKS_METASTORE_ID, or assign the regional metastore as a Databricks account admin.'
    }

    if ($PSCmdlet.ShouldProcess("workspace $WorkspaceId", "assign metastore $MetastoreId")) {
        & databricks account metastore-assignments create $WorkspaceId $MetastoreId --profile $AccountProfile
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to assign the Unity Catalog metastore.'
        }
    }
}

$nodeTypes = Invoke-Databricks @('clusters', 'list-node-types', '--output', 'json') | ConvertFrom-Json
if (@($nodeTypes.node_types | Where-Object node_type_id -eq $DatabricksNodeType).Count -eq 0) {
    throw "Databricks node type $DatabricksNodeType is not supported by this workspace."
}

$managedRoot = "abfss://$ContainerName@$StorageAccountName.dfs.core.windows.net/managed"
$storageCredentialBody = @{
    comment = $ownershipMarker
    azure_managed_identity = @{
        access_connector_id = $AccessConnectorId
    }
} | ConvertTo-Json -Depth 4 -Compress

$existingStorageCredential = Get-DatabricksObject @('credentials', 'get-credential', $StorageCredentialName)
Assert-OwnedObject -Description "Storage credential $StorageCredentialName" -Object $existingStorageCredential
if (-not $existingStorageCredential) {
    Invoke-Databricks @('credentials', 'create-credential', $StorageCredentialName, '--purpose', 'STORAGE', '--json', $storageCredentialBody)
}

$existingExternalLocation = Get-DatabricksObject @('external-locations', 'get', $ExternalLocationName)
Assert-OwnedObject -Description "External location $ExternalLocationName" -Object $existingExternalLocation
if (-not $existingExternalLocation) {
    Invoke-CapabilityRetry -Description 'Access Connector access to ADLS Gen2' -Operation {
        Invoke-Databricks @('external-locations', 'create', $ExternalLocationName, $managedRoot, $StorageCredentialName, '--comment', $ownershipMarker)
    }
}

$existingCatalog = Get-DatabricksObject @('catalogs', 'get', $CatalogName)
Assert-OwnedObject -Description "Catalog $CatalogName" -Object $existingCatalog
if (-not $existingCatalog) {
    Invoke-Databricks @('catalogs', 'create', $CatalogName, '--storage-root', $managedRoot, '--comment', $ownershipMarker)
}

$existingSchema = Get-DatabricksObject @('schemas', 'get', "$CatalogName.$SchemaName")
Assert-OwnedObject -Description "Schema $CatalogName.$SchemaName" -Object $existingSchema
if (-not $existingSchema) {
    Invoke-Databricks @('schemas', 'create', $SchemaName, $CatalogName, '--comment', $ownershipMarker)
}

$serviceCredentialBody = @{
    comment = $ownershipMarker
    azure_managed_identity = @{
        access_connector_id = $AccessConnectorId
    }
} | ConvertTo-Json -Depth 4 -Compress

$existingServiceCredential = Get-DatabricksObject @('credentials', 'get-credential', $ServiceCredentialName)
Assert-OwnedObject -Description "Service credential $ServiceCredentialName" -Object $existingServiceCredential
if (-not $existingServiceCredential) {
    Invoke-Databricks @('credentials', 'create-credential', $ServiceCredentialName, '--purpose', 'SERVICE', '--json', $serviceCredentialBody)
}

Invoke-Databricks @('credentials', 'update-credential', $StorageCredentialName, '--isolation-mode', 'ISOLATION_MODE_ISOLATED')
Invoke-Databricks @('credentials', 'update-credential', $ServiceCredentialName, '--isolation-mode', 'ISOLATION_MODE_ISOLATED')

$bindingBody = @{
    bindings = @(
        @{
            workspace_id = [long]$WorkspaceId
            binding_type = 'BINDING_TYPE_READ_WRITE'
        }
    )
} | ConvertTo-Json -Depth 4 -Compress

Invoke-Databricks @('workspace-bindings', 'update-bindings', 'credential', $ServiceCredentialName, '--json', $bindingBody)
Invoke-Databricks @('workspace-bindings', 'update-bindings', 'storage_credential', $StorageCredentialName, '--json', $bindingBody)
Invoke-Databricks @('workspace-bindings', 'update-bindings', 'external_location', $ExternalLocationName, '--json', $bindingBody)
Invoke-Databricks @('workspace-bindings', 'update-bindings', 'catalog', $CatalogName, '--json', $bindingBody)

$credentialGrant = @{
    changes = @(
        @{
            principal = $JobRunPrincipal
            add = @('ACCESS')
        }
    )
} | ConvertTo-Json -Depth 4 -Compress

$catalogGrant = @{
    changes = @(
        @{
            principal = $JobRunPrincipal
            add = @('USE_CATALOG')
        }
    )
} | ConvertTo-Json -Depth 4 -Compress

$schemaGrant = @{
    changes = @(
        @{
            principal = $JobRunPrincipal
            add = @('USE_SCHEMA', 'CREATE_TABLE', 'CREATE_VOLUME')
        }
    )
} | ConvertTo-Json -Depth 4 -Compress

Invoke-Databricks @('grants', 'update', 'credential', $ServiceCredentialName, '--json', $credentialGrant)
Invoke-Databricks @('grants', 'update', 'catalog', $CatalogName, '--json', $catalogGrant)
Invoke-Databricks @('grants', 'update', 'schema', "$CatalogName.$SchemaName", '--json', $schemaGrant)

Invoke-CapabilityRetry -Description 'Unity Catalog storage credential validation' -Operation {
    Invoke-Databricks @('credentials', 'validate-credential', '--credential-name', $StorageCredentialName, '--purpose', 'STORAGE', '--url', $managedRoot)
}

Invoke-CapabilityRetry -Description 'Unity Catalog service credential validation' -Operation {
    Invoke-Databricks @('credentials', 'validate-credential', '--credential-name', $ServiceCredentialName, '--purpose', 'SERVICE')
}

Write-Host 'Databricks account/workspace bootstrap completed.'