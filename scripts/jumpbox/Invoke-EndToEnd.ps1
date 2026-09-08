# Runs ON the jumpbox. End-to-end proof of the ingestion path:
#   document -> Content Understanding (SCUS) -> AI Search index (CUS, across the vWAN)
#   -> Foundry IQ knowledge base -> grounded retrieval
# Search and CU are both private, so this can only run from inside the VNet.
# Resource names are injected by scripts/Invoke-JumpboxScript.ps1.

$ErrorActionPreference = 'Continue'

$cu = "https://$FqdnCu"
$search = "https://$FqdnSearch"
$foundry = "https://$FqdnFoundryCog"
$index = 'spo-docs'
$ks = 'spo-knowledge-source'
$kb = 'spo-knowledge-base'

$cuApi = '2025-11-01'
$searchApi = '2024-07-01'
$agenticApi = '2026-05-01-preview'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

function Invoke-Api {
    param([string]$Method, [string]$Url, [string]$Token, $Body)
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $json = if ($Body) { $Body | ConvertTo-Json -Depth 20 } else { $null }
    try {
        if ($json) {
            $r = Invoke-WebRequest -Uri $Url -Method $Method -Headers $headers -Body $json -TimeoutSec 120 -UseBasicParsing
        }
        else {
            $r = Invoke-WebRequest -Uri $Url -Method $Method -Headers $headers -TimeoutSec 120 -UseBasicParsing
        }
        return @{ ok = $true; code = $r.StatusCode; body = $r.Content }
    }
    catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $body = ''
        if ($resp) { try { $body = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() } catch {} }
        return @{ ok = $false; code = $code; body = $body; err = $_.Exception.Message }
    }
}

$cogToken = Get-ImdsToken -Resource 'https://cognitiveservices.azure.com/'
$searchToken = Get-ImdsToken -Resource 'https://search.azure.com/'

# --- 1. Index -----------------------------------------------------------------
Write-Output "=== 1. Create search index ==="
$indexDef = @{
    name   = $index
    fields = @(
        @{ name = 'id'; type = 'Edm.String'; key = $true; filterable = $true },
        @{ name = 'title'; type = 'Edm.String'; searchable = $true; retrievable = $true },
        @{ name = 'content'; type = 'Edm.String'; searchable = $true; retrievable = $true; analyzer = 'standard.lucene' }
    )
    semantic = @{
        defaultConfiguration = 'default-semantic'
        configurations       = @(
            @{
                name              = 'default-semantic'
                prioritizedFields = @{
                    titleField               = @{ fieldName = 'title' }
                    prioritizedContentFields = @(@{ fieldName = 'content' })
                }
            }
        )
    }
}
$r = Invoke-Api -Method PUT -Url "$search/indexes/$index`?api-version=$searchApi" -Token $searchToken -Body $indexDef
Write-Output "  http $($r.code) $(if($r.ok){'OK'}else{$r.body.Substring(0,[Math]::Min(200,$r.body.Length))})"

# --- 2. Content Understanding -------------------------------------------------
Write-Output ""
Write-Output "=== 2. Analyze document with Content Understanding (SCUS) ==="
$sample = @"
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
$bytes = [System.Text.Encoding]::UTF8.GetBytes($sample)
$analyzeUrl = "$cu/contentunderstanding/analyzers/prebuilt-document:analyzeBinary?api-version=$cuApi"

$markdown = $null
try {
    $sub = Invoke-WebRequest -Uri $analyzeUrl -Method Post -Body $bytes `
        -Headers @{ Authorization = "Bearer $cogToken"; 'Content-Type' = 'application/octet-stream' } `
        -TimeoutSec 120 -UseBasicParsing
    $op = $sub.Headers['Operation-Location']
    if ($op -is [array]) { $op = $op[0] }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        $poll = Invoke-RestMethod -Uri $op -Headers @{ Authorization = "Bearer $cogToken" } -TimeoutSec 60
        if ($poll.status -eq 'Succeeded') {
            $markdown = ($poll.result.contents | ForEach-Object { $_.markdown }) -join "`n"
            break
        }
        if ($poll.status -eq 'Failed') { Write-Output "  analysis failed"; break }
    }
}
catch { Write-Output "  submit failed: $($_.Exception.Message)" }

if (-not $markdown) { Write-Output "  no markdown produced - stopping"; exit 1 }
Write-Output "  OK - $($markdown.Length) chars of markdown"

# --- 3. Push across the vWAN --------------------------------------------------
Write-Output ""
Write-Output "=== 3. Push into AI Search (CUS) across the vWAN ==="
$docs = @{
    value = @(
        @{
            '@search.action' = 'mergeOrUpload'
            id               = 'architecture-note'
            title            = 'funwithfoundry architecture note'
            content          = $markdown
        }
    )
}
$r = Invoke-Api -Method POST -Url "$search/indexes/$index/docs/index?api-version=$searchApi" -Token $searchToken -Body $docs
Write-Output "  http $($r.code) $(if($r.ok){'OK'}else{$r.body})"
Start-Sleep -Seconds 5

# --- 4. Retrieve --------------------------------------------------------------
Write-Output ""
Write-Output "=== 4. Query the index ==="
$r = Invoke-Api -Method GET -Url "$search/indexes/$index/docs?api-version=$searchApi&search=maintenance+window+code&`$select=id,title" -Token $searchToken
if ($r.ok) {
    $hits = ($r.body | ConvertFrom-Json).value
    Write-Output "  hits: $($hits.Count)"
    foreach ($h in $hits) { Write-Output "    - $($h.id) / $($h.title)" }
}
else { Write-Output "  http $($r.code) $($r.body)" }

# --- 5. Foundry IQ ------------------------------------------------------------
Write-Output ""
Write-Output "=== 5. Foundry IQ knowledge source + knowledge base ==="
$ksDef = @{
    name                  = $ks
    kind                  = 'searchIndex'
    description           = 'Documents processed by Content Understanding.'
    searchIndexParameters = @{ searchIndexName = $index }
}
$r = Invoke-Api -Method PUT -Url "$search/knowledgeSources/$ks`?api-version=$agenticApi" -Token $searchToken -Body $ksDef
Write-Output "  knowledgeSource: http $($r.code) $(if($r.ok){'OK'}else{$r.body.Substring(0,[Math]::Min(300,$r.body.Length))})"

$kbDef = @{
    name             = $kb
    description      = 'Foundry IQ knowledge base over ingested content.'
    # alwaysQuery is rejected here and returns a bare 400 with no error body.
    knowledgeSources = @(@{ name = $ks })
    models           = @(
        @{
            kind                 = 'azureOpenAI'
            azureOpenAIParameters = @{
                # Must be the openai.azure.com hostname. The cognitiveservices hostname
                # returns 403 for the planner even with Cognitive Services OpenAI User.
                resourceUri  = "https://$FqdnFoundryOAI"
                deploymentId = 'gpt-5.2'
                modelName    = 'gpt-5.2'
            }
        }
    )
}
$r = Invoke-Api -Method PUT -Url "$search/knowledgeBases/$kb`?api-version=$agenticApi" -Token $searchToken -Body $kbDef
Write-Output "  knowledgeBase:   http $($r.code) $(if($r.ok){'OK'}else{$r.body.Substring(0,[Math]::Min(300,$r.body.Length))})"

if ($r.ok) {
    Write-Output ""
    Write-Output "=== 6. Grounded retrieval (hello world) ==="
    $q = @{ messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = 'What is the maintenance window code?' }) }) }
    $r = Invoke-Api -Method POST -Url "$search/knowledgeBases/$kb/retrieve?api-version=$agenticApi" -Token $searchToken -Body $q
    if ($r.ok) {
        $resp = $r.body | ConvertFrom-Json
        foreach ($m in $resp.response) { foreach ($p in $m.content) { Write-Output "  $($p.text)" } }
    }
    else { Write-Output "  http $($r.code) $($r.body.Substring(0,[Math]::Min(400,$r.body.Length)))" }
}
