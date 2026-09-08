# Runs ON the jumpbox. The SCM endpoint is private, so deployment status can only be
# read from inside the VNet.
$ErrorActionPreference = 'Continue'

$uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"
$token = (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
$headers = @{ Authorization = "Bearer $token" }

function Show-Scm {
    param([string]$Label, [string]$Path)
    Write-Output "=== $Label"
    try {
        $r = Invoke-WebRequest -Uri "https://$FunctionApp.scm.azurewebsites.net$Path" `
            -Headers $headers -TimeoutSec 120 -UseBasicParsing
        $text = $r.Content
        if ($text.Length -gt 3000) { $text = $text.Substring(0, 3000) }
        Write-Output $text
    }
    catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        Write-Output "  http $code : $($_.Exception.Message)"
        if ($resp) {
            try { Write-Output ([System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()) } catch {}
        }
    }
    Write-Output ""
}

$latest = $null
try {
    $response = Invoke-WebRequest -Uri "https://$FunctionApp.scm.azurewebsites.net/api/deployments/latest" `
        -Headers $headers -TimeoutSec 120 -UseBasicParsing
    $latest = $response.Content | ConvertFrom-Json
    Write-Output '=== latest deployment'
    Write-Output $response.Content
    Write-Output ''
}
catch {
    Write-Output "Could not read latest deployment: $($_.Exception.Message)"
}

if ($latest.id) {
    Show-Scm -Label 'deployment log' -Path "/api/deployments/$($latest.id)/log"
}
