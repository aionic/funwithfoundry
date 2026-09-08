<#
.SYNOPSIS
    Grant the ingest function's managed identity least-privilege SharePoint access.
.DESCRIPTION
    Two steps, both required:
      1. Assign the Microsoft Graph "Sites.Selected" application role to the identity.
         On its own this grants access to NO sites.
      2. Grant that identity read on one specific site.

    Sites.Selected is preferred over Sites.Read.All because the latter grants tenant-wide
    read of every SharePoint site.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [ValidateSet('read', 'write', 'fullcontrol')]
    [string]$Role = 'read'
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

$principalId = $fn.identity_object
$graphAppId = '00000003-0000-0000-c000-000000000000'

Write-Host "Function identity: $principalId" -ForegroundColor Cyan

# --- 1. Sites.Selected app role -----------------------------------------------
# $Role is a parameter; use a distinct name here or its ValidateSet rejects the object.
$graphSp = az ad sp show --id $graphAppId -o json | ConvertFrom-Json
$appRole = $graphSp.appRoles | Where-Object { $_.value -eq 'Sites.Selected' -and $_.allowedMemberTypes -contains 'Application' }
if (-not $appRole) { throw 'Sites.Selected app role not found on Microsoft Graph.' }

$existing = az rest --method get `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
    -o json 2>$null | ConvertFrom-Json

if ($existing.value | Where-Object { $_.appRoleId -eq $appRole.id }) {
    Write-Host 'Sites.Selected already assigned.' -ForegroundColor DarkGray
}
else {
    $body = @{
        principalId = $principalId
        resourceId  = $graphSp.id
        appRoleId   = $appRole.id
    } | ConvertTo-Json -Compress

    $tmp = Join-Path $env:TEMP 'approle.json'
    [System.IO.File]::WriteAllText($tmp, $body)

    az rest --method post `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        --headers 'Content-Type=application/json' `
        --body "@$tmp" -o none
    Write-Host 'Sites.Selected assigned.' -ForegroundColor Green
}

# --- 2. Scope it to a single site ---------------------------------------------
# Writing /sites/{id}/permissions needs Sites.FullControl.All. The Azure CLI's
# first-party client does not carry that delegated scope, and being Global Admin does
# not change which scopes a client app was consented. If this fails we fall back to
# Sites.Read.All so the function can actually read the document.
#
# Production path: grant the site permission with an app that holds
# Sites.FullControl.All (client credentials), then Sites.Selected stays least-privilege.
$hostname = $lab.SharePoint.Hostname
$sitePath = $lab.SharePoint.SitePath

$siteUrl = if ($sitePath -eq '/' -or [string]::IsNullOrWhiteSpace($sitePath)) {
    "https://graph.microsoft.com/v1.0/sites/$hostname"
}
else {
    "https://graph.microsoft.com/v1.0/sites/${hostname}:$sitePath"
}

$site = az rest --method get --url $siteUrl -o json | ConvertFrom-Json
Write-Host "Site: $($site.displayName) ($($site.id))" -ForegroundColor Cyan

$permBody = @{
    roles               = @($Role)
    grantedToIdentities = @(
        @{ application = @{ id = $fn.identity_client; displayName = $fn.name } }
    )
} | ConvertTo-Json -Depth 10 -Compress

$permTmp = Join-Path $env:TEMP 'siteperm.json'
[System.IO.File]::WriteAllText($permTmp, $permBody)

az rest --method post `
    --url "https://graph.microsoft.com/v1.0/sites/$($site.id)/permissions" `
    --headers 'Content-Type=application/json' `
    --body "@$permTmp" -o none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "Granted '$Role' on $($site.displayName) - Sites.Selected is correctly scoped." -ForegroundColor Green
    return
}

Write-Host 'Could not write the site permission (needs Sites.FullControl.All).' -ForegroundColor Yellow
Write-Host 'Falling back to the Sites.Read.All app role: tenant-wide SharePoint READ.' -ForegroundColor Yellow

$readAll = $graphSp.appRoles | Where-Object { $_.value -eq 'Sites.Read.All' -and $_.allowedMemberTypes -contains 'Application' }
if ($existing.value | Where-Object { $_.appRoleId -eq $readAll.id }) {
    Write-Host 'Sites.Read.All already assigned.' -ForegroundColor DarkGray
    return
}

$readBody = @{
    principalId = $principalId
    resourceId  = $graphSp.id
    appRoleId   = $readAll.id
} | ConvertTo-Json -Compress

$readTmp = Join-Path $env:TEMP 'approle-readall.json'
[System.IO.File]::WriteAllText($readTmp, $readBody)

az rest --method post `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
    --headers 'Content-Type=application/json' `
    --body "@$readTmp" -o none

Write-Host 'Sites.Read.All assigned.' -ForegroundColor Green
