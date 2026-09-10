<#
.SYNOPSIS
    Run a scripts/jumpbox script on the jumpbox with resolved resource names injected.
.DESCRIPTION
    Terraform is not available on the jumpbox, and the random name suffix changes on
    every rebuild. This prepends a generated variable block to the script body so the
    jumpbox scripts never carry hardcoded names.

    Injected variables: $FoundryAccount, $FoundryProject, $SearchName, $StorageName,
    $CuAccount, $StagingStorage, and the matching $Fqdn* hostnames.
.EXAMPLE
    .\scripts\Invoke-JumpboxScript.ps1 Test-PrivatePath.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Script,
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform')
)

$ErrorActionPreference = 'Stop'

$path = if (Test-Path $Script) { $Script } else { Join-Path $PSScriptRoot "jumpbox\$Script" }
if (-not (Test-Path $path)) { throw "Jumpbox script not found: $Script" }

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir
if ($LASTEXITCODE -ne 0) { throw 'Lab environment lookup failed.' }

if (-not $lab.SubscriptionId -or -not $lab.ResourceGroups.Primary -or -not $lab.Jumpbox.name) {
    throw 'Expected jumpbox identity is missing from the lab environment.'
}
$variables = [ordered]@{
    FoundryAccount = $lab.Primary.Account
    FoundryProject = $lab.Primary.Project
    SearchName = $lab.Primary.Search
    StorageName = $lab.Primary.Storage
    CuAccount = $lab.Secondary.Account
    StagingStorage = $lab.Secondary.StagingStorage
    FqdnFoundrySvc = $lab.Hosts.FoundryServices
    FqdnFoundryCog = $lab.Hosts.FoundryCogSvc
    FqdnFoundryOAI = $lab.Hosts.FoundryOpenAI
    FqdnSearch = $lab.Hosts.Search
    FqdnStorage = $lab.Hosts.Storage
    FqdnCosmos = $lab.Hosts.Cosmos
    FqdnKeyVault = $lab.Hosts.KeyVault
    FqdnCu = $lab.Hosts.ContentUnderstanding
    FqdnCuOpenAI = "$($lab.Secondary.Account).openai.azure.com"
    FqdnStaging = $lab.Hosts.StagingStorage
    SpHostname = $lab.SharePoint.Hostname
    SpSitePath = $lab.SharePoint.SitePath
    SpFilePath = $lab.SharePoint.FilePath
    FunctionApp = $lab.Function.Name
    FunctionHost = $lab.Function.Hostname
    ProjectEndpoint = $lab.Primary.ProjectEndpoint
    SearchIndex = 'spo-docs'
    AgentToolModel = $lab.Primary.AgentToolModel
}
$prelude = ($variables.GetEnumerator() | ForEach-Object {
    '${0} = ''{1}''' -f $_.Key, ([string]$_.Value).Replace("'", "''")
}) -join "`n"
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $path -Raw)))
$marker = 'FWF_RUN_RESULT_' + [guid]::NewGuid().ToString('N') + '='
$wrapper = @"
`$ErrorActionPreference = 'Stop'
`$PSNativeCommandUseErrorActionPreference = `$true
`$global:LASTEXITCODE = 0
`$Error.Clear()
`$succeeded = `$false
try {
$prelude
    . ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded')))) | ForEach-Object {
        if (`$_.Status -eq 'FAIL' -or `$_.Outcome -eq 'Failed' -or `$_.Success -eq `$false -or `$_.ok -eq `$false) {
            throw 'Remote script emitted a failure result.'
        }
        `$_
    }
    if (-not `$? -or `$LASTEXITCODE -ne 0 -or `$Error.Count -gt 0) { throw 'Remote script reported errors.' }
    `$succeeded = `$true
}
catch { `$succeeded = `$false }
finally {
    Write-Output ('$marker' + (@{ succeeded = `$succeeded; exitCode = `$LASTEXITCODE; errorCount = `$Error.Count } | ConvertTo-Json -Compress))
}
"@

$tmp = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $tmp -Value $wrapper -Encoding UTF8
    Write-Host "Running $([System.IO.Path]::GetFileName($path)) on $($lab.Jumpbox.name)..." -ForegroundColor Cyan
    $raw = az vm run-command invoke `
        --subscription $lab.SubscriptionId `
        --resource-group $lab.ResourceGroups.Primary `
        --name $lab.Jumpbox.name `
        --command-id RunPowerShellScript `
        --scripts "@$tmp" -o json
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Jumpbox Run Command invocation failed.' }
    $result = $raw | ConvertFrom-Json
    $entries = @($result.value)
    if (-not $entries.Count -or @($entries | Where-Object { $_.code -notmatch '/succeeded$' -or $_.level -eq 'Error' }).Count) {
        throw 'Jumpbox Run Command did not report successful execution.'
    }
    $stdout = @()
    foreach ($entry in $entries) {
        if ($entry.code -match '/StdErr/') {
            if (-not [string]::IsNullOrWhiteSpace($entry.message)) { throw 'Jumpbox Run Command reported remote stderr.' }
        }
        elseif ($entry.code -match '/StdOut/') { $stdout += $entry.message }
        elseif ($entry.message -match '(?s)\[stdout\]\s*(.*?)\s*\[stderr\](.*)$') {
            if (-not [string]::IsNullOrWhiteSpace($Matches[2])) { throw 'Jumpbox Run Command reported remote stderr.' }
            $stdout += $Matches[1]
        }
        else { throw 'Unrecognized Run Command output; execution is inconclusive.' }
    }
    $text = $stdout -join "`n"
    $sentinels = [regex]::Matches($text, '(?m)^' + [regex]::Escape($marker) + '(\{[^\r\n]+\})\r?$')
    if ($sentinels.Count -ne 1) { throw 'Remote completion marker missing or ambiguous; execution is inconclusive.' }
    $completion = $sentinels[0].Groups[1].Value | ConvertFrom-Json
    if ($completion.succeeded -isnot [bool] -or -not $completion.succeeded -or $null -eq $completion.exitCode -or $completion.exitCode -ne 0 -or $null -eq $completion.errorCount -or $completion.errorCount -ne 0) {
        throw 'Remote script failed according to its completion marker.'
    }
    $text = $text.Replace($sentinels[0].Value, '').Trim()
    if ($text -match '(?im)\b(?:FAIL(?:ED|URE)?|LEAK)\b|\bhttp\s+[45]\d{2}\b|"(?:ok|success)"\s*:\s*false') {
        throw 'Remote script output contains a failure; execution is not successful.'
    }
    [pscustomobject]@{ Outcome = 'Succeeded'; VM = $lab.Jumpbox.name; Output = $text }
}
finally { Remove-Item -LiteralPath $tmp -Force }
