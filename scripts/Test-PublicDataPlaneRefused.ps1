# Root-URL probes are meaningless against Cognitive Services hosts - the frontend answers
# 200 regardless of network ACLs. Only an authenticated data-plane call proves anything.
[CmdletBinding()]
param([string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'))

$ErrorActionPreference = 'Stop'

function Test-DataPlane {
    param([string]$Label, [string]$Url, [string]$Scope)

    $code = 0
    $outcome = 'Inconclusive'
    $token = $null
    try {
        $token = az account get-access-token --scope $Scope --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($token -join ''))) {
            return [pscustomobject]@{ Label = $Label; Status = 'FAIL'; Outcome = 'TokenUnavailable'; HttpStatus = 0 }
        }
        $response = Invoke-WebRequest -Uri $Url -Headers @{ Authorization = "Bearer $token" } `
            -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        $code = [int]$response.StatusCode
        $outcome = 'Reachable'
    }
    catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $body = [string]$_.ErrorDetails.Message
        if (-not $body -and $resp) {
            try {
                if ($resp.Content -is [System.Net.Http.HttpContent]) {
                    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
                else {
                    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
                    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            }
            catch {}
        }
        if ($code -eq 403 -and $body -match '(?i)public (?:network )?access (?:is )?disabled|access denied due to (?:virtual network|vnet|firewall)|request is not allowed through the current network|client IP address .* is not allowed|source is not allowed by applicable rules[\s\S]*publicNetworkAccess: Disabled') {
            $outcome = 'NetworkDenied'
        }
        elseif ($code -in @(401, 403)) { $outcome = 'UnauthorizedOrInconclusive' }
    }
    finally { $token = $null }

    $status = if ($outcome -eq 'NetworkDenied') { 'PASS' } else { 'FAIL' }
    [pscustomobject]@{ Label = $Label; Status = $status; Outcome = $outcome; HttpStatus = $code }
}

Write-Host "=== Authenticated data-plane probes from a PUBLIC workstation ===" -ForegroundColor Cyan

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir
if ($LASTEXITCODE -ne 0) { throw 'Lab environment lookup failed.' }
if (-not $lab.Hosts.FoundryOpenAI -or -not $lab.Hosts.ContentUnderstanding -or -not $lab.Hosts.Search) {
    throw 'Expected data-plane hosts are missing from the lab environment.'
}

$results = @(
Test-DataPlane -Label 'Foundry CUS (openai models)' `
    -Url "https://$($lab.Hosts.FoundryOpenAI)/openai/models?api-version=2024-10-21" `
    -Scope 'https://cognitiveservices.azure.com/.default'

Test-DataPlane -Label 'Content Understanding SCUS (analyzers)' `
    -Url "https://$($lab.Hosts.ContentUnderstanding)/contentunderstanding/analyzers?api-version=2025-11-01" `
    -Scope 'https://cognitiveservices.azure.com/.default'

Test-DataPlane -Label 'AI Search CUS (indexes)' `
    -Url "https://$($lab.Hosts.Search)/indexes?api-version=2024-07-01" `
    -Scope 'https://search.azure.com/.default'
)
$results
if (@($results | Where-Object Status -ne 'PASS').Count) {
    throw 'Public data-plane verification failed: reachability, authorization, or inconclusive results cannot prove network isolation.'
}
