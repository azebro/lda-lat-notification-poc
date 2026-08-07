[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentName,
    [string]$BundleTarget = 'dev',
    [string]$DatabricksWorkspaceProfile = $env:DATABRICKS_CONFIG_PROFILE,
    [ValidateRange(1, 3600)]
    [int]$BlobTimeoutSeconds = 300,
    [ValidateRange(1, 7200)]
    [int]$TelemetryTimeoutSeconds = 600,
    [ValidateRange(1, 7200)]
    [int]$JobTimeoutSeconds = 1200,
    [ValidateRange(1, 300)]
    [int]$PollIntervalSeconds = 10,
    [ValidateRange(1, 1800)]
    [int]$RestartObservationSeconds = 60,
    [switch]$SkipLocalValidation,
    [switch]$SkipAzdPreview,
    [switch]$Resume,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/phase5-common.ps1"

$script:AzPath = $null
$script:DatabricksPath = $null
$script:DatabricksProfileArgs = @()
$script:State = $null
$script:StatePath = $null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-PocMapValue {
    param(
        [AllowNull()][object]$Map,
        [Parameter(Mandatory)][string]$Key
    )

    if ($null -eq $Map) {
        return $null
    }
    if ($Map -is [System.Collections.IDictionary]) {
        if ($Map.Contains($Key)) {
            return $Map[$Key]
        }
        return $null
    }

    $property = $Map.PSObject.Properties[$Key]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Get-PocRequiredMapValue {
    param(
        [Parameter(Mandatory)][object]$Map,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Description
    )

    $value = Get-PocMapValue -Map $Map -Key $Key
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "$Description did not expose required value '$Key'."
    }
    return $value
}

function ConvertFrom-PocJson {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Description
    )

    try {
        return $Text | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "$Description returned invalid JSON: $($_.Exception.Message)"
    }
}

function Write-PocJsonFile {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $temporaryPath = "$Path.tmp"
    $json = $Value | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($temporaryPath, "$json`n", $utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Save-PocState {
    Write-PocJsonFile -Value $script:State -Path $script:StatePath
}

function Test-PocStageComplete {
    param([Parameter(Mandatory)][string]$Stage)

    return @($script:State['completed_stages']) -contains $Stage
}

function Complete-PocStage {
    param([Parameter(Mandatory)][string]$Stage)

    if (-not (Test-PocStageComplete -Stage $Stage)) {
        $script:State['completed_stages'] = @($script:State['completed_stages']) + $Stage
    }
    $script:State['last_completed_stage'] = $Stage
    Save-PocState
}

function Invoke-PocAzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $text = Invoke-PocNative -FilePath $script:AzPath -Arguments (
        $Arguments + @('--only-show-errors', '--output', 'json')
    ) -CaptureOutput
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return ConvertFrom-PocJson -Text $text -Description "az $($Arguments -join ' ')"
}

function Invoke-PocDatabricksJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $text = Invoke-PocNative -FilePath $script:DatabricksPath -Arguments (
        $Arguments + $script:DatabricksProfileArgs + @('--output', 'json')
    ) -CaptureOutput
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return ConvertFrom-PocJson -Text $text -Description "databricks $($Arguments -join ' ')"
}

function Invoke-PocDatabricks {
    param([Parameter(Mandatory)][string[]]$Arguments)

    Invoke-PocNative -FilePath $script:DatabricksPath -Arguments (
        $Arguments + $script:DatabricksProfileArgs
    )
}

function Start-PocJobRun {
    param(
        [Parameter(Mandatory)][long]$JobId,
        [Parameter(Mandatory)][string]$RunKey,
        [System.Collections.IDictionary]$JobParameters = @{}
    )

    $request = [ordered]@{
        job_id = $JobId
        idempotency_token = "$($script:State['evidence_run_id'])-$RunKey"
    }
    if ($JobParameters.Count -gt 0) {
        $request['job_parameters'] = $JobParameters
    }
    $body = $request | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-PocDatabricksJson -Arguments @(
        'jobs', 'run-now', '--json', $body, '--no-wait'
    )
    return [long](Get-PocRequiredMapValue -Map $response -Key 'run_id' -Description "Databricks $RunKey run")
}

function Get-PocJobRun {
    param([Parameter(Mandatory)][long]$RunId)

    return Invoke-PocDatabricksJson -Arguments @('jobs', 'get-run', [string]$RunId)
}

function Wait-PocJobRun {
    param(
        [Parameter(Mandatory)][long]$RunId,
        [Parameter(Mandatory)][string]$RunKey
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($JobTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $run = Get-PocJobRun -RunId $RunId
        $runState = Get-PocRequiredMapValue -Map $run -Key 'state' -Description "Databricks $RunKey run $RunId"
        $lifeCycleState = [string](Get-PocRequiredMapValue -Map $runState -Key 'life_cycle_state' -Description "Databricks $RunKey state")
        if ($lifeCycleState -in @('TERMINATED', 'SKIPPED', 'INTERNAL_ERROR')) {
            $resultState = [string](Get-PocMapValue -Map $runState -Key 'result_state')
            if ($lifeCycleState -ne 'TERMINATED' -or $resultState -ne 'SUCCESS') {
                $stateMessage = [string](Get-PocMapValue -Map $runState -Key 'state_message')
                throw "Databricks $RunKey run $RunId ended as $lifeCycleState/$resultState. $stateMessage"
            }

            $taskValues = Get-PocMapValue -Map $run -Key 'tasks'
            $tasks = if ($null -eq $taskValues) { @() } else { @($taskValues) }
            if ($tasks.Count -ne 1) {
                throw "Databricks $RunKey run $RunId must expose exactly one task; found $($tasks.Count)."
            }
            $taskRunId = [long](Get-PocRequiredMapValue -Map $tasks[0] -Key 'run_id' -Description "Databricks $RunKey task")
            $output = Invoke-PocDatabricksJson -Arguments @('jobs', 'get-run-output', [string]$taskRunId)
            $notebookOutput = Get-PocRequiredMapValue -Map $output -Key 'notebook_output' -Description "Databricks $RunKey output"
            $resultJson = [string](Get-PocRequiredMapValue -Map $notebookOutput -Key 'result' -Description "Databricks $RunKey notebook output")
            return [ordered]@{
                run_id = $RunId
                task_run_id = $taskRunId
                result = ConvertFrom-PocJson -Text $resultJson -Description "Databricks $RunKey notebook result"
            }
        }

        Write-Host "Waiting for Databricks $RunKey run $RunId ($lifeCycleState)."
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out after $JobTimeoutSeconds seconds waiting for Databricks $RunKey run $RunId."
}

function Get-PocJobNotebookParameters {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Job,
        [Parameter(Mandatory)][string]$TaskKey
    )

    $settings = Get-PocRequiredMapValue -Map $Job -Key 'settings' -Description 'Databricks job'
    $taskValues = Get-PocRequiredMapValue -Map $settings -Key 'tasks' -Description 'Databricks job settings'
    $tasks = @($taskValues | Where-Object {
        [string](Get-PocMapValue -Map $_ -Key 'task_key') -eq $TaskKey
    })
    if ($tasks.Count -ne 1) {
        throw "Databricks job must expose exactly one '$TaskKey' task; found $($tasks.Count)."
    }
    $notebookTask = Get-PocRequiredMapValue -Map $tasks[0] -Key 'notebook_task' -Description "Databricks task $TaskKey"
    $baseParameters = Get-PocRequiredMapValue -Map $notebookTask -Key 'base_parameters' -Description "Databricks task $TaskKey"
    if ($baseParameters -isnot [System.Collections.IDictionary]) {
        throw "Databricks task $TaskKey base_parameters must be an object."
    }
    return $baseParameters
}

function Invoke-PocProofJob {
    param(
        [Parameter(Mandatory)][long]$JobId,
        [Parameter(Mandatory)][string]$RunKey,
        [System.Collections.IDictionary]$JobParameters = @{}
    )

    $jobRuns = $script:State['job_runs']
    if ($jobRuns.Contains($RunKey)) {
        $runId = [long](Get-PocRequiredMapValue -Map $jobRuns[$RunKey] -Key 'run_id' -Description "saved $RunKey run")
    }
    else {
        $runId = Start-PocJobRun -JobId $JobId -RunKey $RunKey -JobParameters $JobParameters
        $jobRuns[$RunKey] = [ordered]@{
            run_id = $runId
            started_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Save-PocState
    }

    $completed = Wait-PocJobRun -RunId $runId -RunKey $RunKey
    $jobRuns[$RunKey]['task_run_id'] = $completed['task_run_id']
    $jobRuns[$RunKey]['status'] = 'SUCCESS'
    Save-PocState
    return $completed
}

function Get-PocBlobMatches {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$ExactPath
    )

    $eventFileName = [System.IO.Path]::GetFileName($ExactPath)
    $response = Invoke-PocAzJson -Arguments @(
        'storage', 'blob', 'list',
        '--account-name', [string]$Values['AZURE_AUDIT_STORAGE_ACCOUNT_NAME'],
        '--container-name', [string]$Values['AZURE_AUDIT_CONTAINER_NAME'],
        '--prefix', 'events/poc_notifications/main/vehicle_signals/',
        '--auth-mode', 'login',
        '--num-results', '*'
    )
    return @($response | Where-Object {
        ([string](Get-PocMapValue -Map $_ -Key 'name')).EndsWith("/$eventFileName", [StringComparison]::Ordinal)
    })
}

function Get-PocAuditBlobNames {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)

    $response = Invoke-PocAzJson -Arguments @(
        'storage', 'blob', 'list',
        '--account-name', [string]$Values['AZURE_AUDIT_STORAGE_ACCOUNT_NAME'],
        '--container-name', [string]$Values['AZURE_AUDIT_CONTAINER_NAME'],
        '--prefix', 'events/poc_notifications/main/vehicle_signals/',
        '--auth-mode', 'login',
        '--num-results', '*'
    )
    return @($response | ForEach-Object { [string](Get-PocRequiredMapValue -Map $_ -Key 'name' -Description 'audit Blob') } | Sort-Object -Unique)
}

function Get-PocAuditPath {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Commit)

    $commitTimestamp = [DateTimeOffset]::Parse(
        [string](Get-PocRequiredMapValue -Map $Commit -Key 'commit_timestamp' -Description 'source commit'),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    $datePath = $commitTimestamp.UtcDateTime.ToString('yyyy/MM/dd')
    $eventId = [string](Get-PocRequiredMapValue -Map $Commit -Key 'expected_event_id' -Description 'source commit')
    return "events/poc_notifications/main/vehicle_signals/$datePath/$eventId.json"
}

function Wait-PocAuditBlob {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$Path
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($BlobTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $matches = @(Get-PocBlobMatches -Values $Values -ExactPath $Path)
        if ($matches.Count -gt 1) {
            throw "Expected one unique audit Blob at '$Path'; found $($matches.Count)."
        }
        if ($matches.Count -eq 1) {
            $actualPath = [string](Get-PocRequiredMapValue -Map $matches[0] -Key 'name' -Description 'audit Blob')
            if ($actualPath -ne $Path) {
                throw "Event ID exists at '$actualPath', not its commit-derived audit path '$Path'."
            }
            $temporaryFile = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
            try {
                Invoke-PocNative -FilePath $script:AzPath -Arguments @(
                    'storage', 'blob', 'download',
                    '--account-name', [string]$Values['AZURE_AUDIT_STORAGE_ACCOUNT_NAME'],
                    '--container-name', [string]$Values['AZURE_AUDIT_CONTAINER_NAME'],
                    '--name', $Path,
                    '--file', $temporaryFile,
                    '--auth-mode', 'login',
                    '--no-progress',
                    '--only-show-errors',
                    '--output', 'none'
                )
                $rawBody = [System.IO.File]::ReadAllText($temporaryFile)
            }
            finally {
                Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
            }

            return [ordered]@{
                path = $Path
                properties = $matches[0]
                raw_body = $rawBody
                envelope = ConvertFrom-PocJson -Text $rawBody -Description "audit Blob $Path"
            }
        }

        Write-Host "Waiting for audit Blob '$Path'."
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out after $BlobTimeoutSeconds seconds waiting for audit Blob '$Path'."
}

function Assert-PocExactFields {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Description
    )

    $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Value.Keys | Sort-Object))
    if ($difference.Count -gt 0) {
        throw "$Description fields do not match the v1 contract: $($difference | ConvertTo-Json -Compress)."
    }
}

function Assert-PocEnvelope {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Envelope,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Commit,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedInput,
        [Parameter(Mandatory)][string]$ExpectedChangeType
    )

    Assert-PocExactFields -Value $Envelope -Expected @(
        'event_id', 'source', 'catalog', 'schema', 'table', 'primary_key', 'change_type',
        'commit_version', 'commit_timestamp', 'payload'
    ) -Description 'audit envelope'
    $payload = Get-PocRequiredMapValue -Map $Envelope -Key 'payload' -Description 'audit envelope'
    if ($payload -isnot [System.Collections.IDictionary]) {
        throw 'audit envelope payload must be an object.'
    }
    Assert-PocExactFields -Value $payload -Expected @(
        'signal_id', 'vehicle_id', 'signal_type', 'signal_value', 'event_timestamp', 'updated_at'
    ) -Description 'audit payload'

    $assertions = [ordered]@{
        event_id = [string]$Envelope['event_id'] -eq [string]$Commit['expected_event_id']
        source = [string]$Envelope['source'] -eq 'azure-databricks'
        location = "$($Envelope['catalog']).$($Envelope['schema']).$($Envelope['table'])" -eq 'poc_notifications.main.vehicle_signals'
        primary_key = [string]$Envelope['primary_key'] -eq [string]$ExpectedInput['signal_id']
        change_type = [string]$Envelope['change_type'] -eq $ExpectedChangeType
        commit_version = [long]$Envelope['commit_version'] -eq [long]$Commit['commit_version']
        commit_timestamp = [string]$Envelope['commit_timestamp'] -eq [string]$Commit['commit_timestamp']
        payload_signal_id = [string]$payload['signal_id'] -eq [string]$ExpectedInput['signal_id']
        payload_vehicle_id = [string]$payload['vehicle_id'] -eq [string]$ExpectedInput['vehicle_id']
        payload_signal_type = [string]$payload['signal_type'] -eq [string]$ExpectedInput['signal_type']
        payload_signal_value = [double]$payload['signal_value'] -eq [double]$ExpectedInput['signal_value']
    }
    $failed = @($assertions.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
    if ($failed.Count -gt 0) {
        throw "Audit envelope assertions failed: $($failed -join ', ')."
    }

    foreach ($timestampName in @('event_timestamp', 'updated_at')) {
        [void][DateTimeOffset]::Parse(
            [string]$payload[$timestampName],
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    }
}

function Convert-PocLogResponseToRows {
    param([AllowNull()][object]$Response)

    if ($null -eq $Response) {
        return @()
    }
    if ($Response -isnot [System.Collections.IDictionary]) {
        return @($Response)
    }

    $tablesValue = Get-PocMapValue -Map $Response -Key 'tables'
    if ($null -eq $tablesValue) {
        return @($Response)
    }

    $result = @()
    foreach ($table in @($tablesValue)) {
        if ($table -isnot [System.Collections.IDictionary] -or -not $table.Contains('columns') -or -not $table.Contains('rows')) {
            throw 'Log Analytics table did not expose columns and rows.'
        }
        $columns = @($table['columns'])
        foreach ($row in $table['rows']) {
            $mapped = [ordered]@{}
            for ($index = 0; $index -lt $columns.Count; $index++) {
                $columnName = [string](Get-PocRequiredMapValue -Map $columns[$index] -Key 'name' -Description 'Log Analytics column')
                $mapped[$columnName] = $row[$index]
            }
            $result += ,$mapped
        }
    }
    return $result
}

function New-PocTelemetryQuery {
    param(
        [Parameter(Mandatory)][string]$EventId,
        [Parameter(Mandatory)][DateTimeOffset]$NotBefore
    )

    $notBeforeText = $NotBefore.UtcDateTime.ToString('o')
    return @"
AppEvents
| where TimeGenerated >= datetime($notBeforeText)
| where Name == "DeltaChangeProcessed"
| extend event_id = tostring(Properties["event_id"])
| where event_id == "$EventId"
| project TimeGenerated, event_id,
    partition = tostring(Properties["partition"]),
    offset = tostring(Properties["offset"]),
    sequence_number = tolong(Properties["sequence_number"]),
    event_hubs_enqueued_time = todatetime(Properties["event_hubs_enqueued_time"]),
    receiver_latency_ms = todouble(Properties["receiver_latency_ms"]),
    duplicate = tobool(Properties["duplicate"]),
    change_type = tostring(Properties["change_type"]),
    commit_version = tolong(Properties["commit_version"])
| order by TimeGenerated asc
"@
}

function Invoke-PocTelemetryQuery {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$Query
    )

    $response = Invoke-PocAzJson -Arguments @(
        'monitor', 'log-analytics', 'query',
        '--workspace', [string]$Values['AZURE_LOG_ANALYTICS_WORKSPACE_ID'],
        '--analytics-query', $Query
    )
    return @(Convert-PocLogResponseToRows -Response $response)
}

function ConvertTo-PocBoolean {
    param([AllowNull()][object]$Value)

    if ($Value -is [bool]) {
        return $Value
    }
    if ([string]$Value -match '^(?i:true|false)$') {
        return [bool]::Parse([string]$Value)
    }
    throw "Value '$Value' is not a Boolean."
}

function Assert-PocTelemetryDimensions {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Row)

    foreach ($name in @('partition', 'offset', 'event_hubs_enqueued_time')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-PocMapValue -Map $Row -Key $name))) {
            throw "Processing telemetry is missing '$name'."
        }
    }
    foreach ($name in @('sequence_number', 'receiver_latency_ms', 'duplicate')) {
        if ($null -eq (Get-PocMapValue -Map $Row -Key $name)) {
            throw "Processing telemetry is missing '$name'."
        }
    }
    [void](ConvertTo-PocBoolean -Value $Row['duplicate'])
}

function Wait-PocTelemetry {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$EventId,
        [Parameter(Mandatory)][DateTimeOffset]$NotBefore,
        [switch]$RequireDuplicate
    )

    $query = New-PocTelemetryQuery -EventId $EventId -NotBefore $NotBefore
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TelemetryTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $rows = @(Invoke-PocTelemetryQuery -Values $Values -Query $query)
        foreach ($row in $rows) {
            Assert-PocTelemetryDimensions -Row $row
        }
        $matching = @(
            if ($RequireDuplicate) {
                $rows | Where-Object { ConvertTo-PocBoolean -Value (Get-PocMapValue -Map $_ -Key 'duplicate') }
            }
            else {
                $rows
            }
        )
        if ($matching.Count -gt 0) {
            return [ordered]@{
                query = $query
                rows = $rows
                selected = $matching[0]
            }
        }

        $kind = if ($RequireDuplicate) { 'duplicate telemetry' } else { 'processing telemetry' }
        Write-Host "Waiting for $kind for '$EventId'."
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out after $TelemetryTimeoutSeconds seconds waiting for telemetry for '$EventId'."
}

function Add-PocLatencyEvidence {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Telemetry,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Commit
    )

    $row = $Telemetry['selected']
    $telemetryTime = [DateTimeOffset]::Parse([string]$row['TimeGenerated'])
    $commitTime = [DateTimeOffset]::Parse([string]$Commit['commit_timestamp'])
    $endToEndLatency = ($telemetryTime - $commitTime).TotalMilliseconds
    if ($endToEndLatency -lt 0) {
        throw "Telemetry for '$($Commit['expected_event_id'])' predates its source commit."
    }
    $Telemetry['end_to_end_latency_ms'] = [math]::Round($endToEndLatency, 3)
    $Telemetry['receiver_latency_ms'] = [double]$row['receiver_latency_ms']
}

function Get-PocActiveJobRuns {
    param([Parameter(Mandatory)][long]$JobId)

    $response = Invoke-PocDatabricksJson -Arguments @(
        'jobs', 'list-runs', '--job-id', [string]$JobId, '--active-only', '--limit', '25'
    )
    $runs = Get-PocMapValue -Map $response -Key 'runs'
    if ($null -ne $runs) {
        return @($runs)
    }
    if ($null -eq $response) {
        return @()
    }
    return @($response)
}

function Wait-PocJobInactive {
    param([Parameter(Mandatory)][long]$JobId)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($JobTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $runs = @(Get-PocActiveJobRuns -JobId $JobId)
        if ($runs.Count -eq 0) {
            return
        }
        Write-Host "Waiting for publisher job $JobId to stop ($($runs.Count) active run(s))."
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timed out after $JobTimeoutSeconds seconds waiting for publisher job $JobId to stop."
}

function Wait-PocJobRunning {
    param([Parameter(Mandatory)][long]$RunId)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($JobTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $run = Get-PocJobRun -RunId $RunId
        $state = Get-PocRequiredMapValue -Map $run -Key 'state' -Description "publisher run $RunId"
        $lifeCycleState = [string](Get-PocRequiredMapValue -Map $state -Key 'life_cycle_state' -Description "publisher run $RunId state")
        if ($lifeCycleState -eq 'RUNNING') {
            return $run
        }
        if ($lifeCycleState -in @('TERMINATED', 'SKIPPED', 'INTERNAL_ERROR')) {
            $resultState = [string](Get-PocMapValue -Map $state -Key 'result_state')
            throw "Publisher restart run $RunId ended before reaching RUNNING ($lifeCycleState/$resultState)."
        }
        Write-Host "Waiting for publisher restart run $RunId ($lifeCycleState)."
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timed out after $JobTimeoutSeconds seconds waiting for publisher restart run $RunId."
}

function Get-PocNormalizedAssignments {
    param([Parameter(Mandatory)][string]$PrincipalId)

    $assignments = @(Invoke-PocAzJson -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', $PrincipalId,
        '--all',
        '--fill-principal-name', 'false',
        '--fill-role-definition-name', 'false'
    ))
    return @($assignments | ForEach-Object {
        $roleDefinitionId = [string](Get-PocRequiredMapValue -Map $_ -Key 'roleDefinitionId' -Description 'role assignment')
        $roleId = ($roleDefinitionId -split '/')[-1].ToLowerInvariant()
        $scope = ([string](Get-PocRequiredMapValue -Map $_ -Key 'scope' -Description 'role assignment')).TrimEnd('/').ToLowerInvariant()
        "$roleId|$scope"
    } | Sort-Object -Unique)
}

function Assert-PocExactAssignmentSet {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Description
    )

    $actual = @(Get-PocNormalizedAssignments -PrincipalId $PrincipalId)
    $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object -Unique) -DifferenceObject $actual)
    if ($difference.Count -gt 0) {
        throw "$Description RBAC assignments differ from the exact expected role/scope set: $($difference | ConvertTo-Json -Compress)."
    }
    return $actual
}

function Assert-PocRequiredAssignments {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string[]]$Required,
        [Parameter(Mandatory)][string]$Description
    )

    $actual = @(Get-PocNormalizedAssignments -PrincipalId $PrincipalId)
    $missing = @($Required | Where-Object { $_ -notin $actual })
    if ($missing.Count -gt 0) {
        throw "$Description is missing required RBAC assignments: $($missing -join ', ')."
    }
    return @($actual | Where-Object { $_ -in $Required })
}

function Assert-PocNoSecretMaterial {
    param(
        [Parameter(Mandatory)][string]$SerializedConfiguration,
        [Parameter(Mandatory)][string]$Description
    )

    $patterns = @(
        '(?i)SharedAccessKey\s*=',
        '(?i)SharedAccessSignature',
        '(?i)Endpoint=sb://',
        '(?i)AccountKey\s*=',
        '(?i)sasl\.jaas\.config',
        '(?i)kafka\.sasl',
        '(?i)client[_-]?secret',
        '(?i)sas[_-]?token'
    )
    $matches = @($patterns | Where-Object { $SerializedConfiguration -match $_ })
    if ($matches.Count -gt 0) {
        throw "$Description contains forbidden secret-bearing configuration patterns: $($matches -join ', ')."
    }
}

function New-PocEvidenceRecord {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)

    return [ordered]@{
        schema_version = 1
        status = 'passed'
        environment_name = $script:State['environment_name']
        evidence_run_id = $script:State['evidence_run_id']
        started_utc = $script:State['started_utc']
        completed_utc = $script:State['completed_utc']
        deployment = [ordered]@{
            subscription_id = $Values['AZURE_SUBSCRIPTION_ID']
            resource_group = $Values['AZURE_RESOURCE_GROUP_NAME']
            location = $Values['AZURE_LOCATION']
            databricks_workspace = $Values['AZURE_DATABRICKS_WORKSPACE_NAME']
            event_hub_namespace = $Values['AZURE_EVENT_HUB_NAMESPACE_NAME']
            event_hub = $Values['AZURE_EVENT_HUB_NAME']
            function_app = $Values['AZURE_FUNCTION_APP_NAME']
            audit_storage_account = $Values['AZURE_AUDIT_STORAGE_ACCOUNT_NAME']
            audit_container = $Values['AZURE_AUDIT_CONTAINER_NAME']
            application_insights = $Values['AZURE_APPLICATION_INSIGHTS_NAME']
            log_analytics_workspace = $Values['AZURE_LOG_ANALYTICS_WORKSPACE_NAME']
            publisher_checkpoint = $script:State['proofs']['restart']['checkpoint_path']
        }
        inputs = $script:State['inputs']
        jobs = $script:State['job_runs']
        insert = $script:State['proofs']['insert']
        update = $script:State['proofs']['update']
        checkpoint_idempotency = $script:State['proofs']['restart']
        independent_replay = $script:State['proofs']['replay']
        security = $script:State['proofs']['security']
        local_validation = $script:State['proofs']['local_validation']
    }
}

function New-PocEvidenceMarkdown {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Evidence)

    $insert = $Evidence['insert']
    $update = $Evidence['update']
    $restart = $Evidence['checkpoint_idempotency']
    $replay = $Evidence['independent_replay']
    $security = $Evidence['security']
    return @"
# Phase 6 POC Evidence

- Status: **passed**
- Environment: ``$($Evidence['environment_name'])``
- Evidence run: ``$($Evidence['evidence_run_id'])``
- Started: ``$($Evidence['started_utc'])``
- Completed: ``$($Evidence['completed_utc'])``

## Source Changes

| Mode | Commit | Change type | Event ID | Audit Blob | End-to-end latency (ms) |
|---|---:|---|---|---|---:|
| Insert | $($insert['commit']['commit_version']) | $($insert['commit']['change_type']) | ``$($insert['commit']['expected_event_id'])`` | ``$($insert['blob']['path'])`` | $($insert['telemetry']['end_to_end_latency_ms']) |
| Update | $($update['commit']['commit_version']) | $($update['commit']['change_type']) | ``$($update['commit']['expected_event_id'])`` | ``$($update['blob']['path'])`` | $($update['telemetry']['end_to_end_latency_ms']) |

## Idempotency

- Publisher checkpoint: ``$($Evidence['deployment']['publisher_checkpoint'])``
- Restart baseline Blob count: $($restart['baseline_blob_count'])
- Restart final Blob count: $($restart['final_blob_count'])
- Restart duplicate telemetry observations: $(@($restart['duplicate_telemetry']).Count)
- Replayed event: ``$($replay['event_id'])``
- Blob count after replay: $($replay['blob_count'])
- Duplicate telemetry recorded: ``true``

## Security

- Function Event Hubs authentication: managed identity
- Databricks Event Hubs authentication: Unity Catalog service credential
- Access Connector assignments: $(@($security['rbac']['access_connector']).Count)
- Function identity assignments: $(@($security['rbac']['function_identity']).Count)
- Verifier scoped reader assignments: $(@($security['rbac']['verifier_required']).Count)
- Secret-bearing Function or Databricks settings found: none

Full envelopes, Databricks run IDs, KQL queries/results, Event Hubs positions, resource names, and normalized RBAC role/scope sets are retained in the companion JSON evidence file.
"@
}

function Invoke-PocVerifierSelfTest {
    $commit = [ordered]@{
        commit_version = 42
        commit_timestamp = '2026-08-05T12:34:56.000Z'
        change_type = 'insert'
        expected_event_id = 'vehicle_signals-signal-001-v42-insert'
    }
    $expectedInput = [ordered]@{
        signal_id = 'signal-001'
        vehicle_id = 'vehicle-001'
        signal_type = 'temperature'
        signal_value = 20.0
    }
    $envelope = [ordered]@{
        event_id = $commit['expected_event_id']
        source = 'azure-databricks'
        catalog = 'poc_notifications'
        schema = 'main'
        table = 'vehicle_signals'
        primary_key = 'signal-001'
        change_type = 'insert'
        commit_version = 42
        commit_timestamp = $commit['commit_timestamp']
        payload = [ordered]@{
            signal_id = 'signal-001'
            vehicle_id = 'vehicle-001'
            signal_type = 'temperature'
            signal_value = 20.0
            event_timestamp = '2026-08-05T12:30:00.000Z'
            updated_at = '2026-08-05T12:34:55.000Z'
        }
    }
    Assert-PocEnvelope -Envelope $envelope -Commit $commit -ExpectedInput $expectedInput -ExpectedChangeType 'insert'

        $tableResponse = ConvertFrom-PocJson -Text @'
{
    "tables": [
        {
            "columns": [
                { "name": "event_id" },
                { "name": "sequence_number" },
                { "name": "duplicate" }
            ],
            "rows": [
                ["vehicle_signals-signal-001-v42-insert", 7, false]
            ]
        }
    ]
}
'@ -Description 'self-test Log Analytics response'
    $rows = @(Convert-PocLogResponseToRows -Response $tableResponse)
    if ($rows.Count -ne 1 -or [long]$rows[0]['sequence_number'] -ne 7 -or (ConvertTo-PocBoolean -Value $rows[0]['duplicate'])) {
        throw 'Verifier self-test failed to convert the Log Analytics table response.'
    }

    $query = New-PocTelemetryQuery -EventId ([string]$commit['expected_event_id']) -NotBefore ([DateTimeOffset]'2026-08-05T12:00:00Z')
    if ($query -notmatch [regex]::Escape([string]$commit['expected_event_id']) -or $query -notmatch 'AppEvents') {
        throw 'Verifier self-test failed to build the processing telemetry query.'
    }
        $jobResponse = ConvertFrom-PocJson -Text @'
{
    "settings": {
        "tasks": [
            {
                "task_key": "publish_cdf",
                "notebook_task": {
                    "base_parameters": {
                        "checkpoint_path": "/Volumes/poc_notifications/main/streaming_state/cdf_publisher"
                    }
                }
            }
        ]
    }
}
'@ -Description 'self-test Databricks job'
        $jobParameters = Get-PocJobNotebookParameters -Job $jobResponse -TaskKey 'publish_cdf'
        if ([string]$jobParameters['checkpoint_path'] -ne '/Volumes/poc_notifications/main/streaming_state/cdf_publisher') {
                throw 'Verifier self-test failed to read the deployed publisher checkpoint.'
        }
    Assert-PocNoSecretMaterial -SerializedConfiguration '{"credential":"managedidentity"}' -Description 'self-test configuration'
    $secretRejected = $false
    try {
        Assert-PocNoSecretMaterial -SerializedConfiguration 'SharedAccessKey=forbidden' -Description 'self-test configuration'
    }
    catch {
        $secretRejected = $true
    }
    if (-not $secretRejected) {
        throw 'Verifier self-test failed to reject secret-bearing configuration.'
    }

    Write-Host 'verify-poc.ps1 self-test passed.'
}

if ($SelfTest) {
    Invoke-PocVerifierSelfTest
    return
}

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$bundlePath = Join-Path $repositoryRoot 'databricks'
$evidenceDirectory = Join-Path $repositoryRoot 'evidence'
$safeEnvironmentName = $EnvironmentName -replace '[^A-Za-z0-9._-]', '_'
$script:StatePath = Join-Path $evidenceDirectory "phase6-$safeEnvironmentName.state.json"
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

if ($Resume) {
    if (-not (Test-Path $script:StatePath)) {
        throw "No Phase 6 state exists at '$script:StatePath'. Run without -Resume to start a proof."
    }
    $stateText = [System.IO.File]::ReadAllText($script:StatePath)
    $script:State = ConvertFrom-PocJson -Text $stateText -Description 'Phase 6 state'
    if ([string]$script:State['environment_name'] -ne $EnvironmentName -or [string]$script:State['bundle_target'] -ne $BundleTarget) {
        throw 'Saved Phase 6 state targets a different environment or bundle target.'
    }
}
else {
    if (Test-Path $script:StatePath) {
        $previous = ConvertFrom-PocJson -Text ([System.IO.File]::ReadAllText($script:StatePath)) -Description 'existing Phase 6 state'
        if ([string]$previous['status'] -ne 'passed') {
            throw "An incomplete Phase 6 proof exists at '$script:StatePath'. Rerun with -Resume."
        }
    }

    $runId = "{0}-{1}" -f [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $signalSuffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $script:State = [ordered]@{
        schema_version = 1
        environment_name = $EnvironmentName
        bundle_target = $BundleTarget
        evidence_run_id = $runId
        status = 'in_progress'
        started_utc = [DateTimeOffset]::UtcNow.ToString('o')
        completed_stages = @()
        last_completed_stage = $null
        inputs = [ordered]@{
            signal_id = "phase6-$signalSuffix"
            vehicle_id = "vehicle-$signalSuffix"
            signal_type = 'temperature'
            insert_signal_value = 20.0
            update_signal_value = 21.5
        }
        job_runs = [ordered]@{}
        proofs = [ordered]@{}
    }
    Save-PocState
}

try {
    $script:AzPath = Assert-PocTool -Name 'az'
    $azd = Assert-PocTool -Name 'azd'
    $script:DatabricksPath = Assert-PocTool -Name 'databricks'
    if (-not [string]::IsNullOrWhiteSpace($DatabricksWorkspaceProfile)) {
        $script:DatabricksProfileArgs = @('--profile', $DatabricksWorkspaceProfile)
        [Environment]::SetEnvironmentVariable('DATABRICKS_CONFIG_PROFILE', $DatabricksWorkspaceProfile, 'Process')
    }

    $values = Import-PocAzdEnvironment -EnvironmentName $EnvironmentName
    Assert-PocEnvironmentValues -Values $values -RequiredKeys @(
        'AZURE_APPLICATION_INSIGHTS_NAME',
        'AZURE_AUDIT_CONTAINER_NAME',
        'AZURE_AUDIT_STORAGE_ACCOUNT_NAME',
        'AZURE_DATABRICKS_ACCESS_CONNECTOR_PRINCIPAL_ID',
        'AZURE_DATABRICKS_NODE_TYPE',
        'AZURE_DATABRICKS_WORKSPACE_NAME',
        'AZURE_DATABRICKS_WORKSPACE_URL',
        'AZURE_DATA_LAKE_ACCOUNT_NAME',
        'AZURE_EVENT_HUB_NAME',
        'AZURE_EVENT_HUB_CONSUMER_GROUP',
        'AZURE_EVENT_HUB_NAMESPACE_FQDN',
        'AZURE_EVENT_HUB_NAMESPACE_NAME',
        'AZURE_FUNCTION_APP_NAME',
        'AZURE_FUNCTION_HOST_STORAGE_ACCOUNT_NAME',
        'AZURE_FUNCTION_IDENTITY_CLIENT_ID',
        'AZURE_FUNCTION_IDENTITY_PRINCIPAL_ID',
        'AZURE_LOCATION',
        'AZURE_LOG_ANALYTICS_WORKSPACE_ID',
        'AZURE_LOG_ANALYTICS_WORKSPACE_NAME',
        'AZURE_NAME_TOKEN',
        'AZURE_RESOURCE_GROUP_NAME',
        'AZURE_SUBSCRIPTION_ID',
        'AZURE_VERIFIER_PRINCIPAL_ID'
    )
    Set-PocBundleEnvironment -Values $values
    Assert-PocDatabricksWorkspace -DatabricksPath $script:DatabricksPath -ExpectedHost $env:DATABRICKS_HOST -Profile $DatabricksWorkspaceProfile
    Invoke-PocNative -FilePath $script:AzPath -Arguments @('account', 'set', '--subscription', [string]$values['AZURE_SUBSCRIPTION_ID'])

    if (-not (Test-PocStageComplete -Stage 'local_validation')) {
        if (-not $SkipLocalValidation) {
            & "$PSScriptRoot/test-local.ps1"
        }
        $previewStatus = 'skipped by parameter'
        if (-not $SkipAzdPreview) {
            $provisionHelp = Invoke-PocNative -FilePath $azd -Arguments @('provision', '--help') -CaptureOutput
            if ($provisionHelp -match '(?m)--preview\b') {
                Invoke-PocNative -FilePath $azd -Arguments @(
                    'provision', '--preview', '--environment', $EnvironmentName, '--no-prompt'
                )
                $previewStatus = 'passed'
            }
            else {
                $previewStatus = 'unsupported by installed azd'
            }
        }
        Invoke-PocInDirectory -Path $bundlePath -Operation {
            Invoke-PocDatabricks -Arguments @('bundle', 'validate', '--target', $BundleTarget)
        }
        $script:State['proofs']['local_validation'] = [ordered]@{
            local_checks = if ($SkipLocalValidation) { 'skipped by parameter' } else { 'passed' }
            azd_preview = $previewStatus
            deployed_bundle_validation = 'passed'
        }
        Complete-PocStage -Stage 'local_validation'
    }

    $summary = Get-PocBundleSummary -DatabricksPath $script:DatabricksPath -BundlePath $bundlePath -Target $BundleTarget
    $jobIds = [ordered]@{}
    foreach ($jobKey in @('kafka_smoke', 'cdf_publisher', 'drive_change', 'replay_event')) {
        $jobId = Get-PocBundleJobId -Summary $summary -JobKey $jobKey
        if (-not $jobId) {
            throw "The deployed bundle does not expose '$jobKey'. Deploy the current bundle before Phase 6 verification."
        }
        $jobIds[$jobKey] = [long]$jobId
    }
    $publisherJob = Invoke-PocDatabricksJson -Arguments @('jobs', 'get', [string]$jobIds['cdf_publisher'])
    $publisherParameters = Get-PocJobNotebookParameters -Job $publisherJob -TaskKey 'publish_cdf'
    $publisherCheckpointPath = [string](Get-PocRequiredMapValue -Map $publisherParameters -Key 'checkpoint_path' -Description 'deployed CDF publisher')
    if (-not $publisherCheckpointPath.StartsWith('/Volumes/poc_notifications/main/streaming_state/', [StringComparison]::Ordinal)) {
        throw "Deployed publisher checkpoint '$publisherCheckpointPath' is outside the POC streaming_state volume."
    }

    $inputs = $script:State['inputs']
    $proofStart = [DateTimeOffset]::Parse([string]$script:State['started_utc'])
    if (-not (Test-PocStageComplete -Stage 'insert')) {
        $insertRun = Invoke-PocProofJob -JobId $jobIds['drive_change'] -RunKey 'insert' -JobParameters ([ordered]@{
            mode = 'insert'
            signal_id = [string]$inputs['signal_id']
            vehicle_id = [string]$inputs['vehicle_id']
            signal_type = [string]$inputs['signal_type']
            signal_value = [string]$inputs['insert_signal_value']
        })
        $commit = $insertRun['result']
        if ([string]$commit['change_type'] -ne 'insert') {
            throw 'Insert driver did not return change_type=insert.'
        }
        $blob = Wait-PocAuditBlob -Values $values -Path (Get-PocAuditPath -Commit $commit)
        Assert-PocEnvelope -Envelope $blob['envelope'] -Commit $commit -ExpectedInput ([ordered]@{
            signal_id = $inputs['signal_id']
            vehicle_id = $inputs['vehicle_id']
            signal_type = $inputs['signal_type']
            signal_value = $inputs['insert_signal_value']
        }) -ExpectedChangeType 'insert'
        $telemetry = Wait-PocTelemetry -Values $values -EventId ([string]$commit['expected_event_id']) -NotBefore $proofStart
        Add-PocLatencyEvidence -Telemetry $telemetry -Commit $commit
        $script:State['proofs']['insert'] = [ordered]@{
            run_id = $insertRun['run_id']
            commit = $commit
            blob = $blob
            telemetry = $telemetry
        }
        Complete-PocStage -Stage 'insert'
    }

    if (-not (Test-PocStageComplete -Stage 'update')) {
        $updateRun = Invoke-PocProofJob -JobId $jobIds['drive_change'] -RunKey 'update' -JobParameters ([ordered]@{
            mode = 'update'
            signal_id = [string]$inputs['signal_id']
            vehicle_id = [string]$inputs['vehicle_id']
            signal_type = [string]$inputs['signal_type']
            signal_value = [string]$inputs['update_signal_value']
        })
        $commit = $updateRun['result']
        $insertCommit = $script:State['proofs']['insert']['commit']
        if ([string]$commit['change_type'] -ne 'update_postimage') {
            throw 'Update driver did not return change_type=update_postimage.'
        }
        if ([long]$commit['commit_version'] -le [long]$insertCommit['commit_version']) {
            throw 'Update commit_version must be strictly greater than the insert commit_version.'
        }
        $blob = Wait-PocAuditBlob -Values $values -Path (Get-PocAuditPath -Commit $commit)
        Assert-PocEnvelope -Envelope $blob['envelope'] -Commit $commit -ExpectedInput ([ordered]@{
            signal_id = $inputs['signal_id']
            vehicle_id = $inputs['vehicle_id']
            signal_type = $inputs['signal_type']
            signal_value = $inputs['update_signal_value']
        }) -ExpectedChangeType 'update_postimage'
        $preimageCommit = [ordered]@{
            commit_timestamp = $commit['commit_timestamp']
            expected_event_id = "vehicle_signals-$($inputs['signal_id'])-v$($commit['commit_version'])-update_preimage"
        }
        $preimagePath = Get-PocAuditPath -Commit $preimageCommit
        if (@(Get-PocBlobMatches -Values $values -ExactPath $preimagePath).Count -ne 0) {
            throw "Unexpected update_preimage audit Blob exists at '$preimagePath'."
        }
        $telemetry = Wait-PocTelemetry -Values $values -EventId ([string]$commit['expected_event_id']) -NotBefore $proofStart
        Add-PocLatencyEvidence -Telemetry $telemetry -Commit $commit
        $script:State['proofs']['update'] = [ordered]@{
            run_id = $updateRun['run_id']
            commit = $commit
            blob = $blob
            preimage_path = $preimagePath
            preimage_blob_count = 0
            telemetry = $telemetry
        }
        Complete-PocStage -Stage 'update'
    }

    if (-not (Test-PocStageComplete -Stage 'restart')) {
        if (-not $script:State['proofs'].Contains('restart')) {
            $pauseBody = [ordered]@{
                job_id = $jobIds['cdf_publisher']
                new_settings = [ordered]@{
                    continuous = [ordered]@{
                        pause_status = 'PAUSED'
                        task_retry_mode = 'ON_FAILURE'
                    }
                }
            } | ConvertTo-Json -Depth 10 -Compress
            Invoke-PocDatabricks -Arguments @('jobs', 'update', '--json', $pauseBody)
            Invoke-PocDatabricks -Arguments @(
                'jobs', 'cancel-all-runs', '--job-id', [string]$jobIds['cdf_publisher'], '--all-queued-runs'
            )
            Wait-PocJobInactive -JobId $jobIds['cdf_publisher']
            $baselineNames = @(Get-PocAuditBlobNames -Values $values)
            $script:State['proofs']['restart'] = [ordered]@{
                baseline_blob_names = $baselineNames
                baseline_blob_count = $baselineNames.Count
                checkpoint_path = $publisherCheckpointPath
            }
            Save-PocState
        }
        $restartProof = $script:State['proofs']['restart']
        if (-not $script:State['job_runs'].Contains('publisher_restart')) {
            $restartRunId = Start-PocJobRun -JobId $jobIds['cdf_publisher'] -RunKey 'publisher_restart'
            $restartStarted = [DateTimeOffset]::UtcNow
            $script:State['job_runs']['publisher_restart'] = [ordered]@{
                run_id = $restartRunId
                started_utc = $restartStarted.ToString('o')
            }
            $restartProof['restart_started_utc'] = $restartStarted.ToString('o')
            Save-PocState
        }
        $restartRunId = [long]$script:State['job_runs']['publisher_restart']['run_id']
        [void](Wait-PocJobRunning -RunId $restartRunId)
        $observationEnds = [DateTimeOffset]::Parse([string]$restartProof['restart_started_utc']).AddSeconds($RestartObservationSeconds)
        $remainingSeconds = [math]::Ceiling(($observationEnds - [DateTimeOffset]::UtcNow).TotalSeconds)
        if ($remainingSeconds -gt 0) {
            Write-Host "Observing restarted publisher for $remainingSeconds seconds with no source change."
            Start-Sleep -Seconds $remainingSeconds
        }
        $finalNames = @(Get-PocAuditBlobNames -Values $values)
        $blobDifference = @(Compare-Object -ReferenceObject @($restartProof['baseline_blob_names']) -DifferenceObject $finalNames)
        if ($blobDifference.Count -gt 0) {
            throw "Publisher restart changed the unique audit Blob set: $($blobDifference | ConvertTo-Json -Compress)."
        }
        $restartProof['final_blob_count'] = $finalNames.Count
        $restartProof['publisher_run_id'] = $restartRunId
        $restartProof['duplicate_telemetry'] = @()
        foreach ($eventProofName in @('insert', 'update')) {
            $eventId = [string]$script:State['proofs'][$eventProofName]['commit']['expected_event_id']
            $query = New-PocTelemetryQuery -EventId $eventId -NotBefore ([DateTimeOffset]::Parse([string]$restartProof['restart_started_utc']))
            $rows = @(Invoke-PocTelemetryQuery -Values $values -Query $query)
            foreach ($row in $rows) {
                Assert-PocTelemetryDimensions -Row $row
                if (-not (ConvertTo-PocBoolean -Value $row['duplicate'])) {
                    throw "Publisher restart reprocessed '$eventId' without duplicate=true."
                }
                $restartProof['duplicate_telemetry'] += ,$row
            }
        }
        Complete-PocStage -Stage 'restart'
    }

    if (-not (Test-PocStageComplete -Stage 'replay')) {
        $capturedBlob = $script:State['proofs']['update']['blob']
        $capturedEnvelope = $capturedBlob['envelope']
        $capturedEnvelopeJson = [string](Get-PocRequiredMapValue -Map $capturedBlob -Key 'raw_body' -Description 'captured update audit Blob')
        $eventId = [string]$capturedEnvelope['event_id']
        if (-not $script:State['proofs'].Contains('replay')) {
            $script:State['proofs']['replay'] = [ordered]@{
                event_id = $eventId
                started_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            Save-PocState
        }
        $replayProof = $script:State['proofs']['replay']
        $replayRun = Invoke-PocProofJob -JobId $jobIds['replay_event'] -RunKey 'replay' -JobParameters ([ordered]@{
            envelope_json = $capturedEnvelopeJson
        })
        if ([string]$replayRun['result']['event_id'] -ne $eventId -or [string]$replayRun['result']['status'] -ne 'replayed') {
            throw 'Replay job did not confirm the expected event ID and replay status.'
        }
        $duplicateTelemetry = Wait-PocTelemetry -Values $values -EventId $eventId -NotBefore ([DateTimeOffset]::Parse([string]$replayProof['started_utc'])) -RequireDuplicate
        $blobPath = [string]$script:State['proofs']['update']['blob']['path']
        $blobCount = @(Get-PocBlobMatches -Values $values -ExactPath $blobPath).Count
        if ($blobCount -ne 1) {
            throw "Replay changed the unique audit Blob count for '$eventId' to $blobCount."
        }
        $replayProof['run_id'] = $replayRun['run_id']
        $replayProof['blob_path'] = $blobPath
        $replayProof['blob_count'] = $blobCount
        $replayProof['telemetry'] = $duplicateTelemetry
        Complete-PocStage -Stage 'replay'
    }

    if (-not (Test-PocStageComplete -Stage 'security')) {
        $functionSettings = @(Invoke-PocAzJson -Arguments @(
            'functionapp', 'config', 'appsettings', 'list',
            '--name', [string]$values['AZURE_FUNCTION_APP_NAME'],
            '--resource-group', [string]$values['AZURE_RESOURCE_GROUP_NAME']
        ))
        $settingsMap = [ordered]@{}
        foreach ($setting in $functionSettings) {
            $settingsMap[[string](Get-PocRequiredMapValue -Map $setting -Key 'name' -Description 'Function app setting')] = [string](Get-PocMapValue -Map $setting -Key 'value')
        }
        foreach ($requiredSetting in @(
            'APPLICATIONINSIGHTS_AUTHENTICATION_STRING',
            'APPLICATIONINSIGHTS_CONNECTION_STRING',
            'AUDIT_STORAGE_BLOB_SERVICE_URI',
            'AUDIT_STORAGE_CONTAINER_NAME',
            'AzureWebJobsStorage__blobServiceUri',
            'AzureWebJobsStorage__clientId',
            'AzureWebJobsStorage__credential',
            'AzureWebJobsStorage__queueServiceUri',
            'AzureWebJobsStorage__tableServiceUri',
            'EventHubConnection__clientId',
            'EventHubConnection__credential',
            'EventHubConnection__fullyQualifiedNamespace',
            'EVENT_HUB_CONSUMER_GROUP',
            'EVENT_HUB_NAME'
        )) {
            if (-not $settingsMap.Contains($requiredSetting)) {
                throw "Function app is missing identity setting '$requiredSetting'."
            }
        }
        foreach ($forbiddenSetting in @(
            'AzureWebJobsStorage',
            'EventHubConnection',
            'AUDIT_STORAGE_CONNECTION_STRING',
            'EVENT_HUB_CONNECTION_STRING'
        )) {
            if ($settingsMap.Contains($forbiddenSetting)) {
                throw "Function app contains forbidden secret-bearing setting '$forbiddenSetting'."
            }
        }
        $expectedFunctionSettings = [ordered]@{
            APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "ClientId=$($values['AZURE_FUNCTION_IDENTITY_CLIENT_ID']);Authorization=AAD"
            AUDIT_STORAGE_BLOB_SERVICE_URI = "https://$($values['AZURE_AUDIT_STORAGE_ACCOUNT_NAME']).blob.core.windows.net/"
            AUDIT_STORAGE_CONTAINER_NAME = [string]$values['AZURE_AUDIT_CONTAINER_NAME']
            AzureWebJobsStorage__blobServiceUri = "https://$($values['AZURE_FUNCTION_HOST_STORAGE_ACCOUNT_NAME']).blob.core.windows.net/"
            AzureWebJobsStorage__clientId = [string]$values['AZURE_FUNCTION_IDENTITY_CLIENT_ID']
            AzureWebJobsStorage__credential = 'managedidentity'
            AzureWebJobsStorage__queueServiceUri = "https://$($values['AZURE_FUNCTION_HOST_STORAGE_ACCOUNT_NAME']).queue.core.windows.net/"
            AzureWebJobsStorage__tableServiceUri = "https://$($values['AZURE_FUNCTION_HOST_STORAGE_ACCOUNT_NAME']).table.core.windows.net/"
            EventHubConnection__clientId = [string]$values['AZURE_FUNCTION_IDENTITY_CLIENT_ID']
            EventHubConnection__credential = 'managedidentity'
            EventHubConnection__fullyQualifiedNamespace = [string]$values['AZURE_EVENT_HUB_NAMESPACE_FQDN']
            EVENT_HUB_CONSUMER_GROUP = [string]$values['AZURE_EVENT_HUB_CONSUMER_GROUP']
            EVENT_HUB_NAME = [string]$values['AZURE_EVENT_HUB_NAME']
        }
        $mismatchedSettings = @($expectedFunctionSettings.GetEnumerator() | Where-Object {
            [string]$settingsMap[$_.Key] -ne [string]$_.Value
        } | ForEach-Object Key)
        if ($mismatchedSettings.Count -gt 0) {
            throw "Function identity settings do not match deployed resources: $($mismatchedSettings -join ', ')."
        }
        Assert-PocNoSecretMaterial -SerializedConfiguration ($functionSettings | ConvertTo-Json -Depth 20 -Compress) -Description 'Function app settings'

        $functionIdentity = Invoke-PocAzJson -Arguments @(
            'functionapp', 'identity', 'show',
            '--name', [string]$values['AZURE_FUNCTION_APP_NAME'],
            '--resource-group', [string]$values['AZURE_RESOURCE_GROUP_NAME']
        )
        $userAssignedIdentities = Get-PocRequiredMapValue -Map $functionIdentity -Key 'userAssignedIdentities' -Description 'Function identity'
        $identityMatches = @($userAssignedIdentities.Values | Where-Object {
            [string](Get-PocMapValue -Map $_ -Key 'clientId') -eq [string]$values['AZURE_FUNCTION_IDENTITY_CLIENT_ID'] -and
            [string](Get-PocMapValue -Map $_ -Key 'principalId') -eq [string]$values['AZURE_FUNCTION_IDENTITY_PRINCIPAL_ID']
        })
        if ($userAssignedIdentities.Count -ne 1 -or $identityMatches.Count -ne 1) {
            throw 'Function app must have exactly the expected user-assigned managed identity.'
        }

        $databricksConfiguration = [ordered]@{}
        foreach ($jobKey in @('kafka_smoke', 'cdf_publisher', 'replay_event')) {
            $job = Invoke-PocDatabricksJson -Arguments @('jobs', 'get', [string]$jobIds[$jobKey])
            $serialized = $job | ConvertTo-Json -Depth 100 -Compress
            Assert-PocNoSecretMaterial -SerializedConfiguration $serialized -Description "Databricks $jobKey job"
            if ($serialized -notmatch [regex]::Escape([string]$values['AZURE_EVENT_HUB_NAMESPACE_FQDN']) -or
                $serialized -notmatch [regex]::Escape([string]$env:BUNDLE_VAR_service_credential_name)) {
                throw "Databricks $jobKey job does not reference the expected Event Hubs namespace and service credential."
            }
            $databricksConfiguration[$jobKey] = [ordered]@{
                job_id = $jobIds[$jobKey]
                identity_only = $true
            }
        }

        $subscriptionScope = "/subscriptions/$($values['AZURE_SUBSCRIPTION_ID'])"
        $resourceGroupScope = "$subscriptionScope/resourceGroups/$($values['AZURE_RESOURCE_GROUP_NAME'])"
        $dataLakeScope = "$resourceGroupScope/providers/Microsoft.Storage/storageAccounts/$($values['AZURE_DATA_LAKE_ACCOUNT_NAME'])"
        $eventHubScope = "$resourceGroupScope/providers/Microsoft.EventHub/namespaces/$($values['AZURE_EVENT_HUB_NAMESPACE_NAME'])/eventhubs/$($values['AZURE_EVENT_HUB_NAME'])"
        $functionStorageScope = "$resourceGroupScope/providers/Microsoft.Storage/storageAccounts/$($values['AZURE_FUNCTION_HOST_STORAGE_ACCOUNT_NAME'])"
        $auditContainerScope = "$resourceGroupScope/providers/Microsoft.Storage/storageAccounts/$($values['AZURE_AUDIT_STORAGE_ACCOUNT_NAME'])/blobServices/default/containers/$($values['AZURE_AUDIT_CONTAINER_NAME'])"
        $applicationInsightsScope = "$resourceGroupScope/providers/Microsoft.Insights/components/$($values['AZURE_APPLICATION_INSIGHTS_NAME'])"
        $logAnalyticsScope = "$resourceGroupScope/providers/Microsoft.OperationalInsights/workspaces/$($values['AZURE_LOG_ANALYTICS_WORKSPACE_NAME'])"
        $assignment = {
            param([string]$RoleId, [string]$Scope)
            return "$($RoleId.ToLowerInvariant())|$($Scope.TrimEnd('/').ToLowerInvariant())"
        }
        $connectorExpected = @(
            & $assignment 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' $dataLakeScope
            & $assignment '2b629674-e913-4c01-ae53-ef4638d8f975' $eventHubScope
        )
        $functionExpected = @(
            & $assignment 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde' $eventHubScope
            & $assignment 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' $functionStorageScope
            & $assignment '974c5e8b-45b9-4653-ba55-5f855dd0fb88' $functionStorageScope
            & $assignment '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' $functionStorageScope
            & $assignment 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' $auditContainerScope
            & $assignment '3913510d-42f4-4e42-8a64-420c390055eb' $applicationInsightsScope
        )
        $verifierExpected = @(
            & $assignment '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' $auditContainerScope
            & $assignment '73c42c96-874c-492b-b04d-ab87d138a893' $logAnalyticsScope
        )
        $rbacEvidence = [ordered]@{
            access_connector = @(Assert-PocExactAssignmentSet -PrincipalId ([string]$values['AZURE_DATABRICKS_ACCESS_CONNECTOR_PRINCIPAL_ID']) -Expected $connectorExpected -Description 'Access Connector')
            function_identity = @(Assert-PocExactAssignmentSet -PrincipalId ([string]$values['AZURE_FUNCTION_IDENTITY_PRINCIPAL_ID']) -Expected $functionExpected -Description 'Function identity')
            verifier_required = @(Assert-PocRequiredAssignments -PrincipalId ([string]$values['AZURE_VERIFIER_PRINCIPAL_ID']) -Required $verifierExpected -Description 'Verifier principal')
        }
        $script:State['proofs']['security'] = [ordered]@{
            function = [ordered]@{
                app_setting_names = @($settingsMap.Keys | Sort-Object)
                identity_backed_settings_verified = @($expectedFunctionSettings.Keys)
                event_hubs_authentication = 'managed identity'
                expected_user_assigned_identity = $true
                forbidden_secret_patterns_found = 0
            }
            databricks = $databricksConfiguration
            rbac = $rbacEvidence
        }
        Complete-PocStage -Stage 'security'
    }

    $script:State['status'] = 'passed'
    $script:State['completed_utc'] = [DateTimeOffset]::UtcNow.ToString('o')
    $evidenceBaseName = "phase6-$safeEnvironmentName-$($script:State['evidence_run_id'])"
    $jsonEvidencePath = Join-Path $evidenceDirectory "$evidenceBaseName.json"
    $markdownEvidencePath = Join-Path $evidenceDirectory "$evidenceBaseName.md"
    $script:State['evidence_files'] = [ordered]@{
        json = $jsonEvidencePath
        markdown = $markdownEvidencePath
    }
    Save-PocState
    $evidence = New-PocEvidenceRecord -Values $values
    Write-PocJsonFile -Value $evidence -Path $jsonEvidencePath
    [System.IO.File]::WriteAllText($markdownEvidencePath, (New-PocEvidenceMarkdown -Evidence $evidence), $utf8NoBom)

    Write-Host "Phase 6 verification passed."
    Write-Host "JSON evidence: $jsonEvidencePath"
    Write-Host "Markdown evidence: $markdownEvidencePath"
}
catch {
    if ($script:State) {
        $script:State['status'] = 'failed'
        $script:State['last_error'] = [ordered]@{
            time_utc = [DateTimeOffset]::UtcNow.ToString('o')
            message = $_.Exception.Message
        }
        Save-PocState
    }
    throw
}