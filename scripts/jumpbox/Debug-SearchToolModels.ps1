# Runs ON the jumpbox. Same search tool, same index, same connection - only the model
# changes. Isolates whether the azure_ai_search failure is model-specific.
$ErrorActionPreference = 'Continue'

$api = '2025-05-01'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

$token = Get-ImdsToken -Resource 'https://ai.azure.com'
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

function Invoke-Foundry {
    param([string]$Method, [string]$Path, $Body)
    $url = "$ProjectEndpoint$Path" + $(if ($Path -match '\?') { "&api-version=$api" } else { "?api-version=$api" })
    $json = if ($Body) { $Body | ConvertTo-Json -Depth 20 } else { $null }
    try {
        if ($json) {
            $r = Invoke-WebRequest -Uri $url -Method $Method -Headers $headers -Body $json -TimeoutSec 120 -UseBasicParsing
        }
        else {
            $r = Invoke-WebRequest -Uri $url -Method $Method -Headers $headers -TimeoutSec 120 -UseBasicParsing
        }
        return @{ ok = $true; code = $r.StatusCode; body = ($r.Content | ConvertFrom-Json) }
    }
    catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $text = ''
        if ($resp) { try { $text = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() } catch {} }
        return @{ ok = $false; code = $code; body = $text }
    }
}

$conns = Invoke-Foundry -Method GET -Path '/connections'
$search = $conns.body.value | Where-Object { $_.type -in @('AzureAISearch', 'CognitiveSearch') } | Select-Object -First 1

foreach ($model in @('gpt-4o', 'gpt-5.2')) {
    Write-Output "=== model = $model ==="
    $create = Invoke-Foundry -Method POST -Path '/assistants' -Body @{
        model          = $model
        name           = "fwf-modeltest-$model"
        instructions   = 'Answer from the indexed documents only. Cite the document title.'
        tools          = @(@{ type = 'azure_ai_search' })
        tool_resources = @{
            azure_ai_search = @{
                indexes = @(@{
                        index_connection_id = $search.id
                        index_name          = $SearchIndex
                        query_type          = 'simple'
                    })
            }
        }
    }
    if (-not $create.ok) { Write-Output "  create http $($create.code): $($create.body)"; continue }

    $thread = Invoke-Foundry -Method POST -Path '/threads' -Body @{}
    $tid = $thread.body.id
    [void](Invoke-Foundry -Method POST -Path "/threads/$tid/messages" -Body @{ role = 'user'; content = 'What is the maintenance window code?' })
    $run = Invoke-Foundry -Method POST -Path "/threads/$tid/runs" -Body @{ assistant_id = $create.body.id }
    $rid = $run.body.id
    $status = $run.body.status
    for ($i = 0; $i -lt 40 -and $status -notin @('completed', 'failed', 'cancelled', 'expired'); $i++) {
        Start-Sleep -Seconds 3
        $p = Invoke-Foundry -Method GET -Path "/threads/$tid/runs/$rid"
        $status = $p.body.status
    }
    Write-Output "  status: $status"

    if ($status -eq 'completed') {
        $m = Invoke-Foundry -Method GET -Path "/threads/$tid/messages"
        foreach ($x in ($m.body.data | Where-Object role -eq 'assistant')) {
            foreach ($c in $x.content) { if ($c.text) { Write-Output "  A: $($c.text.value)" } }
        }
    }
    else {
        $p = Invoke-Foundry -Method GET -Path "/threads/$tid/runs/$rid"
        Write-Output "  last_error: $($p.body.last_error | ConvertTo-Json -Depth 5 -Compress)"
    }

    [void](Invoke-Foundry -Method DELETE -Path "/assistants/$($create.body.id)")
    Write-Output ""
}
