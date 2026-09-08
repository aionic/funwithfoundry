# Runs ON the jumpbox. Uploads the demo document into SharePoint using the jumpbox
# managed identity, because the Azure CLI's delegated token cannot write to Graph.
# The Graph call egresses through Azure Firewall (graph-and-sharepoint rule).
$ErrorActionPreference = 'Continue'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

$token = Get-ImdsToken -Resource 'https://graph.microsoft.com'
$headers = @{ Authorization = "Bearer $token" }

Write-Output "=== Resolve site ==="
$siteUrl = if ($SpSitePath -eq '/' -or [string]::IsNullOrWhiteSpace($SpSitePath)) {
    "https://graph.microsoft.com/v1.0/sites/$SpHostname"
}
else {
    "https://graph.microsoft.com/v1.0/sites/${SpHostname}:$SpSitePath"
}

try {
    $site = Invoke-RestMethod -Uri $siteUrl -Headers $headers -TimeoutSec 60
    Write-Output "  $($site.displayName)"
    Write-Output "  id: $($site.id)"
}
catch {
    Write-Output "  FAILED to resolve site: $($_.Exception.Message)"
    return
}

$body = @"
FUNWITHFOUNDRY ARCHITECTURE NOTE

The lab spans two Azure regions joined by a Virtual WAN Standard with Azure Firewall
in both hubs. Central US hosts the network-injected Foundry agent platform. South
Central US hosts Content Understanding.

The agent subnet is 172.16.0.0/24, delegated to Microsoft.App/environments, because
Class A support in Central US is contradicted between the docs and the official sample.

Azure Firewall evaluates network rules before application rules. Without an explicit
private-to-private network rule, cross-spoke traffic to a private endpoint falls
through to an application rule, gets proxied, and arrives at the service from the
firewall public IP.

The maintenance window code is BLUE-HERON-42.
"@

Write-Output ""
Write-Output "=== Upload $SpFilePath ==="
$uploadUrl = "https://graph.microsoft.com/v1.0/sites/$($site.id)/drive/root:/$($SpFilePath):/content"
try {
    $r = Invoke-RestMethod -Uri $uploadUrl -Method Put -Headers $headers `
        -ContentType 'text/plain' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    Write-Output "  uploaded: $($r.name) ($($r.size) bytes)"
    Write-Output "  webUrl:   $($r.webUrl)"
}
catch {
    Write-Output "  FAILED: $($_.Exception.Message)"
    $resp = $_.Exception.Response
    if ($resp) {
        try { Write-Output ([System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()) } catch {}
    }
}
