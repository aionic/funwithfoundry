# Diagnostic: is the 403 an RBAC denial, a network ACL denial, or a bad route?
# Compares a known-good data-plane call against the Content Understanding call.

$ErrorActionPreference = 'Continue'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

function Probe {
    param([string]$Label, [string]$Url, [string]$Token)
    Write-Output "--- $Label"
    Write-Output "    $Url"
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers @{ Authorization = "Bearer $Token" } `
            -TimeoutSec 60 -UseBasicParsing
        Write-Output "    http $($r.StatusCode)  len=$($r.Content.Length)"
        $c = $r.Content
        if ($c.Length -gt 300) { $c = $c.Substring(0, 300) }
        Write-Output "    $c"
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            $body = ''
            try {
                $s = $resp.GetResponseStream()
                $s.Position = 0
                $body = [System.IO.StreamReader]::new($s).ReadToEnd()
            }
            catch { $body = "(could not read body: $($_.Exception.Message))" }

            $hdrs = @()
            foreach ($h in $resp.Headers.AllKeys) {
                if ($h -match 'x-ms|WWW-Authenticate|error') { $hdrs += "$h=$($resp.Headers[$h])" }
            }
            Write-Output "    http $code"
            if ($hdrs) { Write-Output "    headers: $($hdrs -join '; ')" }
            Write-Output "    body: $body"
        }
        else {
            Write-Output "    transport error: $($_.Exception.Message)"
        }
    }
    Write-Output ""
}

$cogToken = Get-ImdsToken -Resource 'https://cognitiveservices.azure.com/'
Write-Output "cognitiveservices token len=$($cogToken.Length)"
Write-Output ""

# Known-good comparison: same role, same token audience, primary region account.
Probe -Label 'CUS Foundry - openai models (control)' `
    -Url "https://$FqdnFoundryOAI/openai/models?api-version=2024-10-21" -Token $cogToken

Probe -Label 'SCUS CU - openai models (is the account reachable at all?)' `
    -Url "https://$FqdnCuOpenAI/openai/models?api-version=2024-10-21" -Token $cogToken

Probe -Label 'SCUS CU - contentunderstanding analyzers 2025-11-01' `
    -Url "https://$FqdnCu/contentunderstanding/analyzers?api-version=2025-11-01" -Token $cogToken

Probe -Label 'SCUS CU - contentunderstanding analyzers 2026-06-01-preview' `
    -Url "https://$FqdnCu/contentunderstanding/analyzers?api-version=2026-06-01-preview" -Token $cogToken



