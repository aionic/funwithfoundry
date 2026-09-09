# Runs ON the jumpbox. Invokes the New Foundry native hosted agent and requires both
# Foundry IQ and the Search-backed Foundry Toolbox to ground the answer.
$ErrorActionPreference = 'Stop'

$agentName = 'funwithfoundry-rag-agent'
$question = 'What is the maintenance window code, and why is the agent subnet 172.16.0.0/24?'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

$token = Get-ImdsToken -Resource 'https://ai.azure.com'
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$url = "$ProjectEndpoint/agents/$agentName/endpoint/protocols/openai/responses?api-version=v1"
$body = @{ input = $question; model = $AgentToolModel } | ConvertTo-Json
$response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -TimeoutSec 900

Write-Output "=== Native agent response: $($response.status) ==="
$toolCalls = @($response.output | Where-Object type -eq 'function_call')
$toolCalls | ForEach-Object { Write-Output "  tool: $($_.name) $($_.arguments)" }

$answer = ($response.output | Where-Object type -eq 'message' | ForEach-Object content | Where-Object text | ForEach-Object text) -join "`n"
Write-Output ""
Write-Output $answer

$toolNames = @($toolCalls.name)
if ($response.status -ne 'completed') { throw "Native agent status was $($response.status)." }
if ($toolNames -notcontains 'retrieve_foundry_iq') { throw 'Foundry IQ tool was not called.' }
if ($toolNames -notcontains $SearchName) { throw "Toolbox Search tool '$SearchName' was not called." }
if ($answer -notmatch 'BLUE-HERON-42' -or $answer -notmatch '172\.16\.0\.0/24' -or $answer -notmatch 'Sources') {
    throw 'Native agent answer did not meet the grounded validation contract.'
}
Write-Output ""
Write-Output 'PASS: native agent used Foundry IQ and Toolbox Search.'
