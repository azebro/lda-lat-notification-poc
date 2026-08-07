[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentName,
    [string]$BundleTarget = 'dev',
    [string]$DatabricksWorkspaceProfile = $env:DATABRICKS_CONFIG_PROFILE,
    [switch]$DryRun,
    [switch]$ConfirmUnityCatalogDelete,
    [switch]$SkipPublisherDrain,
    [switch]$SkipBundleDestroy,
    [switch]$SkipUnityCatalogCleanup,
    [switch]$SkipAzureDown,
    [ValidateRange(1, 120)]
    [int]$DrainTimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/phase5-common.ps1"

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$bundlePath = Join-Path $repositoryRoot 'databricks'
$azd = Assert-PocTool -Name 'azd'
$needsDatabricks = -not $SkipPublisherDrain -or -not $SkipBundleDestroy -or -not $SkipUnityCatalogCleanup
$databricks = if ($needsDatabricks) { Assert-PocTool -Name 'databricks' } else { $null }

if (-not $DryRun -and -not $SkipUnityCatalogCleanup -and -not $ConfirmUnityCatalogDelete) {
    throw 'Pass -ConfirmUnityCatalogDelete to authorize deletion of POC-owned Unity Catalog objects, or use -DryRun.'
}
if ($DatabricksWorkspaceProfile) {
    [Environment]::SetEnvironmentVariable('DATABRICKS_CONFIG_PROFILE', $DatabricksWorkspaceProfile, 'Process')
}

$values = Import-PocAzdEnvironment -EnvironmentName $EnvironmentName
if ($needsDatabricks) {
    Assert-PocEnvironmentValues -Values $values -RequiredKeys @(
        'AZURE_DATABRICKS_NODE_TYPE',
        'AZURE_DATABRICKS_WORKSPACE_URL',
        'AZURE_EVENT_HUB_NAME',
        'AZURE_EVENT_HUB_NAMESPACE_FQDN',
        'AZURE_NAME_TOKEN'
    )
    Set-PocBundleEnvironment -Values $values
    Assert-PocDatabricksWorkspace -DatabricksPath $databricks -ExpectedHost $env:DATABRICKS_HOST -Profile $DatabricksWorkspaceProfile
}
$names = if (-not $SkipUnityCatalogCleanup) { Get-PocDatabricksNames -NameToken $values.AZURE_NAME_TOKEN } else { $null }
$profileArgs = if ($DatabricksWorkspaceProfile) { @('--profile', $DatabricksWorkspaceProfile) } else { @() }

function Invoke-TeardownAction {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Preview,
        [Parameter(Mandatory)][scriptblock]$Operation
    )

    if ($DryRun) {
        Write-Host "[DRY RUN] $Preview"
        return
    }
    if ($PSCmdlet.ShouldProcess($Target, $Action)) {
        & $Operation
    }
}

function Get-ActiveRuns {
    param([Parameter(Mandatory)][long]$JobId)

    $text = Invoke-PocNative -FilePath $databricks -Arguments (@(
        'jobs', 'list-runs', '--job-id', [string]$JobId, '--active-only', '--expand-tasks', '--limit', '25', '--output', 'json'
    ) + $profileArgs) -CaptureOutput
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    $response = $text | ConvertFrom-Json
    if ($null -eq $response) {
        return @()
    }
    if ($response.PSObject.Properties.Name -contains 'runs') {
        return @($response.runs)
    }
    return @($response)
}

function Wait-PublisherDrain {
    param(
        [Parameter(Mandatory)][long]$JobId,
        [Parameter(Mandatory)][string[]]$ClusterIds
    )

    $deadline = [DateTimeOffset]::UtcNow.AddMinutes($DrainTimeoutMinutes)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $activeRuns = @(Get-ActiveRuns -JobId $JobId)
        $runningClusters = @()
        foreach ($clusterId in $ClusterIds) {
            $cluster = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@(
                'clusters', 'get', $clusterId
            ) + $profileArgs)
            $stateProperty = if ($cluster) { $cluster.PSObject.Properties['state'] } else { $null }
            $state = if ($stateProperty) { [string]$stateProperty.Value } else { 'UNKNOWN' }
            if ($cluster -and $state -notin @('TERMINATED', 'ERROR', 'UNKNOWN')) {
                $runningClusters += "$clusterId ($state)"
            }
        }

        if ($activeRuns.Count -eq 0 -and $runningClusters.Count -eq 0) {
            Write-Host 'Publisher runs are stopped and job compute is terminated.'
            return
        }

        Write-Host "Waiting for publisher drain: $($activeRuns.Count) active run(s), $($runningClusters.Count) running cluster(s)."
        Start-Sleep -Seconds 10
    }

    throw "Timed out after $DrainTimeoutMinutes minute(s) waiting for publisher compute shutdown. Rerun teardown after checking the Databricks Jobs UI."
}

Write-Host 'Teardown phase 1/5: stop continuous publisher and drain compute.'
$summary = if (-not $SkipPublisherDrain -or -not $SkipBundleDestroy) {
    Get-PocBundleSummary -DatabricksPath $databricks -BundlePath $bundlePath -Target $BundleTarget -AllowMissing
}
else {
    $null
}
$publisherJobId = if ($summary) { Get-PocBundleJobId -Summary $summary -JobKey 'cdf_publisher' } else { $null }
if (-not $SkipPublisherDrain -and $publisherJobId) {
    $activeRuns = @(Get-ActiveRuns -JobId $publisherJobId)
    $clusterIds = @($activeRuns | ForEach-Object {
        $ids = @()
        $clusterInstance = $_.PSObject.Properties['cluster_instance']
        if ($clusterInstance) {
            $clusterId = $clusterInstance.Value.PSObject.Properties['cluster_id']
            if ($clusterId) { $ids += $clusterId.Value }
        }
        $tasks = $_.PSObject.Properties['tasks']
        if ($tasks) {
            foreach ($task in @($tasks.Value)) {
                $taskClusterInstance = $task.PSObject.Properties['cluster_instance']
                if ($taskClusterInstance) {
                    $taskClusterId = $taskClusterInstance.Value.PSObject.Properties['cluster_id']
                    if ($taskClusterId) { $ids += $taskClusterId.Value }
                }
            }
        }
        $ids
    } | Where-Object { $_ } | Select-Object -Unique)
    $pauseBody = @{
        job_id = $publisherJobId
        new_settings = @{ continuous = @{ pause_status = 'PAUSED'; task_retry_mode = 'ON_FAILURE' } }
    } | ConvertTo-Json -Depth 5 -Compress

    Invoke-TeardownAction -Target "Databricks job $publisherJobId" -Action 'pause continuous schedule' -Preview 'databricks jobs update --json <pause JSON>' -Operation {
        Invoke-PocNative -FilePath $databricks -Arguments (@(
            'jobs', 'update', '--json', $pauseBody
        ) + $profileArgs)
    }
    Invoke-TeardownAction -Target "Databricks job $publisherJobId" -Action 'cancel all active and queued runs' -Preview "databricks jobs cancel-all-runs --job-id $publisherJobId --all-queued-runs" -Operation {
        Invoke-PocNative -FilePath $databricks -Arguments (@(
            'jobs', 'cancel-all-runs', '--job-id', [string]$publisherJobId, '--all-queued-runs'
        ) + $profileArgs)
    }
    if (-not $DryRun) {
        Wait-PublisherDrain -JobId $publisherJobId -ClusterIds $clusterIds
    }
}
elseif (-not $SkipPublisherDrain) {
    Write-Host 'No deployed cdf_publisher bundle job was found; continuing partial teardown.'
}

Write-Host 'Teardown phase 2/5: destroy bundle jobs and synchronized files.'
if (-not $SkipBundleDestroy -and $summary) {
    Invoke-TeardownAction -Target "Databricks bundle target $BundleTarget" -Action 'destroy bundle resources' -Preview "databricks bundle destroy --target $BundleTarget --auto-approve" -Operation {
        Invoke-PocInDirectory -Path $bundlePath -Operation {
            Invoke-PocNative -FilePath $databricks -Arguments @(
                'bundle', 'destroy', '--target', $BundleTarget, '--auto-approve'
            )
        }
    }
}

if (-not $SkipUnityCatalogCleanup) {
    Write-Host 'Teardown phase 3/5: verify ownership of every Unity Catalog object.'
    $catalog = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('catalogs', 'get', $names.Catalog) + $profileArgs)
    $schema = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('schemas', 'get', "$($names.Catalog).$($names.Schema)") + $profileArgs)
    $table = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('tables', 'get', "$($names.Catalog).$($names.Schema).$($names.Table)") + $profileArgs)
    $volume = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('volumes', 'read', "$($names.Catalog).$($names.Schema).$($names.Volume)") + $profileArgs)
    $externalLocation = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('external-locations', 'get', $names.ExternalLocation) + $profileArgs)
    $serviceCredential = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('credentials', 'get-credential', $names.ServiceCredential) + $profileArgs)
    $storageCredential = Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('credentials', 'get-credential', $names.StorageCredential) + $profileArgs)

    if ($catalog) { Assert-PocOwnedObject -Description "Catalog $($names.Catalog)" -Object $catalog -OwnershipMarker $names.OwnershipMarker }
    if ($schema) { Assert-PocOwnedObject -Description "Schema $($names.Catalog).$($names.Schema)" -Object $schema -OwnershipMarker $names.OwnershipMarker }
    if ($table) {
        $tableMarker = $null
        $propertiesProperty = $table.PSObject.Properties['properties']
        if ($propertiesProperty) {
            $ownerProperty = $propertiesProperty.Value.PSObject.Properties['poc.owner']
            if ($ownerProperty) { $tableMarker = [string]$ownerProperty.Value }
        }
        Assert-PocOwnedObject -Description "Table $($names.Table)" -Object $table -OwnershipMarker $names.OwnershipMarker -ActualMarker $tableMarker
    }
    if ($volume) { Assert-PocOwnedObject -Description "Volume $($names.Volume)" -Object $volume -OwnershipMarker $names.OwnershipMarker }
    if ($externalLocation) { Assert-PocOwnedObject -Description "External location $($names.ExternalLocation)" -Object $externalLocation -OwnershipMarker $names.OwnershipMarker }
    if ($serviceCredential) { Assert-PocOwnedObject -Description "Service credential $($names.ServiceCredential)" -Object $serviceCredential -OwnershipMarker $names.OwnershipMarker }
    if ($storageCredential) { Assert-PocOwnedObject -Description "Storage credential $($names.StorageCredential)" -Object $storageCredential -OwnershipMarker $names.OwnershipMarker }

    Write-Host 'Teardown phase 4/5: delete verified POC-owned Unity Catalog objects.'
    $deletions = @(
        @{ Object = $table; Target = "table $($names.Catalog).$($names.Schema).$($names.Table)"; Arguments = @('tables', 'delete', "$($names.Catalog).$($names.Schema).$($names.Table)") },
        @{ Object = $volume; Target = "volume $($names.Catalog).$($names.Schema).$($names.Volume)"; Arguments = @('volumes', 'delete', "$($names.Catalog).$($names.Schema).$($names.Volume)") },
        @{ Object = $schema; Target = "schema $($names.Catalog).$($names.Schema)"; Arguments = @('schemas', 'delete', "$($names.Catalog).$($names.Schema)") },
        @{ Object = $catalog; Target = "catalog $($names.Catalog)"; Arguments = @('catalogs', 'delete', $names.Catalog) },
        @{ Object = $externalLocation; Target = "external location $($names.ExternalLocation)"; Arguments = @('external-locations', 'delete', $names.ExternalLocation) },
        @{ Object = $serviceCredential; Target = "service credential $($names.ServiceCredential)"; Arguments = @('credentials', 'delete-credential', $names.ServiceCredential) },
        @{ Object = $storageCredential; Target = "storage credential $($names.StorageCredential)"; Arguments = @('credentials', 'delete-credential', $names.StorageCredential) }
    )
    foreach ($deletion in $deletions) {
        if (-not $deletion.Object) {
            Write-Host "Skipping absent $($deletion.Target)."
            continue
        }
        Invoke-TeardownAction -Target $deletion.Target -Action 'delete POC-owned object' -Preview "databricks $($deletion.Arguments -join ' ')" -Operation {
            Invoke-PocNative -FilePath $databricks -Arguments ($deletion.Arguments + $profileArgs)
        }
    }

    if (-not $DryRun) {
        $remaining = @()
        $remaining += Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('catalogs', 'get', $names.Catalog) + $profileArgs)
        $remaining += Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('external-locations', 'get', $names.ExternalLocation) + $profileArgs)
        $remaining += Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('credentials', 'get-credential', $names.ServiceCredential) + $profileArgs)
        $remaining += Get-PocDatabricksObject -DatabricksPath $databricks -Arguments (@('credentials', 'get-credential', $names.StorageCredential) + $profileArgs)
        $remaining = @($remaining | Where-Object { $_ })
        if ($remaining.Count -gt 0) {
            throw 'Unity Catalog reference verification failed; one or more POC objects still exist. Rerun teardown before Azure deletion.'
        }
        Write-Host 'Unity Catalog cleanup verified. The shared metastore assignment was not changed.'
    }
}

Write-Host 'Teardown phase 5/5: delete POC-owned Azure resources.'
if (-not $SkipAzureDown) {
    Invoke-TeardownAction -Target "azd environment $EnvironmentName" -Action 'delete and purge Azure resources' -Preview "azd down --environment $EnvironmentName --purge --force --no-prompt" -Operation {
        Invoke-PocNative -FilePath $azd -Arguments @(
            'down', '--environment', $EnvironmentName, '--purge', '--force', '--no-prompt'
        )
    }
}

Write-Host $(if ($DryRun) { 'Teardown dry run completed.' } else { 'Phase 5 teardown completed.' })