# Root-URL probes are meaningless against Cognitive Services hosts - the frontend answers
# 200 regardless of network ACLs. Only an authenticated data-plane call proves anything.
$ErrorActionPreference = 'Continue'

function Test-DataPlane {
    param([string]$Label, [string]$Url, [string]$Scope)

    $token = (az account get-access-token --scope $Scope --query accessToken -o tsv 2>$null)
    if (-not $token) { Write-Host "  $Label : could not acquire token" -ForegroundColor Yellow; return }

    try {
        $r = Invoke-WebRequest -Uri $Url -Headers @{ Authorization = "Bearer $token" } `
            -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        Write-Host ("{0,-42} REACHABLE http {1}  <-- LEAK" -f $Label, $r.StatusCode) -ForegroundColor Red
    }
    catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $body = ''
        if ($resp) {
            try {
                $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
                $body = $reader.ReadToEnd()
            }
            catch {}
        }

        $blocked = $code -eq 403 -or $body -match 'public network access|not allowed|Forbidden|denied'
        $color = if ($blocked) { 'Green' } else { 'Yellow' }
        $note = if ($blocked) { 'BLOCKED by network rules' } else { 'inconclusive' }
        $snippet = ($body -replace '\s+', ' ')
        if ($snippet.Length -gt 90) { $snippet = $snippet.Substring(0, 90) }
        Write-Host ("{0,-42} http {1}  {2}" -f $Label, $code, $note) -ForegroundColor $color
        if ($snippet) { Write-Host "      $snippet" -ForegroundColor DarkGray }
    }
}

Write-Host "=== Authenticated data-plane probes from a PUBLIC workstation ===" -ForegroundColor Cyan

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1')

Test-DataPlane -Label 'Foundry CUS (openai models)' `
    -Url "https://$($lab.Hosts.FoundryOpenAI)/openai/models?api-version=2024-10-21" `
    -Scope 'https://cognitiveservices.azure.com/.default'

Test-DataPlane -Label 'Content Understanding SCUS (analyzers)' `
    -Url "https://$($lab.Hosts.ContentUnderstanding)/contentunderstanding/analyzers?api-version=2025-11-01" `
    -Scope 'https://cognitiveservices.azure.com/.default'

Test-DataPlane -Label 'AI Search CUS (indexes)' `
    -Url "https://$($lab.Hosts.Search)/indexes?api-version=2024-07-01" `
    -Scope 'https://search.azure.com/.default'
