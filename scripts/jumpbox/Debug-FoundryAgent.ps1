# Runs ON the jumpbox. Bisects a failing agent run: first a plain agent with no tools
# (tests the model path), then dumps run steps for the search-tool agent.
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

function Start-AgentRun {
    param($AgentId, [string]$Question)
    $thread = Invoke-Foundry -Method POST -Path '/threads' -Body @{}
    if (-not $thread.ok) { Write-Output "  thread http $($thread.code) $($thread.body)"; return $null }
    $tid = $thread.body.id
    [void](Invoke-Foundry -Method POST -Path "/threads/$tid/messages" -Body @{ role = 'user'; content = $Question })
    $run = Invoke-Foundry -Method POST -Path "/threads/$tid/runs" -Body @{ assistant_id = $AgentId }
    if (-not $run.ok) { Write-Output "  run http $($run.code) $($run.body)"; return $null }
    $rid = $run.body.id
    $status = $run.body.status
    for ($i = 0; $i -lt 40 -and $status -notin @('completed', 'failed', 'cancelled', 'expired'); $i++) {
        Start-Sleep -Seconds 3
        $p = Invoke-Foundry -Method GET -Path "/threads/$tid/runs/$rid"
        $status = $p.body.status
    }
    return @{ thread = $tid; run = $rid; status = $status }
}

Write-Output "=== A. Plain agent, no tools (tests the model path) ==="
$plain = Invoke-Foundry -Method POST -Path '/assistants' -Body @{
    model        = 'gpt-5.2'
    name         = 'funwithfoundry-diag-plain'
    instructions = 'Answer in one short sentence.'
}
if (-not $plain.ok) {
    Write-Output "  create http $($plain.code) $($plain.body)"
}
else {
    $r = Start-AgentRun -AgentId $plain.body.id -Question 'Say hello in five words.'
    Write-Output "  status: $($r.status)"
    if ($r.status -eq 'completed') {
        $m = Invoke-Foundry -Method GET -Path "/threads/$($r.thread)/messages"
        foreach ($x in ($m.body.data | Where-Object role -eq 'assistant')) {
            foreach ($c in $x.content) { if ($c.text) { Write-Output "  A: $($c.text.value)" } }
        }
    }
    else {
        $p = Invoke-Foundry -Method GET -Path "/threads/$($r.thread)/runs/$($r.run)"
        Write-Output "  last_error: $($p.body.last_error | ConvertTo-Json -Depth 5 -Compress)"
    }
    [void](Invoke-Foundry -Method DELETE -Path "/assistants/$($plain.body.id)")
}

Write-Output ""
Write-Output "=== B. Run steps for the search-tool agent ==="
$agents = Invoke-Foundry -Method GET -Path '/assistants'
$kb = $agents.body.data | Where-Object name -eq 'funwithfoundry-kb-agent' | Select-Object -First 1
if (-not $kb) { Write-Output "  agent not found"; return }
Write-Output "  agent: $($kb.id)"
Write-Output "  tool_resources: $($kb.tool_resources | ConvertTo-Json -Depth 10 -Compress)"

$r = Start-AgentRun -AgentId $kb.id -Question 'What is the maintenance window code?'
Write-Output "  status: $($r.status)"
$p = Invoke-Foundry -Method GET -Path "/threads/$($r.thread)/runs/$($r.run)"
Write-Output "  last_error: $($p.body.last_error | ConvertTo-Json -Depth 5 -Compress)"
$steps = Invoke-Foundry -Method GET -Path "/threads/$($r.thread)/runs/$($r.run)/steps"
if ($steps.ok) {
    foreach ($s in $steps.body.data) {
        Write-Output "  step $($s.type) status=$($s.status)"
        if ($s.last_error) { Write-Output "    error: $($s.last_error | ConvertTo-Json -Depth 5 -Compress)" }
        if ($s.step_details) { Write-Output "    details: $($s.step_details | ConvertTo-Json -Depth 6 -Compress)" }
    }
}
else {
    Write-Output "  steps http $($steps.code) $($steps.body)"
}
