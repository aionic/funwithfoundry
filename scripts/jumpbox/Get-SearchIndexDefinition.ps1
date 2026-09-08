# Runs ON the jumpbox. Dumps the live index definition. The azure_ai_search tool
# introspects the index, so a malformed semantic or vector config can fail the tool
# regardless of query_type.
$ErrorActionPreference = 'Continue'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

$token = Get-ImdsToken -Resource 'https://search.azure.com/'
$tmp = Join-Path $env:TEMP 'idx'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Curl-Get {
    param([string]$Label, [string]$Url)
    Write-Output "=== $Label"
    $out = & curl.exe -s -S -X GET $Url `
        -H "Authorization: Bearer $token" `
        -H 'Accept: application/json' 2>&1
    $text = ($out | Out-String)
    if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }
    Write-Output $text
    Write-Output ""
}

Curl-Get -Label "index definition ($SearchIndex)" -Url "https://$FqdnSearch/indexes/$SearchIndex`?api-version=2024-07-01"
Curl-Get -Label 'index stats' -Url "https://$FqdnSearch/indexes/$SearchIndex/stats?api-version=2024-07-01"
