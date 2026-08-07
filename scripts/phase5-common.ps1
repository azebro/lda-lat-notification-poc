Set-StrictMode -Version Latest

function Assert-PocTool {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required tool '$Name' is not available on PATH."
    }

    return $command.Source
}

function Invoke-PocNative {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput,
        [switch]$AllowNotFound
    )

    if ($CaptureOutput -or $AllowNotFound) {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | Out-String).Trim()

        if ($exitCode -ne 0) {
            if ($AllowNotFound -and $text -match '(?i)\bRESOURCE_DOES_NOT_EXIST\b|\bNOT_FOUND\b|\bHTTP\s*404\b|\bstatus(?: code)?\s*404\b') {
                return $null
            }

            throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')`n$text"
        }

        if ($CaptureOutput) {
            return $text
        }

        return
    }

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-PocInDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Operation
    )

    Push-Location $Path
    try {
        & $Operation
    }
    finally {
        Pop-Location
    }
}

function Import-PocAzdEnvironment {
    param([Parameter(Mandatory)][string]$EnvironmentName)

    $azd = Assert-PocTool -Name 'azd'
    $dotenv = Invoke-PocNative -FilePath $azd -Arguments @(
        'env', 'get-values', '--environment', $EnvironmentName, '--no-prompt'
    ) -CaptureOutput
    $values = @{}
    foreach ($line in $dotenv -split "`r?`n") {
        if ($line -notmatch '^(?<key>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$') {
            continue
        }

        $value = $Matches.value.Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2).Replace('\\', '\').Replace('\"', '"')
        }
        $values[$Matches.key] = $value
    }
    if ($values.Count -eq 0) {
        throw "azd environment '$EnvironmentName' contains no values. Create and configure it before orchestration."
    }

    foreach ($entry in $values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
    }

    return $values
}

function Assert-PocEnvironmentValues {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string[]]$RequiredKeys
    )

    $missing = @($RequiredKeys | Where-Object {
        -not $Values.Contains($_) -or [string]::IsNullOrWhiteSpace([string]$Values[$_])
    })
    if ($missing.Count -gt 0) {
        throw "The azd environment is missing required outputs: $($missing -join ', '). Run azd provision successfully before resuming."
    }
}

function Set-PocBundleEnvironment {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)

    Assert-PocEnvironmentValues -Values $Values -RequiredKeys @(
        'AZURE_DATABRICKS_NODE_TYPE',
        'AZURE_DATABRICKS_WORKSPACE_URL',
        'AZURE_EVENT_HUB_NAME',
        'AZURE_EVENT_HUB_NAMESPACE_FQDN',
        'AZURE_NAME_TOKEN'
    )

    $workspaceUrl = [string]$Values.AZURE_DATABRICKS_WORKSPACE_URL
    if ($workspaceUrl -notmatch '^https://') {
        $workspaceUrl = "https://$workspaceUrl"
    }

    $sparkVersion = if ([string]::IsNullOrWhiteSpace($env:POC_DATABRICKS_SPARK_VERSION)) {
        '18.x-scala2.13'
    }
    else {
        $env:POC_DATABRICKS_SPARK_VERSION
    }

    [Environment]::SetEnvironmentVariable('DATABRICKS_HOST', $workspaceUrl, 'Process')
    [Environment]::SetEnvironmentVariable('BUNDLE_VAR_spark_version', $sparkVersion, 'Process')
    [Environment]::SetEnvironmentVariable('BUNDLE_VAR_node_type_id', [string]$Values.AZURE_DATABRICKS_NODE_TYPE, 'Process')
    [Environment]::SetEnvironmentVariable('BUNDLE_VAR_event_hub_namespace_fqdn', [string]$Values.AZURE_EVENT_HUB_NAMESPACE_FQDN, 'Process')
    [Environment]::SetEnvironmentVariable('BUNDLE_VAR_event_hub_name', [string]$Values.AZURE_EVENT_HUB_NAME, 'Process')
    [Environment]::SetEnvironmentVariable('BUNDLE_VAR_ownership_token', [string]$Values.AZURE_NAME_TOKEN, 'Process')
    [Environment]::SetEnvironmentVariable(
        'BUNDLE_VAR_service_credential_name',
        "delta_notification_event_hubs_$($Values.AZURE_NAME_TOKEN)",
        'Process'
    )
}

function Assert-PocDatabricksWorkspace {
    param(
        [Parameter(Mandatory)][string]$DatabricksPath,
        [Parameter(Mandatory)][string]$ExpectedHost,
        [string]$Profile
    )

    $arguments = @('auth', 'describe')
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $arguments += @('--profile', $Profile)
    }
    $description = Invoke-PocNative -FilePath $DatabricksPath -Arguments $arguments -CaptureOutput
    if ($description -notmatch '(?m)^Host:\s*(?<host>\S+)\s*$') {
        throw "Unable to determine the effective Databricks workspace host."
    }

    $actualHost = $Matches.host.Trim().TrimEnd('/').ToLowerInvariant()
    $expectedNormalized = $ExpectedHost.Trim().TrimEnd('/').ToLowerInvariant()
    if ($actualHost -ne $expectedNormalized) {
        $profileDescription = if ($Profile) { "profile '$Profile'" } else { 'effective authentication configuration' }
        throw "Databricks $profileDescription targets '$($Matches.host)', not the provisioned workspace '$ExpectedHost'. Refusing to mutate workspace objects."
    }
}

function Get-PocDatabricksNames {
    param([Parameter(Mandatory)][string]$NameToken)

    return @{
        Catalog = 'poc_notifications'
        ExternalLocation = "delta_notification_location_$NameToken"
        OwnershipMarker = "poc-owner:$NameToken"
        Schema = 'main'
        ServiceCredential = "delta_notification_event_hubs_$NameToken"
        StorageCredential = "delta_notification_storage_$NameToken"
        Table = 'vehicle_signals'
        Volume = 'streaming_state'
    }
}

function Get-PocBundleSummary {
    param(
        [Parameter(Mandatory)][string]$DatabricksPath,
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$Target,
        [switch]$AllowMissing
    )

    $operation = {
        $text = Invoke-PocNative -FilePath $DatabricksPath -Arguments @(
            'bundle', 'summary', '--target', $Target, '--output', 'json', '--force-pull'
        ) -CaptureOutput -AllowNotFound:$AllowMissing
        if ($text) {
            return $text | ConvertFrom-Json
        }
        return $null
    }

    return Invoke-PocInDirectory -Path $BundlePath -Operation $operation
}

function Get-PocBundleJobId {
    param(
        [Parameter(Mandatory)][object]$Summary,
        [Parameter(Mandatory)][string]$JobKey
    )

    $resourcesProperty = $Summary.PSObject.Properties['resources']
    if (-not $resourcesProperty) {
        return $null
    }
    $jobsProperty = $resourcesProperty.Value.PSObject.Properties['jobs']
    if (-not $jobsProperty) {
        return $null
    }
    $jobProperty = $jobsProperty.Value.PSObject.Properties[$JobKey]
    if (-not $jobProperty) {
        return $null
    }
    $job = $jobProperty.Value
    if (-not $job) {
        return $null
    }
    $idProperty = $job.PSObject.Properties['id']
    if ($idProperty -and $idProperty.Value) {
        return [long]$idProperty.Value
    }
    $urlProperty = $job.PSObject.Properties['url']
    if ($urlProperty -and $urlProperty.Value -match '/jobs/(?<id>\d+)') {
        return [long]$Matches.id
    }

    throw "Bundle summary did not expose an ID for job '$JobKey'."
}

function Get-PocDatabricksObject {
    param(
        [Parameter(Mandatory)][string]$DatabricksPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $text = Invoke-PocNative -FilePath $DatabricksPath -Arguments ($Arguments + @('--output', 'json')) -CaptureOutput -AllowNotFound
    if (-not $text) {
        return $null
    }
    return $text | ConvertFrom-Json
}

function Assert-PocOwnedObject {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$OwnershipMarker,
        [string]$ActualMarker
    )

    if (-not $PSBoundParameters.ContainsKey('ActualMarker')) {
        $commentProperty = $Object.PSObject.Properties['comment']
        $ActualMarker = if ($commentProperty) { [string]$commentProperty.Value } else { $null }
    }
    if ($ActualMarker -ne $OwnershipMarker) {
        throw "$Description is not owned by this POC environment ($OwnershipMarker). Refusing to delete it."
    }
}