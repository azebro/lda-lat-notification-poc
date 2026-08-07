[CmdletBinding()]
param(
    [switch]$SkipSparkTests
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/phase5-common.ps1"

$repositoryRoot = Split-Path $PSScriptRoot -Parent
Invoke-PocInDirectory -Path $repositoryRoot -Operation {
    $az = Assert-PocTool -Name 'az'
    $dotnet = Assert-PocTool -Name 'dotnet'
    $venvPython = if ($IsWindows) {
        Join-Path $repositoryRoot '.venv/Scripts/python.exe'
    }
    else {
        Join-Path $repositoryRoot '.venv/bin/python'
    }
    $lintPython = if (Test-Path $venvPython) { $venvPython } else { Assert-PocTool -Name 'python' }

Write-Host 'Validating Bicep and event contracts.'
Invoke-PocNative -FilePath $az -Arguments @('bicep', 'build', '--file', 'infra/main.bicep', '--outfile', "$env:TEMP/lda-lat-notification-poc-main.json")
& "$PSScriptRoot/validate-contract.ps1"

Write-Host 'Restoring, building, and testing the receiver.'
Invoke-PocNative -FilePath $dotnet -Arguments @(
    'restore', 'src/receiver/DeltaNotificationReceiver.csproj', '--source', 'https://api.nuget.org/v3/index.json'
)
Invoke-PocNative -FilePath $dotnet -Arguments @(
    'restore', 'tests/receiver/DeltaNotificationReceiver.Tests.csproj', '--source', 'https://api.nuget.org/v3/index.json'
)
Invoke-PocNative -FilePath $dotnet -Arguments @(
    'build', 'src/receiver/DeltaNotificationReceiver.csproj', '--no-restore', '-p:RestoreSources=https://api.nuget.org/v3/index.json'
)
Invoke-PocNative -FilePath $dotnet -Arguments @(
    'run', '--project', 'tests/receiver/DeltaNotificationReceiver.Tests.csproj', '--no-restore',
    '-p:RestoreSources=https://api.nuget.org/v3/index.json', '--', '--progress', 'off'
)

$pythonExecutable = $null
$pythonPrefix = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3.11 -c 'import sys' 2>$null
    if ($LASTEXITCODE -eq 0) {
        $pythonExecutable = (Get-Command py).Source
        $pythonPrefix = @('-3.11')
    }
}
if (-not $pythonExecutable) {
    $pythonExecutable = Assert-PocTool -Name 'python'
}

Write-Host 'Compiling and testing Databricks Python.'
& $lintPython -c 'import ruff' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Install tests/databricks/requirements.txt before running Python lint checks.'
}
Invoke-PocNative -FilePath $lintPython -Arguments @(
    '-m', 'ruff', 'check', 'databricks/src', 'tests/databricks', 'scripts/validate-bundle.py'
)
Invoke-PocNative -FilePath $lintPython -Arguments @('scripts/validate-bundle.py')
Invoke-PocNative -FilePath $pythonExecutable -Arguments ($pythonPrefix + @(
    '-m', 'compileall', '-q', 'databricks/src', 'tests/databricks'
))
if ($SkipSparkTests) {
    Invoke-PocNative -FilePath $pythonExecutable -Arguments ($pythonPrefix + @(
        '-m', 'unittest', 'tests.databricks.test_contract', '-v'
    ))
}
else {
    & $pythonExecutable @pythonPrefix -c "import importlib.util, jsonschema; assert importlib.util.find_spec('pyspark')" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Install tests/databricks/requirements.txt into the selected Python environment before running Spark tests."
    }
    if (-not (Get-Command java -ErrorAction SilentlyContinue) -and -not $env:JAVA_HOME -and $IsWindows) {
        $jdk = Get-ChildItem 'C:/Program Files/Microsoft' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($jdk) {
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.FullName, 'Process')
            [Environment]::SetEnvironmentVariable('PATH', "$($jdk.FullName)/bin;$env:PATH", 'Process')
        }
    }
    if (-not (Get-Command java -ErrorAction SilentlyContinue) -and -not $env:JAVA_HOME) {
        throw 'Java is required for local Spark tests. Install OpenJDK 17 or set JAVA_HOME.'
    }
    [Environment]::SetEnvironmentVariable('PYSPARK_PYTHON', (& $pythonExecutable @pythonPrefix -c 'import sys; print(sys.executable)'), 'Process')
    Invoke-PocNative -FilePath $pythonExecutable -Arguments ($pythonPrefix + @(
        '-m', 'unittest', 'discover', '-s', 'tests/databricks', '-p', 'test_*.py', '-v'
    ))
}

    Write-Host 'Testing Phase 6 verifier helpers.'
    & "$PSScriptRoot/verify-poc.ps1" -EnvironmentName self-test -SelfTest

    Write-Host 'Local validation passed.'
}