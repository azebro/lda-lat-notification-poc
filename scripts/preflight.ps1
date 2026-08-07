[CmdletBinding()]
param(
    [string]$Location = $env:AZURE_LOCATION,
    [string]$DatabricksNodeType = $(if ($env:AZURE_DATABRICKS_NODE_TYPE) { $env:AZURE_DATABRICKS_NODE_TYPE } else { 'Standard_D4ds_v6' }),
    [string]$DatabricksAccountProfile = $env:DATABRICKS_ACCOUNT_PROFILE,
    [switch]$SkipAzureChecks
)

$ErrorActionPreference = 'Stop'

if ($env:POC_PREFLIGHT_COMPLETE -eq 'true') {
    Write-Host 'Preflight already completed by Phase 5 orchestration.'
    return
}

$requiredTools = @('az', 'azd', 'databricks', 'dotnet', 'pwsh')
$missingTools = @($requiredTools | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })

if ($missingTools.Count -gt 0) {
    throw "Missing required tools: $($missingTools -join ', '). See README.md prerequisites."
}

$bicepVersion = az bicep version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI Bicep is not available. Run: az bicep install'
}

az functionapp list-flexconsumption-runtimes --help *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'This Azure CLI version does not support Flex Consumption runtime discovery. Upgrade Azure CLI before deployment.'
}

Write-Host "Bicep: $bicepVersion"
Write-Host "azd: $(azd version)"
$databricksVersionText = databricks version
$dotnetVersionText = dotnet --version
Write-Host "Databricks CLI: $databricksVersionText"
Write-Host ".NET SDK: $dotnetVersionText"

if ($dotnetVersionText -notmatch '^(?<version>\d+\.\d+\.\d+)') {
    throw "Unable to parse .NET SDK version: $dotnetVersionText"
}

if ([version]$Matches.version -lt [version]'10.0.100') {
    throw ".NET SDK 10.0.100 or later is required. Found $dotnetVersionText."
}

if ($databricksVersionText -notmatch '(?<version>\d+\.\d+\.\d+)') {
    throw "Unable to parse Databricks CLI version: $databricksVersionText"
}

if ([version]$Matches.version -lt [version]'0.278.0') {
    throw "Databricks CLI 0.278.0 or later is required. Found $databricksVersionText."
}

if ($SkipAzureChecks) {
    Write-Warning 'Azure account, provider, region, quota, and permission checks were skipped.'
    return
}

if ([string]::IsNullOrWhiteSpace($Location)) {
    throw 'Set AZURE_LOCATION or pass -Location.'
}

$account = az account show --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not authenticated. Run: az login'
}

Write-Host "Subscription: $($account.name) ($($account.id))"
Write-Host "Location: $Location"

$locationRecord = az account list-locations --query "[?name=='$Location'] | [0].{name:name,displayName:displayName}" --output json | ConvertFrom-Json
if (-not $locationRecord) {
    throw "Azure location '$Location' is not recognized. Use a location code such as eastus."
}

$providers = @(
    'Microsoft.Databricks',
    'Microsoft.ContainerInstance',
    'Microsoft.EventHub',
    'Microsoft.Insights',
    'Microsoft.ManagedIdentity',
    'Microsoft.OperationalInsights',
    'Microsoft.Resources',
    'Microsoft.Storage',
    'Microsoft.Web'
)

foreach ($provider in $providers) {
    $state = az provider show --namespace $provider --query registrationState --output tsv
    if ($state -ne 'Registered') {
        throw "Resource provider $provider is not registered. Run: az provider register --namespace $provider"
    }
}

$flexLocations = @(az functionapp list-flexconsumption-locations --query '[].name' --output tsv)
if ($flexLocations -notcontains $Location) {
    throw "Azure Functions Flex Consumption is not available in $Location."
}

$flexRuntimes = az functionapp list-flexconsumption-runtimes --location $Location --runtime dotnet-isolated --output json | ConvertFrom-Json
$dotnet10Runtime = @($flexRuntimes | Where-Object { $_.sku.functionAppConfigProperties.runtime.version -eq '10.0' })
if ($dotnet10Runtime.Count -eq 0) {
    throw ".NET 10 isolated is not available on Flex Consumption in $Location."
}

function Assert-ProviderLocation {
    param(
        [string]$Namespace,
        [string]$ResourceType,
        [string]$DisplayName
    )

    $locations = @(az provider show --namespace $Namespace --query "resourceTypes[?resourceType=='$ResourceType'].locations[]" --output tsv)
    if ($locations -notcontains $DisplayName) {
        throw "$Namespace/$ResourceType is not available in $Location ($DisplayName)."
    }
}

Assert-ProviderLocation -Namespace 'Microsoft.Databricks' -ResourceType 'workspaces' -DisplayName $locationRecord.displayName
Assert-ProviderLocation -Namespace 'Microsoft.EventHub' -ResourceType 'namespaces' -DisplayName $locationRecord.displayName

$nodeSku = @(az vm list-skus --location $Location --resource-type virtualMachines --all --output json | ConvertFrom-Json | Where-Object { $_.name -eq $DatabricksNodeType }) | Select-Object -First 1
if (-not $nodeSku) {
    throw "Databricks node type $DatabricksNodeType is not advertised by Azure Compute in $Location."
}

$blockingRestrictions = @($nodeSku.restrictions | Where-Object { $_.reasonCode -eq 'NotAvailableForSubscription' })
if ($blockingRestrictions.Count -gt 0) {
    throw "Databricks node type $DatabricksNodeType is restricted for this subscription in $Location."
}

$requiredCores = [int](($nodeSku.capabilities | Where-Object name -eq 'vCPUs' | Select-Object -First 1).value)
$vmUsage = az vm list-usage --location $Location --output json | ConvertFrom-Json
$familyUsage = $vmUsage | Where-Object { $_.name.value -eq $nodeSku.family } | Select-Object -First 1
if (-not $familyUsage) {
    throw "Unable to locate the $($nodeSku.family) core quota used by $DatabricksNodeType in $Location."
}

if (($familyUsage.limit - $familyUsage.currentValue) -lt $requiredCores) {
    throw "Insufficient $($nodeSku.family) quota in $Location. Required: $requiredCores cores; available: $($familyUsage.limit - $familyUsage.currentValue)."
}

function Test-ActionAllowed {
    param(
        [string]$RequiredAction,
        [object[]]$PermissionSets
    )

    foreach ($permission in $PermissionSets) {
        $allowed = @($permission.actions | Where-Object { $RequiredAction -like $_ }).Count -gt 0
        $denied = @($permission.notActions | Where-Object { $RequiredAction -like $_ }).Count -gt 0
        if ($allowed -and -not $denied) {
            return $true
        }
    }

    return $false
}

$subscriptionScope = "/subscriptions/$($account.id)"
$permissionResponse = az rest --method get --url "https://management.azure.com$subscriptionScope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $permissionResponse.value) {
    throw 'Unable to retrieve effective Azure Resource Manager permissions for the deployment principal.'
}
$permissionSets = @($permissionResponse.value)
$requiredActions = @(
    'Microsoft.Resources/subscriptions/resourceGroups/write',
    'Microsoft.Authorization/roleAssignments/write',
    'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action',
    'Microsoft.Resources/deploymentScripts/write',
    'Microsoft.ContainerInstance/containerGroups/write',
    'Microsoft.Storage/storageAccounts/write'
)

$missingActions = @($requiredActions | Where-Object { -not (Test-ActionAllowed -RequiredAction $_ -PermissionSets $permissionSets) })
if ($missingActions.Count -gt 0) {
    throw "The deployment principal lacks required actions at subscription scope: $($missingActions -join ', ')."
}

if ([string]::IsNullOrWhiteSpace($DatabricksAccountProfile)) {
    throw 'Set DATABRICKS_ACCOUNT_PROFILE to a Databricks CLI profile authenticated as an account admin.'
}

$metastores = databricks account metastores list --profile $DatabricksAccountProfile --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list Unity Catalog metastores with profile '$DatabricksAccountProfile'. Confirm account-admin access."
}

$regionalMetastore = @($metastores | Where-Object { $_.region -eq $Location })
if ($regionalMetastore.Count -eq 0) {
    throw "No Unity Catalog metastore exists in $Location. Create or select the regional metastore before deployment."
}

Write-Warning 'Azure does not expose Flex regional memory quota through this CLI surface; ARM validates that quota during provisioning.'
Write-Host 'Preflight passed: tooling, providers, regions, runtime, VM SKU/quota, deployment actions, and regional metastore are available.'