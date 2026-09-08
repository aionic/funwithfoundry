# Discriminator: does ANY cross-region data-plane call work through the secured hubs,
# or is this specific to Cognitive Services? Prints the actual remote IP used.

$ErrorActionPreference = 'Continue'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

function Show-Route {
    param([string]$FQDN)
    $ips = try {
        [System.Net.Dns]::GetHostAddresses($FQDN) | Where-Object AddressFamily -eq 'InterNetwork' |
            ForEach-Object { $_.IPAddressToString }
    } catch { @('resolve-failed') }
    $tnc = Test-NetConnection -ComputerName $FQDN -Port 443 -WarningAction SilentlyContinue
    Write-Output ("    dns={0}  tcp_remote={1}  tcp_ok={2}" -f ($ips -join ','), $tnc.RemoteAddress, $tnc.TcpTestSucceeded)
}

function Probe {
    param([string]$Label, [string]$Url, [string]$Token)
    $fqdn = ([System.Uri]$Url).Host
    Write-Output "--- $Label"
    Show-Route -FQDN $fqdn
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 60 -UseBasicParsing
        Write-Output "    http $($r.StatusCode)  OK"
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            $body = ''
            try { $body = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() } catch {}
            if ($body.Length -gt 200) { $body = $body.Substring(0, 200) }
            Write-Output "    http $code  $body"
        }
        else { Write-Output "    transport error: $($_.Exception.Message)" }
    }
    Write-Output ""
}

$storageToken = Get-ImdsToken -Resource 'https://storage.azure.com/'
$cogToken = Get-ImdsToken -Resource 'https://cognitiveservices.azure.com/'

Write-Output "=== SAME-REGION baseline (never traverses the firewall) ==="
Probe -Label 'CUS storage list containers' `
    -Url "https://$FqdnStorage/?comp=list" -Token $storageToken

Write-Output "=== CROSS-REGION through both hub firewalls ==="
Probe -Label 'SCUS staging storage list containers' `
    -Url "https://$FqdnStaging/?comp=list" -Token $storageToken

Probe -Label 'SCUS Content Understanding analyzers' `
    -Url "https://$FqdnCu/contentunderstanding/analyzers?api-version=2025-11-01" -Token $cogToken


