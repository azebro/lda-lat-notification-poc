[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspaceProfile = $env:DATABRICKS_CONFIG_PROFILE,
    [string]$AccountProfile = $env:DATABRICKS_ACCOUNT_PROFILE,
    [string]$WorkspaceId = $env:AZURE_DATABRICKS_WORKSPACE_ID,
    [string]$WorkspaceUrl = $env:AZURE_DATABRICKS_WORKSPACE_URL,
    [string]$MetastoreId = $env:DATABRICKS_METASTORE_ID,
    [string]$AccessConnectorId = $env:AZURE_DATABRICKS_ACCESS_CONNECTOR_ID,
    [string]$StorageAccountName = $env:AZURE_DATA_LAKE_ACCOUNT_NAME,
    [string]$ContainerName = $env:AZURE_DATA_LAKE_CONTAINER_NAME,
    [string]$DatabricksNodeType = $env:AZURE_DATABRICKS_NODE_TYPE,
    [string]$SparkVersion = $env:BUNDLE_VAR_spark_version,
    [string]$NameToken = $env:AZURE_NAME_TOKEN,
    [string]$JobRunPrincipal = $env:DATABRICKS_JOB_RUN_PRINCIPAL,
    [string]$CatalogName = 'poc_notifications',
    [string]$SchemaName = 'main',
    [string]$StorageCredentialName = '',
    [string]$ExternalLocationName = '',
    [string]$ServiceCredentialName = '',
    [ValidateSet('All', 'Account', 'Workspace')]
    [string]$Phase = 'All'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/phase5-common.ps1"

if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) {
    throw 'Databricks CLI is required.'
}

$StorageCredentialName = if ($StorageCredentialName) { $StorageCredentialName } else { "delta_notification_storage_$NameToken" }
$ExternalLocationName = if ($ExternalLocationName) { $ExternalLocationName } else { "delta_notification_location_$NameToken" }
$ServiceCredentialName = if ($ServiceCredentialName) { $ServiceCredentialName } else { "delta_notification_event_hubs_$NameToken" }
$ownershipMarker = "poc-owner:$NameToken"

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
    $result = & databricks @Arguments @profileArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    $text = ($result | Out-String).Trim()
    if ($text -match '(?i)\bRESOURCE_DOES_NOT_EXIST\b|\bNOT_FOUND\b|\bHTTP\s*404\b|\bstatus(?: code)?\s*404\b') {
        return $false
    }
    throw "Databricks existence check failed: databricks $($Arguments -join ' ')`n$text"
}

function Get-DatabricksObject {
    param([string[]]$Arguments)

    $result = & databricks @Arguments @profileArgs --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($result | Out-String).Trim()
        if ($text -match '(?i)\bRESOURCE_DOES_NOT_EXIST\b|\bNOT_FOUND\b|\bHTTP\s*404\b|\bstatus(?: code)?\s*404\b') {
            return $null
        }
        throw "Databricks lookup failed: databricks $($Arguments -join ' ')`n$text"
    }

    return $result | ConvertFrom-Json
}

function Assert-OwnedObject {
    param(
        [string]$Description,
        [object]$Object
    )

    $commentProperty = if ($Object) { $Object.PSObject.Properties['comment'] } else { $null }
    $comment = if ($commentProperty) { [string]$commentProperty.Value } else { $null }
    if ($Object -and $comment -ne $ownershipMarker) {
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

if ([string]::IsNullOrWhiteSpace($WorkspaceUrl)) {
    throw 'AZURE_DATABRICKS_WORKSPACE_URL is required to verify the workspace target before bootstrap.'
}
$expectedWorkspaceHost = if ($WorkspaceUrl -match '^https://') { $WorkspaceUrl } else { "https://$WorkspaceUrl" }
Assert-PocDatabricksWorkspace -DatabricksPath (Assert-PocTool -Name 'databricks') -ExpectedHost $expectedWorkspaceHost -Profile $WorkspaceProfile

if ($Phase -in @('All', 'Account')) {
    if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        throw 'AZURE_DATABRICKS_WORKSPACE_ID is required for the account-plane phase.'
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
            Invoke-CapabilityRetry -Description 'workspace metastore assignment' -Operation {
                if (-not (Test-DatabricksObject @('metastores', 'current'))) {
                    throw 'The workspace metastore assignment is not visible yet.'
                }
            }
        }
    }

    Write-Host 'Databricks account-plane bootstrap completed.'
    if ($Phase -eq 'Account') {
        return
    }
}

$requiredWorkspaceValues = @{
    AccessConnectorId = $AccessConnectorId
    StorageAccountName = $StorageAccountName
    ContainerName = $ContainerName
    DatabricksNodeType = $DatabricksNodeType
    SparkVersion = $SparkVersion
    NameToken = $NameToken
    JobRunPrincipal = $JobRunPrincipal
    WorkspaceId = $WorkspaceId
}
$missingWorkspaceValues = @($requiredWorkspaceValues.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace($_.Value) } | ForEach-Object Key)
if ($missingWorkspaceValues.Count -gt 0) {
    throw "Missing workspace-plane values: $($missingWorkspaceValues -join ', '). Load azd outputs and set DATABRICKS_JOB_RUN_PRINCIPAL."
}

$currentUser = Invoke-Databricks @('current-user', 'me', '--output', 'json') | ConvertFrom-Json
if ($JobRunPrincipal -ne $currentUser.userName) {
    throw "DATABRICKS_JOB_RUN_PRINCIPAL must identify the bundle deployment identity ($($currentUser.userName)) because Phase 4 jobs run as the current bundle user."
}

$nodeTypes = Invoke-Databricks @('clusters', 'list-node-types', '--output', 'json') | ConvertFrom-Json
if (@($nodeTypes.node_types | Where-Object node_type_id -eq $DatabricksNodeType).Count -eq 0) {
    throw "Databricks node type $DatabricksNodeType is not supported by this workspace."
}

$sparkVersions = Invoke-Databricks @('clusters', 'spark-versions', '--output', 'json') | ConvertFrom-Json
$sparkVersionKeys = @($sparkVersions.versions | ForEach-Object { [string]$_.key })
if ($SparkVersion -notin $sparkVersionKeys) {
    $candidates = @($sparkVersionKeys | Where-Object { $_ -match 'scala' } | Sort-Object) -join ', '
    throw "Databricks Runtime '$SparkVersion' is not offered by this workspace. Set POC_DATABRICKS_SPARK_VERSION to one of: $candidates."
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
    if ($PSCmdlet.ShouldProcess("storage credential $StorageCredentialName", 'create')) {
        Invoke-Databricks @('credentials', 'create-credential', $StorageCredentialName, '--purpose', 'STORAGE', '--json', $storageCredentialBody)
    }
}

$existingExternalLocation = Get-DatabricksObject @('external-locations', 'get', $ExternalLocationName)
Assert-OwnedObject -Description "External location $ExternalLocationName" -Object $existingExternalLocation
if (-not $existingExternalLocation) {
    if ($PSCmdlet.ShouldProcess("external location $ExternalLocationName", 'create')) {
        Invoke-CapabilityRetry -Description 'Access Connector access to ADLS Gen2' -Operation {
            Invoke-Databricks @('external-locations', 'create', $ExternalLocationName, $managedRoot, $StorageCredentialName, '--comment', $ownershipMarker)
        }
    }
}

$existingCatalog = Get-DatabricksObject @('catalogs', 'get', $CatalogName)
Assert-OwnedObject -Description "Catalog $CatalogName" -Object $existingCatalog
if (-not $existingCatalog) {
    if ($PSCmdlet.ShouldProcess("catalog $CatalogName", 'create')) {
        Invoke-Databricks @('catalogs', 'create', $CatalogName, '--storage-root', $managedRoot, '--comment', $ownershipMarker)
    }
}

$existingSchema = Get-DatabricksObject @('schemas', 'get', "$CatalogName.$SchemaName")
Assert-OwnedObject -Description "Schema $CatalogName.$SchemaName" -Object $existingSchema
if (-not $existingSchema) {
    if ($PSCmdlet.ShouldProcess("schema $CatalogName.$SchemaName", 'create')) {
        Invoke-Databricks @('schemas', 'create', $SchemaName, $CatalogName, '--comment', $ownershipMarker)
    }
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
    if ($PSCmdlet.ShouldProcess("service credential $ServiceCredentialName", 'create')) {
        Invoke-Databricks @('credentials', 'create-credential', $ServiceCredentialName, '--purpose', 'SERVICE', '--json', $serviceCredentialBody)
    }
}

if ($PSCmdlet.ShouldProcess('Databricks storage and service credentials', 'set isolated workspace mode')) {
    Invoke-Databricks @('credentials', 'update-credential', $StorageCredentialName, '--isolation-mode', 'ISOLATION_MODE_ISOLATED')
    Invoke-Databricks @('credentials', 'update-credential', $ServiceCredentialName, '--isolation-mode', 'ISOLATION_MODE_ISOLATED')
}

$bindingBody = @{
    bindings = @(
        @{
            workspace_id = [long]$WorkspaceId
            binding_type = 'BINDING_TYPE_READ_WRITE'
        }
    )
} | ConvertTo-Json -Depth 4 -Compress

if ($PSCmdlet.ShouldProcess("workspace $WorkspaceId", 'bind POC Unity Catalog securables')) {
    Invoke-Databricks @('workspace-bindings', 'update-bindings', 'credential', $ServiceCredentialName, '--json', $bindingBody)
    Invoke-Databricks @('workspace-bindings', 'update-bindings', 'storage_credential', $StorageCredentialName, '--json', $bindingBody)
    Invoke-Databricks @('workspace-bindings', 'update-bindings', 'external_location', $ExternalLocationName, '--json', $bindingBody)
    Invoke-Databricks @('workspace-bindings', 'update-bindings', 'catalog', $CatalogName, '--json', $bindingBody)
}

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

if ($PSCmdlet.ShouldProcess("principal $JobRunPrincipal", 'grant POC Unity Catalog privileges')) {
    Invoke-Databricks @('grants', 'update', 'credential', $ServiceCredentialName, '--json', $credentialGrant)
    Invoke-Databricks @('grants', 'update', 'catalog', $CatalogName, '--json', $catalogGrant)
    Invoke-Databricks @('grants', 'update', 'schema', "$CatalogName.$SchemaName", '--json', $schemaGrant)
}

if (-not $WhatIfPreference) {
    Invoke-CapabilityRetry -Description 'Unity Catalog storage credential validation' -Operation {
        Invoke-Databricks @('credentials', 'validate-credential', '--credential-name', $StorageCredentialName, '--purpose', 'STORAGE', '--url', $managedRoot)
    }

    Invoke-CapabilityRetry -Description 'Unity Catalog service credential validation' -Operation {
        Invoke-Databricks @('credentials', 'validate-credential', '--credential-name', $ServiceCredentialName, '--purpose', 'SERVICE')
    }
}

Write-Host 'Databricks workspace-plane bootstrap completed.'