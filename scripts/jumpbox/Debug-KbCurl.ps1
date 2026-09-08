# PowerShell is returning empty bodies for Search API errors. curl.exe shows the raw
# response, which is the only way to see why these calls are being rejected.
# Resource names are injected by scripts/Invoke-JumpboxScript.ps1.
$ErrorActionPreference = 'Continue'

$search = "https://$FqdnSearch"
$kb = 'spo-knowledge-base'
$ks = 'spo-knowledge-source'
$openai = "https://$FqdnFoundryOAI"
$api = '2026-05-01-preview'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}
$token = Get-ImdsToken -Resource 'https://search.azure.com/'

$tmp = Join-Path $env:TEMP 'kbtest'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Curl-Json {
    param([string]$Label, [string]$Method, [string]$Url, [string]$Json)
    Write-Host "=== $Label"
    $file = Join-Path $tmp 'body.json'
    if ($Json) { [System.IO.File]::WriteAllText($file, $Json) }
    # $args is an automatic variable in a function scope; use a distinct name.
    $curlArgs = @('-s', '-S', '-i', '-X', $Method, $Url,
        '-H', "Authorization: Bearer $token",
        '-H', 'Content-Type: application/json',
        '-H', 'Accept: application/json')
    if ($Json) { $curlArgs += @('--data-binary', "@$file") }
    $out = & curl.exe @curlArgs 2>&1
    $text = ($out | Out-String)
    if ($text.Length -gt 1500) { $text = $text.Substring(0, 1500) }
    Write-Host $text
    Write-Host ""
}

# 1. Attach a chat model to the knowledge base - agentic retrieval needs a planner.
$withModel = @'
{
  "name": "spo-knowledge-base",
  "knowledgeSources": [ { "name": "spo-knowledge-source" } ],
  "models": [
    {
      "kind": "azureOpenAI",
      "azureOpenAIParameters": {
        "resourceUri": "RESOURCE_URI",
        "deploymentId": "gpt-5.2",
        "modelName": "gpt-5.2"
      }
    }
  ]
}
'@ -replace 'RESOURCE_URI', $openai

Curl-Json -Label 'PUT knowledgeBase with models[]' -Method PUT -Url "$search/knowledgeBases/$kb`?api-version=$api" -Json $withModel

# 2. Retrieve, to see the actual validation error.
$retrieve = @'
{
  "messages": [ { "role": "user", "content": [ { "type": "text", "text": "What is the maintenance window code?" } ] } ]
}
'@
Curl-Json -Label 'POST retrieve' -Method POST -Url "$search/knowledgeBases/$kb/retrieve?api-version=$api" -Json $retrieve
