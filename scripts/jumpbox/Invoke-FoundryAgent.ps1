# Runs ON the jumpbox. Creates a Foundry agent wired to the AI Search index and asks it
# a question. The project endpoint is private, so this only works from inside the VNet.
#
# The agent uses the azure_ai_search tool against the index directly. The Foundry IQ
# knowledge base is a separate Search-side construct over the same index.
$ErrorActionPreference = 'Continue'

$api = '2025-05-01'
$agentName = 'funwithfoundry-kb-agent'

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

Write-Output "=== 1. Find the AI Search connection ==="
$conns = Invoke-Foundry -Method GET -Path '/connections'
if (-not $conns.ok) { Write-Output "  http $($conns.code) $($conns.body)"; return }
$search = $conns.body.value | Where-Object { $_.type -eq 'AzureAISearch' -or $_.type -eq 'CognitiveSearch' } | Select-Object -First 1
if (-not $search) {
    Write-Output "  no search connection found. Available:"
    $conns.body.value | ForEach-Object { Write-Output "   - $($_.name) [$($_.type)]" }
    return
}
Write-Output "  $($search.name) [$($search.type)]"
Write-Output "  id: $($search.id)"

Write-Output ""
Write-Output "=== 2. Create or reuse the agent ==="
$existing = Invoke-Foundry -Method GET -Path '/assistants'
$agent = $null
if ($existing.ok) { $agent = $existing.body.data | Where-Object name -eq $agentName | Select-Object -First 1 }

# An agent pinned to the wrong model fails every tool run, so replace rather than reuse.
if ($agent -and $agent.model -ne $AgentToolModel) {
    Write-Output "  existing agent is on $($agent.model), recreating on $AgentToolModel"
    [void](Invoke-Foundry -Method DELETE -Path "/assistants/$($agent.id)")
    $agent = $null
}

if ($agent) {
    Write-Output "  reusing $($agent.id) [$($agent.model)]"
}
else {
    $def = @{
        model        = $AgentToolModel
        name         = $agentName
        instructions = 'You answer strictly from the indexed funwithfoundry documents. Cite the document title. If the answer is not in the documents, say so.'
        tools        = @(@{ type = 'azure_ai_search' })
        tool_resources = @{
            azure_ai_search = @{
                indexes = @(
                    @{
                        index_connection_id = $search.id
                        index_name          = $SearchIndex
                        query_type          = 'simple'
                    }
                )
            }
        }
    }
    $r = Invoke-Foundry -Method POST -Path '/assistants' -Body $def
    if (-not $r.ok) { Write-Output "  http $($r.code) $($r.body)"; return }
    $agent = $r.body
    Write-Output "  created $($agent.id)"
}

Write-Output ""
Write-Output "=== 3. Ask the agent ==="
$question = 'What is the maintenance window code, and why is the agent subnet 172.16.0.0/24?'
Write-Output "  Q: $question"

$thread = Invoke-Foundry -Method POST -Path '/threads' -Body @{}
if (-not $thread.ok) { Write-Output "  thread http $($thread.code) $($thread.body)"; return }
$threadId = $thread.body.id

$msg = Invoke-Foundry -Method POST -Path "/threads/$threadId/messages" -Body @{ role = 'user'; content = $question }
if (-not $msg.ok) { Write-Output "  message http $($msg.code) $($msg.body)"; return }

$run = Invoke-Foundry -Method POST -Path "/threads/$threadId/runs" -Body @{ assistant_id = $agent.id }
if (-not $run.ok) { Write-Output "  run http $($run.code) $($run.body)"; return }
$runId = $run.body.id

$status = $run.body.status
for ($i = 0; $i -lt 60 -and $status -notin @('completed', 'failed', 'cancelled', 'expired'); $i++) {
    Start-Sleep -Seconds 3
    $poll = Invoke-Foundry -Method GET -Path "/threads/$threadId/runs/$runId"
    if (-not $poll.ok) { Write-Output "  poll http $($poll.code) $($poll.body)"; return }
    $status = $poll.body.status
}
Write-Output "  run status: $status"
if ($status -ne 'completed') {
    $poll = Invoke-Foundry -Method GET -Path "/threads/$threadId/runs/$runId"
    Write-Output "  last_error: $($poll.body.last_error | ConvertTo-Json -Depth 5 -Compress)"
    return
}

Write-Output ""
Write-Output "=== 4. Answer ==="
$msgs = Invoke-Foundry -Method GET -Path "/threads/$threadId/messages"
if (-not $msgs.ok) { Write-Output "  http $($msgs.code) $($msgs.body)"; return }
foreach ($m in ($msgs.body.data | Where-Object role -eq 'assistant')) {
    foreach ($c in $m.content) {
        if ($c.text) {
            Write-Output $c.text.value
            if ($c.text.annotations) {
                Write-Output ""
                Write-Output "  citations:"
                foreach ($a in $c.text.annotations) { Write-Output "   - $($a.text)" }
            }
        }
    }
}
