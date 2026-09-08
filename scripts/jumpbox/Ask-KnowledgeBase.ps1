# Hello world: grounded retrieval from the Foundry IQ knowledge base.
# Runs ON the jumpbox - the search service is private.
$ErrorActionPreference = 'Continue'

$search = "https://$FqdnSearch"
$kb = 'spo-knowledge-base'
$agenticApi = '2026-05-01-preview'
$question = 'What is the maintenance window code, and why is the agent subnet 172.16.0.0/24?'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

$token = Get-ImdsToken -Resource 'https://search.azure.com/'

Write-Host "Question: $question"
Write-Host ""

$body = @{
    messages = @(
        @{ role = 'user'; content = @(@{ type = 'text'; text = $question }) }
    )
} | ConvertTo-Json -Depth 20

try {
    $r = Invoke-WebRequest -Uri "$search/knowledgeBases/$kb/retrieve?api-version=$agenticApi" -Method POST `
        -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -Body $body -TimeoutSec 180 -UseBasicParsing

    Write-Host "http $($r.StatusCode)"
    $resp = $r.Content | ConvertFrom-Json

    Write-Host ""
    Write-Host "=== Grounded response ==="
    foreach ($m in $resp.response) {
        foreach ($p in $m.content) { Write-Host $p.text }
    }

    if ($resp.references) {
        Write-Host ""
        Write-Host "=== Citations ==="
        foreach ($ref in $resp.references) {
            $t = $ref.sourceData.title
            if (-not $t) { $t = $ref.docKey }
            Write-Host "  - $t"
        }
    }
}
catch {
    $resp = $_.Exception.Response
    $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
    $b = ''
    if ($resp) { try { $b = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() } catch {} }
    Write-Host "http $code"
    Write-Host $b
}
