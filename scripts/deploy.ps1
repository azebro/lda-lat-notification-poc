[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentName,
    [string]$BundleTarget = 'dev',
    [string]$DatabricksAccountProfile = $env:DATABRICKS_ACCOUNT_PROFILE,
    [string]$DatabricksWorkspaceProfile = $env:DATABRICKS_CONFIG_PROFILE,
    [string]$JobRunPrincipal = $env:DATABRICKS_JOB_RUN_PRINCIPAL,
    [string]$MetastoreId = $env:DATABRICKS_METASTORE_ID,
    [switch]$SkipLocalValidation,
    [switch]$SkipProvision,
    [switch]$SkipSmokeTest,
    [switch]$SkipReceiverDeploy,
    [switch]$SkipBundleDeploy,
    [switch]$SkipSetup,
    [switch]$SkipPublisherStart
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/phase5-common.ps1"

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$bundlePath = Join-Path $repositoryRoot 'databricks'
$azd = Assert-PocTool -Name 'azd'
$databricks = Assert-PocTool -Name 'databricks'

if ([string]::IsNullOrWhiteSpace($DatabricksAccountProfile)) {
    throw 'Set DATABRICKS_ACCOUNT_PROFILE or pass -DatabricksAccountProfile.'
}
if ([string]::IsNullOrWhiteSpace($JobRunPrincipal)) {
    throw 'Set DATABRICKS_JOB_RUN_PRINCIPAL or pass -JobRunPrincipal.'
}
if ($DatabricksWorkspaceProfile) {
    [Environment]::SetEnvironmentVariable('DATABRICKS_CONFIG_PROFILE', $DatabricksWorkspaceProfile, 'Process')
}
[Environment]::SetEnvironmentVariable('DATABRICKS_ACCOUNT_PROFILE', $DatabricksAccountProfile, 'Process')
[Environment]::SetEnvironmentVariable('DATABRICKS_JOB_RUN_PRINCIPAL', $JobRunPrincipal, 'Process')
$initialValues = Import-PocAzdEnvironment -EnvironmentName $EnvironmentName

if (-not $SkipLocalValidation) {
    Write-Host 'Phase 1/8: local validation'
    & "$PSScriptRoot/test-local.ps1"
}

if (-not $SkipProvision) {
    Write-Host 'Phase 2/8: Azure and account preflight'
    & "$PSScriptRoot/preflight.ps1" -Location $initialValues.AZURE_LOCATION -DatabricksAccountProfile $DatabricksAccountProfile
    [Environment]::SetEnvironmentVariable('POC_PREFLIGHT_COMPLETE', 'true', 'Process')

    Write-Host 'Phase 3/8: Azure provisioning and RBAC capability gate'
    if ($PSCmdlet.ShouldProcess("azd environment $EnvironmentName", 'provision Azure resources')) {
        Invoke-PocNative -FilePath $azd -Arguments @(
            'provision', '--environment', $EnvironmentName, '--no-prompt'
        )
    }
}

$values = Import-PocAzdEnvironment -EnvironmentName $EnvironmentName
Assert-PocEnvironmentValues -Values $values -RequiredKeys @(
    'AZURE_DATABRICKS_ACCESS_CONNECTOR_ID',
    'AZURE_DATABRICKS_NODE_TYPE',
    'AZURE_DATABRICKS_WORKSPACE_ID',
    'AZURE_DATABRICKS_WORKSPACE_URL',
    'AZURE_DATA_LAKE_ACCOUNT_NAME',
    'AZURE_DATA_LAKE_CONTAINER_NAME',
    'AZURE_EVENT_HUB_NAME',
    'AZURE_EVENT_HUB_NAMESPACE_FQDN',
    'AZURE_LOCATION',
    'AZURE_NAME_TOKEN'
)
Set-PocBundleEnvironment -Values $values
Assert-PocDatabricksWorkspace -DatabricksPath $databricks -ExpectedHost $env:DATABRICKS_HOST -Profile $DatabricksWorkspaceProfile

if (-not $MetastoreId) {
    $metastoresJson = Invoke-PocNative -FilePath $databricks -Arguments @(
        'account', 'metastores', 'list', '--profile', $DatabricksAccountProfile, '--output', 'json'
    ) -CaptureOutput
    $regionalMetastores = @($metastoresJson | ConvertFrom-Json | Where-Object region -eq $values.AZURE_LOCATION)
    if ($regionalMetastores.Count -ne 1) {
        throw "Expected exactly one Unity Catalog metastore in $($values.AZURE_LOCATION); found $($regionalMetastores.Count). Set DATABRICKS_METASTORE_ID explicitly."
    }
    $metastore = $regionalMetastores[0]
    $idProperty = $metastore.PSObject.Properties['metastore_id']
    if (-not $idProperty) {
        $idProperty = $metastore.PSObject.Properties['metastoreId']
    }
    if (-not $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
        throw 'The regional metastore response did not expose a metastore ID.'
    }
    $MetastoreId = [string]$idProperty.Value
}
[Environment]::SetEnvironmentVariable('DATABRICKS_METASTORE_ID', $MetastoreId, 'Process')

Write-Host 'Phase 4/8: Databricks account-plane metastore assignment'
& "$PSScriptRoot/bootstrap-databricks.ps1" -Phase Account -WorkspaceProfile $DatabricksWorkspaceProfile -AccountProfile $DatabricksAccountProfile -MetastoreId $MetastoreId -WhatIf:$WhatIfPreference

Write-Host 'Phase 5/8: bundle validation and workspace-plane bootstrap'
Invoke-PocInDirectory -Path $bundlePath -Operation {
    Invoke-PocNative -FilePath $databricks -Arguments @('bundle', 'validate', '--target', $BundleTarget)
}
& "$PSScriptRoot/bootstrap-databricks.ps1" -Phase Workspace -WorkspaceProfile $DatabricksWorkspaceProfile -AccountProfile $DatabricksAccountProfile -MetastoreId $MetastoreId -WhatIf:$WhatIfPreference

if (-not $SkipSmokeTest) {
    Write-Host 'Phase 6/8: one-message Kafka credential smoke test'
    if ($PSCmdlet.ShouldProcess('Databricks kafka_smoke job', 'deploy and run')) {
        Invoke-PocInDirectory -Path $bundlePath -Operation {
            Invoke-PocNative -FilePath $databricks -Arguments @(
                'bundle', 'deploy', '--target', $BundleTarget, '--select', 'kafka_smoke', '--auto-approve'
            )
            Invoke-PocNative -FilePath $databricks -Arguments @(
                'bundle', 'run', '--target', $BundleTarget, 'kafka_smoke'
            )
        }
    }
}

if (-not $SkipReceiverDeploy) {
    Write-Host 'Phase 7/8: receiver deployment'
    if ($PSCmdlet.ShouldProcess('receiver Function', 'deploy application package')) {
        Invoke-PocNative -FilePath $azd -Arguments @(
            'deploy', 'receiver', '--environment', $EnvironmentName, '--no-prompt'
        )
    }
}

Write-Host 'Phase 8/8: bundle deployment, source setup, and publisher start'
if (-not $SkipBundleDeploy -and $PSCmdlet.ShouldProcess("Databricks bundle target $BundleTarget", 'deploy')) {
    Invoke-PocInDirectory -Path $bundlePath -Operation {
        Invoke-PocNative -FilePath $databricks -Arguments @(
            'bundle', 'deploy', '--target', $BundleTarget, '--auto-approve'
        )
    }
}
if (-not $SkipSetup -and $PSCmdlet.ShouldProcess('Databricks source table and checkpoint', 'run setup_source')) {
    Invoke-PocInDirectory -Path $bundlePath -Operation {
        Invoke-PocNative -FilePath $databricks -Arguments @(
            'bundle', 'run', '--target', $BundleTarget, 'setup_source'
        )
    }
}
if (-not $SkipPublisherStart -and $PSCmdlet.ShouldProcess('Databricks CDF publisher', 'start continuous run')) {
    Invoke-PocInDirectory -Path $bundlePath -Operation {
        Invoke-PocNative -FilePath $databricks -Arguments @(
            'bundle', 'run', '--target', $BundleTarget, '--no-wait', 'cdf_publisher'
        )
    }
}

Write-Host 'Phase 5 deployment orchestration completed.'