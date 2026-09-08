# Runs ON the jumpbox via 'az vm run-command'. Proves private DNS resolution and
# cross-region reachability from inside the VNet, including the hub-to-hub hop.
# Resource names are injected by scripts/Invoke-JumpboxScript.ps1.

$names = @(
    $FqdnFoundrySvc,
    $FqdnFoundryCog,
    $FqdnFoundryOAI,
    $FqdnSearch,
    $FqdnStorage,
    $FqdnCosmos,
    $FqdnKeyVault,
    $FqdnCu,
    $FqdnStaging
)

Write-Output "=== DNS resolution from inside the VNet ==="
foreach ($n in $names) {
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($n) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString }
        $ip = $ips -join ','
        # 10.10.x = CUS spoke PE subnet, 10.20.x = SCUS spoke PE subnet.
        $private = $ips | Where-Object { $_ -like '10.10.*' -or $_ -like '10.20.*' }
        $verdict = if ($private) { 'PRIVATE' } else { 'PUBLIC <-- leak' }
        Write-Output ("{0,-46} {1,-16} {2}" -f $n, $ip, $verdict)
    }
    catch {
        Write-Output ("{0,-46} {1}" -f $n, "RESOLVE FAILED")
    }
}

Write-Output ""
Write-Output "=== TCP 443 reachability ==="
$targets = @(
    @{ host = $FqdnSearch;      label = 'AI Search (same region)' },
    @{ host = $FqdnFoundrySvc;  label = 'Foundry (same region)' },
    @{ host = $FqdnCu;          label = 'Content Understanding (CROSS-REGION via vWAN)' },
    @{ host = $FqdnStaging;     label = 'Staging blob (CROSS-REGION via vWAN)' }
)
foreach ($t in $targets) {
    $r = Test-NetConnection -ComputerName $t.host -Port 443 -WarningAction SilentlyContinue
    $verdict = if ($r.TcpTestSucceeded) { 'OK' } else { 'FAILED' }
    Write-Output ("{0,-48} {1,-16} {2}" -f $t.label, $r.RemoteAddress, $verdict)
}
