# Runs ON the jumpbox. Proves Content Understanding is genuinely available in the
# secondary region by calling it - availability of an AIServices SKU does not prove this.
# Uses analyzeBinary because CU cannot fetch a private blob by URL.

$ErrorActionPreference = 'Stop'
$cu = "https://$FqdnCu"
$apiVersion = '2025-11-01'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

Write-Output "=== Acquiring managed identity token ==="
$token = Get-ImdsToken -Resource 'https://cognitiveservices.azure.com/'
Write-Output "token acquired: $($token.Length) chars"

Write-Output ""
Write-Output "=== Listing Content Understanding analyzers (proves the API exists in-region) ==="
try {
    $list = Invoke-RestMethod -Uri "$cu/contentunderstanding/analyzers?api-version=$apiVersion" `
        -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 60
    $names = ($list.value | ForEach-Object { $_.analyzerId }) -join ', '
    Write-Output "OK - analyzers reachable. Prebuilt available: $names"
}
catch {
    Write-Output "FAILED to list analyzers: $($_.Exception.Message)"
    $r = $_.Exception.Response
    if ($r) {
        $body = [System.IO.StreamReader]::new($r.GetResponseStream()).ReadToEnd()
        Write-Output "body: $body"
    }
    exit 1
}

Write-Output ""
Write-Output "=== analyzeBinary round trip ==="
$sample = @"
FUNWITHFOUNDRY LAB DOCUMENT

Project: Private Foundry lab spanning Central US and South Central US.
Network: Virtual WAN Standard with Azure Firewall in both hubs.
Agent subnet: 172.16.0.0/24 delegated to Microsoft.App/environments.
Secret phrase for retrieval testing: the pelican files at midnight.
"@
$bytes = [System.Text.Encoding]::UTF8.GetBytes($sample)

$analyzer = 'prebuilt-document'
$url = "$cu/contentunderstanding/analyzers/$analyzer`:analyzeBinary?api-version=$apiVersion"

try {
    $resp = Invoke-WebRequest -Uri $url -Method Post -Body $bytes `
        -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/octet-stream' } `
        -TimeoutSec 120 -UseBasicParsing
    Write-Output "submitted: http $($resp.StatusCode)"
    $opUrl = $resp.Headers['Operation-Location']
    if ($opUrl -is [array]) { $opUrl = $opUrl[0] }
}
catch {
    Write-Output "FAILED to submit: $($_.Exception.Message)"
    $r = $_.Exception.Response
    if ($r) {
        $body = [System.IO.StreamReader]::new($r.GetResponseStream()).ReadToEnd()
        Write-Output "body: $body"
    }
    exit 1
}

if (-not $opUrl) { Write-Output 'No Operation-Location header returned.'; exit 1 }

for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 3
    $poll = Invoke-RestMethod -Uri $opUrl -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 60
    if ($poll.status -eq 'Succeeded') {
        $md = ($poll.result.contents | ForEach-Object { $_.markdown }) -join "`n"
        Write-Output "STATUS: Succeeded"
        Write-Output "markdown chars: $($md.Length)"
        Write-Output "--- extracted ---"
        Write-Output $md
        exit 0
    }
    if ($poll.status -eq 'Failed') {
        Write-Output "STATUS: Failed"
        Write-Output ($poll | ConvertTo-Json -Depth 6)
        exit 1
    }
}
Write-Output 'Timed out waiting for analysis.'
exit 1
