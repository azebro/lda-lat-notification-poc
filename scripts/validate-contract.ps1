[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $repositoryRoot 'contracts/delta-change-envelope.v1.schema.json'
$examples = Get-ChildItem (Join-Path $repositoryRoot 'contracts/examples/*.json')

foreach ($example in $examples) {
    $content = Get-Content $example.FullName -Raw
    $isValid = $content | Test-Json -SchemaFile $schemaPath
    if (-not $isValid) {
        throw "Contract example failed schema validation: $($example.Name)"
    }

    $event = $content | ConvertFrom-Json
    if ($event.primary_key -ne $event.payload.signal_id) {
        throw "primary_key must equal payload.signal_id: $($example.Name)"
    }

    $expectedEventId = "vehicle_signals-$($event.payload.signal_id)-v$($event.commit_version)-$($event.change_type)"
    if ($event.event_id -ne $expectedEventId) {
        throw "event_id does not match deterministic identity: $($example.Name)"
    }
}

Write-Host "Validated $($examples.Count) contract examples."