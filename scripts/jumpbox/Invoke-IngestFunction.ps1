# Runs ON the jumpbox. The function app is private, so it is only reachable from inside
# the VNet. The route is anonymous because public network access is disabled and the
# private endpoint is the auth boundary.
$ErrorActionPreference = 'Continue'

Write-Output "=== Invoke /api/ingest ==="
$body = @{
    siteHostname = $SpHostname
    sitePath     = $SpSitePath
    filePath     = $SpFilePath
} | ConvertTo-Json -Compress

try {
    $r = Invoke-WebRequest -Uri "https://$FunctionHost/api/ingest" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 600 -UseBasicParsing
    Write-Output "  http $($r.StatusCode)"
    Write-Output $r.Content
}
catch {
    $resp = $_.Exception.Response
    $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
    Write-Output "  FAILED http $code : $($_.Exception.Message)"
    if ($resp) { try { Write-Output ([System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()) } catch {} }
}
