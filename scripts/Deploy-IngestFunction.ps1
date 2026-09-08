<#
.SYNOPSIS
    Deploy the ingest function to its private SCM endpoint, via the jumpbox.
.DESCRIPTION
    The function app has public network access disabled, so its SCM endpoint is only
    reachable from inside the VNet. This zips src/ingest_func, embeds it as base64 in a
    jumpbox script, and pushes it with the jumpbox managed identity.

    RemoteBuild=true makes the platform install requirements.txt server-side.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\src\ingest_func')
)

$ErrorActionPreference = 'Stop'

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir

Push-Location $TerraformDir
try {
    $fn = terraform output -json ingest_function | ConvertFrom-Json
}
finally {
    Pop-Location
}

$zip = Join-Path $env:TEMP 'ingest_func.zip'
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $SourceDir '*') -DestinationPath $zip -Force
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zip))

Write-Host "Package: $([Math]::Round((Get-Item $zip).Length / 1KB, 1)) KB -> $($fn.name)" -ForegroundColor Cyan

$remote = @"
`$ErrorActionPreference = 'Continue'
`$b64 = '$b64'
`$zipPath = Join-Path `$env:TEMP 'ingest_func.zip'
[System.IO.File]::WriteAllBytes(`$zipPath, [Convert]::FromBase64String(`$b64))
Write-Output "wrote `$((Get-Item `$zipPath).Length) bytes"

`$uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"
`$token = (Invoke-RestMethod -Uri `$uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token

`$scm = 'https://$($fn.name).scm.azurewebsites.net/api/publish?RemoteBuild=true'
Write-Output "POST `$scm"
try {
    `$r = Invoke-WebRequest -Uri `$scm -Method Post ``
        -Headers @{ Authorization = "Bearer `$token" } ``
        -ContentType 'application/zip' ``
        -InFile `$zipPath -TimeoutSec 600 -UseBasicParsing
    Write-Output "  http `$(`$r.StatusCode)"
    Write-Output `$r.Content
}
catch {
    `$resp = `$_.Exception.Response
    `$code = if (`$resp) { [int]`$resp.StatusCode } else { 0 }
    Write-Output "  FAILED http `$code : `$(`$_.Exception.Message)"
    if (`$resp) {
        try { Write-Output ([System.IO.StreamReader]::new(`$resp.GetResponseStream()).ReadToEnd()) } catch {}
    }
}
"@

$tmp = Join-Path $env:TEMP 'deploy-func-remote.ps1'
Set-Content -Path $tmp -Value $remote -Encoding UTF8

az vm run-command invoke `
    --resource-group $lab.ResourceGroups.Primary `
    --name $lab.Jumpbox.name `
    --command-id RunPowerShellScript `
    --scripts "@$tmp" `
    --query 'value[0].message' -o tsv
