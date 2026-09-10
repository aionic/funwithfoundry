<#
.SYNOPSIS
    Grant the ingest function's managed identity least-privilege SharePoint access.
.DESCRIPTION
    Two steps, both required:
      1. Assign the Microsoft Graph "Sites.Selected" application role to the identity.
         On its own this grants access to NO sites.
      2. Grant that identity read on one specific site.

    No tenant-wide permission is assigned when site consent is unavailable.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [ValidateSet('read', 'write', 'fullcontrol')]
    [string]$Role = 'read'
)

$ErrorActionPreference = 'Stop'

function Invoke-GraphRequest {
    param([string]$Uri, [string]$Method = 'get', [object]$Body)
    $tmp = $null
    try {
        $arguments = @('rest', '--method', $Method, '--url', $Uri, '-o', 'json')
        if ($null -ne $Body) {
            $tmp = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 10 -Compress))
            $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$tmp")
        }
        $response = & az @arguments
        if ($LASTEXITCODE -ne 0) { throw "Graph $Method failed (exit $LASTEXITCODE)." }
        if ($response) { $response | ConvertFrom-Json }
    }
    finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Get-GraphCollection {
    param([string]$Uri)
    while ($Uri) {
        $page = Invoke-GraphRequest -Uri $Uri
        if ($null -eq $page.value) { throw 'Graph collection response is missing value.' }
        $page.value
        $Uri = $page.'@odata.nextLink'
        if ($Uri -and -not $Uri.StartsWith('https://graph.microsoft.com/v1.0/')) {
            throw 'Unexpected Graph pagination URL.'
        }
    }
}

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir
if ($LASTEXITCODE -ne 0) { throw 'Lab environment lookup failed.' }

Push-Location $TerraformDir
try {
    $output = terraform output -json ingest_function
    if ($LASTEXITCODE -ne 0) { throw "Terraform output failed (exit $LASTEXITCODE)." }
    $fn = $output | ConvertFrom-Json
}
finally {
    Pop-Location
}

$principalId = $fn.identity_object
$graphAppId = '00000003-0000-0000-c000-000000000000'

if (-not $principalId -or -not $fn.identity_client -or -not $lab.SharePoint.Hostname) {
    throw 'Terraform must resolve the function identity and configured SharePoint site.'
}
Write-Host "Function identity: $principalId" -ForegroundColor Cyan

$graphOutput = az ad sp show --id $graphAppId -o json
if ($LASTEXITCODE -ne 0) { throw "Graph service principal lookup failed (exit $LASTEXITCODE)." }
$graphSp = $graphOutput | ConvertFrom-Json
$appRoles = @($graphSp.appRoles | Where-Object {
    $_.value -eq 'Sites.Selected' -and $_.allowedMemberTypes -contains 'Application' -and $_.isEnabled
})
if (-not $graphSp.id -or $appRoles.Count -ne 1) { throw 'Expected one enabled Sites.Selected application role on Microsoft Graph.' }
$appRole = $appRoles[0]
$assignmentsUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments"
$existing = @(Get-GraphCollection -Uri $assignmentsUri)
$assigned = @($existing | Where-Object {
    $_.principalId -eq $principalId -and $_.resourceId -eq $graphSp.id -and $_.appRoleId -eq $appRole.id
})

$hostname = $lab.SharePoint.Hostname
$sitePath = $lab.SharePoint.SitePath

$siteUrl = if ($sitePath -eq '/' -or [string]::IsNullOrWhiteSpace($sitePath)) {
    "https://graph.microsoft.com/v1.0/sites/$hostname"
}
else {
    "https://graph.microsoft.com/v1.0/sites/${hostname}:$sitePath"
}

try {
    $site = Invoke-GraphRequest -Uri $siteUrl
    if (-not $site.id) { throw 'Graph did not resolve the configured site.' }
    $permissionsUri = "https://graph.microsoft.com/v1.0/sites/$($site.id)/permissions"
    $permissions = @(Get-GraphCollection -Uri $permissionsUri)
    $matching = @($permissions | Where-Object {
        $identities = @($_.grantedToIdentitiesV2) + @($_.grantedToIdentities) + @($_.grantedToV2) + @($_.grantedTo)
        @($identities.application.id) -contains $fn.identity_client
    })
    if ($matching.Count -gt 1 -or ($matching.Count -eq 1 -and
        (@($matching[0].roles).Count -ne 1 -or $matching[0].roles[0] -ne $Role))) {
        throw "Existing site permissions do not match the single requested '$Role' grant. Have the site administrator reconcile them before rerunning."
    }
    if ($assigned.Count -eq 0) {
        $null = Invoke-GraphRequest -Uri $assignmentsUri -Method post -Body @{
            principalId = $principalId
            resourceId = $graphSp.id
            appRoleId = $appRole.id
        }
    }
    if ($matching.Count -eq 0) {
        $null = Invoke-GraphRequest -Uri $permissionsUri -Method post -Body @{
            roles = @($Role)
            grantedToIdentities = @(@{ application = @{ id = $fn.identity_client; displayName = $fn.name } })
        }
    }
}
catch {
    throw "Site-scoped consent failed. Use an administrator-approved Graph client authorized to manage site permissions (Sites.FullControl.All on the consenting client, not the function), grant '$Role' only on the configured site to client $($fn.identity_client), then rerun. No tenant-wide fallback is attempted. $($_.Exception.Message)"
}

[pscustomobject]@{ Outcome = 'Succeeded'; SiteId = $site.id; ClientId = $fn.identity_client; Role = $Role }
