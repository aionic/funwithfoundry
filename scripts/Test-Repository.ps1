<#
.SYNOPSIS
    Cloud-free repository checks. Never discovers credentials or invokes Azure CLIs.
.DESCRIPTION
    Supply PythonPath or activate a virtual environment. IngestionPythonPath allows
    the Function and native agent to retain their different azure-identity pins.
    Release ingestion tests require Python 3.11. DocumentationPythonPath optionally
    isolates documentation tools from the runtime environments.
    Quick is syntax-only. Release rejects skipped tests and requires documentation tools.
    Terraform additionally checks formatting, validates, and runs mocked auth tests.
#>
[CmdletBinding()]
param(
    [string]$PythonPath = $env:FWF_PYTHON,
    [string]$IngestionPythonPath = $env:FWF_INGEST_PYTHON,
    [string]$DocumentationPythonPath = $env:FWF_DOCS_PYTHON,
    [switch]$Quick,
    [switch]$Release,
    [switch]$Terraform,
    [ValidateSet('Auto', 'Required', 'Skip')][string]$Documentation = 'Auto'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
}

function Resolve-TestPython {
    param([string]$SelectedPath)
    if (-not $SelectedPath -and $env:VIRTUAL_ENV) {
        $SelectedPath = Join-Path $env:VIRTUAL_ENV $(if ($IsWindows) { 'Scripts/python.exe' } else { 'bin/python' })
    }
    if (-not $SelectedPath -or -not (Test-Path -LiteralPath $SelectedPath -PathType Leaf)) {
        throw 'Python is not configured. Supply -PythonPath, set FWF_PYTHON, or activate a uv virtual environment. PATH Python is never used implicitly.'
    }
    (Resolve-Path -LiteralPath $SelectedPath).Path
}

if ($Release -and ($Quick -or $Documentation -eq 'Skip')) {
    throw 'Release cannot use Quick or skip documentation checks.'
}
if ($Release) { $Documentation = 'Required' }
$PythonPath = Resolve-TestPython $PythonPath
if (-not $IngestionPythonPath) { $IngestionPythonPath = $PythonPath }
if (-not $Quick) { $IngestionPythonPath = Resolve-TestPython $IngestionPythonPath }

Push-Location $root
try {
    $files = @(git -c core.quotepath=false ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate repository files.' }
    $files = @($files | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $powershellFiles = @($files | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' })
    if (-not $powershellFiles.Count) { throw 'No PowerShell files found; refusing an empty check.' }
    foreach ($file in $powershellFiles) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "PowerShell parse failed for ${file}: $($parseErrors -join '; ')" }
    }
    Write-Host "PASS PowerShell parsing: $($powershellFiles.Count) files"
    $pythonRunner = Join-Path $root '.github/scripts/run-python-checks.py'
    $pythonFiles = @($files | Where-Object { $_ -match '\.py$' })
    Invoke-Checked $PythonPath (@($pythonRunner, 'syntax') + $pythonFiles)
    if ($Quick) {
        Write-Host 'PASS quick syntax checks only; tests, Terraform, and documentation were not run.'
        return
    }

    $releaseArguments = if ($Release) { @('--release') } else { @() }
    Invoke-Checked $IngestionPythonPath (@($pythonRunner, 'ingestion') + $releaseArguments)
    Invoke-Checked $PythonPath (@($pythonRunner, 'retrieval') + $releaseArguments)
    Invoke-Checked $PythonPath (@($pythonRunner, 'knowledge_schema') + $releaseArguments)
    $shell = (Get-Process -Id $PID).Path
    foreach ($test in @('Test-OperationalGuards.ps1', 'Test-NativeDeployment.ps1', 'Test-Deployment.ps1',
        'Test-NativeKnowledgeSource.ps1', 'Test-NativeIngestion.ps1', 'Test-NativePrivateLinks.ps1')) {
        Invoke-Checked $shell @('-NoProfile', '-File', (Join-Path $root "tests/$test"))
    }
    if ($IsWindows) {
        $guestShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        foreach ($test in @('Test-NativeDeployment.ps1', 'Test-NativeKnowledgeSource.ps1', 'Test-NativeIngestion.ps1', 'Test-NativePrivateLinks.ps1')) {
            Invoke-Checked $guestShell @('-NoProfile', '-File', (Join-Path $root "tests/$test"))
        }
        Invoke-Checked $shell @('-NoProfile', '-File', (Join-Path $root 'tests/Test-ArtifactTransfer.ps1'))
    }
    elseif ($Release) { throw 'Release requires the Windows artifact transport guard suite.' }
    else { Write-Host 'NOT RUN Windows artifact transport guards (Windows and native OpenSSH clients required).' }

    if ($Terraform) {
        Invoke-Checked 'terraform' @('-chdir=terraform', 'fmt', '-check', '-recursive', '-no-color')
        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "fwf-terraform-check-$([guid]::NewGuid().ToString('N'))"
        $savedTerraformEnvironment = @{}
        foreach ($variable in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^TF_(DATA_DIR|WORKSPACE|CLI_ARGS.*)$' })) {
            $savedTerraformEnvironment[$variable.Name] = $variable.Value
            Remove-Item "Env:$($variable.Name)"
        }
        try {
            foreach ($file in @($files | Where-Object { $_ -match '^terraform/.*\.(tf|hcl|tftpl)$' })) {
                $destination = Join-Path $scratch $file
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent)
                Copy-Item -LiteralPath $file -Destination $destination
            }
            $terraformRoot = Join-Path $scratch 'terraform'
            $authModule = Join-Path $terraformRoot 'modules/ingest-function'
            foreach ($directory in @($terraformRoot, $authModule)) {
                $initArguments = @("-chdir=$directory", 'init', '-backend=false', '-input=false', '-no-color')
                if (Test-Path (Join-Path $directory '.terraform.lock.hcl')) { $initArguments += '-lockfile=readonly' }
                Invoke-Checked 'terraform' $initArguments
                Invoke-Checked 'terraform' @("-chdir=$directory", 'validate', '-no-color')
            }
            $nativeTest = Join-Path 'tests' 'native_ingestion.tftest.hcl'
            if (-not (Test-Path (Join-Path $terraformRoot $nativeTest))) { throw 'The mocked native ingestion Terraform test is missing.' }
            $nativeOutput = @(Invoke-Checked 'terraform' @("-chdir=$terraformRoot", 'test', "-filter=$nativeTest", '-json', '-no-color'))
            $nativeEvents = @($nativeOutput | ForEach-Object { $_ | ConvertFrom-Json })
            foreach ($event in $nativeEvents) { Write-Host $event.'@message' }
            $nativeSummary = @($nativeEvents | Where-Object type -eq 'test_summary')
            if ($nativeSummary.Count -ne 1 -or $nativeSummary[0].test_summary.status -ne 'pass' -or
                $nativeSummary[0].test_summary.passed -lt 1 -or $nativeSummary[0].test_summary.skipped -ne 0) {
                throw 'Native ingestion Terraform contract tests must execute successfully without skips.'
            }
            $authTest = Join-Path 'tests' 'auth.tftest.hcl'
            if (-not (Test-Path (Join-Path $authModule $authTest))) { throw 'The mocked Terraform auth test is missing.' }
            $testOutput = @(Invoke-Checked 'terraform' @("-chdir=$authModule", 'test', "-filter=$authTest", '-json', '-no-color'))
            $events = @($testOutput | ForEach-Object { $_ | ConvertFrom-Json })
            foreach ($event in $events) { Write-Host $event.'@message' }
            $summaries = @($events | Where-Object type -eq 'test_summary')
            if ($summaries.Count -ne 1 -or $summaries[0].test_summary.status -ne 'pass' -or
                $summaries[0].test_summary.passed -lt 1 -or $summaries[0].test_summary.skipped -ne 0) {
                throw 'Terraform auth tests must execute successfully; an empty or skipped suite is not a pass.'
            }
            Write-Host 'PASS Terraform root/module validation and mocked ingestion auth tests'
        }
        finally {
            if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
            foreach ($name in $savedTerraformEnvironment.Keys) { Set-Item "Env:$name" $savedTerraformEnvironment[$name] }
        }
    }
    else { Write-Host 'NOT RUN Terraform (opt in with -Terraform; CI always enables it).' }

    if ($Documentation -ne 'Skip') {
        if (-not $DocumentationPythonPath) { $DocumentationPythonPath = $PythonPath }
        $DocumentationPythonPath = Resolve-TestPython $DocumentationPythonPath
        & (Join-Path $root '.github/scripts/Test-Documentation.ps1') -PythonPath $DocumentationPythonPath -Required:($Documentation -eq 'Required')
    }
    else { Write-Host 'NOT RUN documentation (explicit -Documentation Skip).' }
    Write-Host 'PASS requested repository checks; this is not cloud deployment or integration evidence.'
}
finally { Pop-Location }
