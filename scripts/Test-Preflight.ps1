<#
.SYNOPSIS
    Phase 0 capacity gate for the funwithfoundry private Foundry lab.
.DESCRIPTION
    Read-only. Verifies region/SKU/model/quota prerequisites in both target regions
    before any Terraform runs. Emits PASS/WARN/FAIL per check and a final verdict.
#>
[CmdletBinding()]
param(
    [string]$PrimaryRegion   = 'centralus',
    [string]$SecondaryRegion = 'southcentralus',
    [string]$JumpboxSize     = 'Standard_D4s_v5'
)

$ErrorActionPreference = 'Continue'
$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param($Check, $Status, $Detail)
    $script:Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ("[{0,-4}] {1,-42} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}

function Invoke-Az {
    param([string[]]$CliArgs)
    $raw = & az @CliArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

Write-Host "`n=== funwithfoundry :: Phase 0 preflight ===" -ForegroundColor Cyan

# --- Subscription context -----------------------------------------------------
$acct = Invoke-Az @('account','show','-o','json')
if (-not $acct) { Add-Result 'Azure login' 'FAIL' 'az account show failed - run az login'; return }
Add-Result 'Subscription' 'INFO' "$($acct.name) ($($acct.id))"

# --- Resource providers -------------------------------------------------------
$providers = @(
    'Microsoft.App','Microsoft.CognitiveServices','Microsoft.Search','Microsoft.Storage',
    'Microsoft.MachineLearningServices','Microsoft.KeyVault','Microsoft.Network',
    'Microsoft.ContainerService','Microsoft.DocumentDB','Microsoft.Web'
)
foreach ($p in $providers) {
    $state = (Invoke-Az @('provider','show','-n',$p,'--query','registrationState','-o','json'))
    $status = if ($state -eq 'Registered') { 'PASS' } else { 'WARN' }
    Add-Result "Provider $p" $status "$state"
}

# --- AIServices SKU availability ---------------------------------------------
foreach ($r in @($PrimaryRegion, $SecondaryRegion)) {
    $skus = Invoke-Az @('cognitiveservices','account','list-skus','--location',$r,'--kind','AIServices','-o','json')
    if ($skus) { Add-Result "AIServices SKU ($r)" 'PASS' (($skus.name | Select-Object -Unique) -join ', ') }
    else       { Add-Result "AIServices SKU ($r)" 'FAIL' 'no AIServices SKUs offered' }
}

# --- Model availability -------------------------------------------------------
$wanted = @('gpt-5.2','gpt-4.1','gpt-4o','text-embedding-3-large')
foreach ($r in @($PrimaryRegion, $SecondaryRegion)) {
    $models = Invoke-Az @('cognitiveservices','model','list','-l',$r,'-o','json')
    if (-not $models) { Add-Result "Models ($r)" 'FAIL' 'model list returned nothing'; continue }
    $names = $models.model.name | Select-Object -Unique
    foreach ($w in $wanted) {
        $hit = $names | Where-Object { $_ -eq $w }
        $status = if ($hit) { 'PASS' } else { 'WARN' }
        Add-Result "Model $w ($r)" $status ($(if ($hit) { 'available' } else { 'NOT offered in region' }))
    }
}

# --- Model quota / TPM --------------------------------------------------------
foreach ($r in @($PrimaryRegion, $SecondaryRegion)) {
    $usage = Invoke-Az @('cognitiveservices','usage','list','-l',$r,'-o','json')
    if (-not $usage) { Add-Result "OpenAI quota ($r)" 'WARN' 'usage list unavailable'; continue }
    $interesting = $usage | Where-Object {
        $_.name.value -match 'gpt-5\.2|gpt-4\.1|text-embedding-3-large'
    } | Sort-Object { $_.name.value }
    if (-not $interesting) { Add-Result "OpenAI quota ($r)" 'WARN' 'no matching quota entries'; continue }
    foreach ($u in $interesting) {
        $avail = [int]$u.limit - [int]$u.currentValue
        $status = if ($avail -ge 30) { 'PASS' } elseif ($avail -gt 0) { 'WARN' } else { 'FAIL' }
        Add-Result "Quota $($u.name.value) ($r)" $status "limit=$($u.limit) used=$($u.currentValue) avail=$avail"
    }
}

# --- Flex Consumption ---------------------------------------------------------
$flex = Invoke-Az @('functionapp','list-flexconsumption-locations','-o','json')
if ($flex) {
    $flexNames = $flex.name | ForEach-Object { $_ -replace '\s','' } | ForEach-Object { $_.ToLower() }
    foreach ($r in @($PrimaryRegion, $SecondaryRegion)) {
        $status = if ($flexNames -contains $r) { 'PASS' } else { 'FAIL' }
        Add-Result "Flex Consumption ($r)" $status ($(if ($status -eq 'PASS') { 'supported' } else { 'NOT supported' }))
    }
} else { Add-Result 'Flex Consumption' 'WARN' 'could not enumerate locations' }

# --- Compute quota for jumpbox -----------------------------------------------
$vmUsage = Invoke-Az @('vm','list-usage','-l',$PrimaryRegion,'-o','json')
if ($vmUsage) {
    foreach ($n in @('cores','standardDSv5Family')) {
        $u = $vmUsage | Where-Object { $_.name.value -eq $n }
        if ($u) {
            $avail = [int]$u.limit - [int]$u.currentValue
            $status = if ($avail -ge 4) { 'PASS' } else { 'FAIL' }
            Add-Result "vCPU $n ($PrimaryRegion)" $status "limit=$($u.limit) used=$($u.currentValue) avail=$avail"
        }
    }
} else { Add-Result "VM usage ($PrimaryRegion)" 'WARN' 'unavailable' }

$sku = Invoke-Az @('vm','list-skus','-l',$PrimaryRegion,'--size',$JumpboxSize,'--all','-o','json')
if ($sku) {
    $exact = $sku | Where-Object { $_.name -eq $JumpboxSize }
    if ($exact) {
        $restr = $exact.restrictions
        $status = if (-not $restr -or $restr.Count -eq 0) { 'PASS' } else { 'WARN' }
        Add-Result "$JumpboxSize ($PrimaryRegion)" $status ($(if ($status -eq 'PASS') { 'no restrictions' } else { "restricted: $($restr.reasonCode -join ',')" }))
    } else { Add-Result "$JumpboxSize ($PrimaryRegion)" 'FAIL' 'size not offered' }
}

# --- Network quota (public IPs) ----------------------------------------------
foreach ($r in @($PrimaryRegion, $SecondaryRegion)) {
    $net = Invoke-Az @('network','list-usages','-l',$r,'-o','json')
    if (-not $net) { Add-Result "Network quota ($r)" 'WARN' 'unavailable'; continue }
    $pip = $net | Where-Object { $_.name.value -eq 'IPv4StandardSkuPublicIpAddresses' }
    if ($pip) {
        $avail = [int]$pip.limit - [int]$pip.currentValue
        $status = if ($avail -ge 3) { 'PASS' } elseif ($avail -gt 0) { 'WARN' } else { 'FAIL' }
        Add-Result "Standard public IPs ($r)" $status "limit=$($pip.limit) used=$($pip.currentValue) avail=$avail"
    } else {
        Add-Result "Standard public IPs ($r)" 'WARN' 'quota entry IPv4StandardSkuPublicIpAddresses not found'
    }
}

# --- Existing footprint vs per-sub caps --------------------------------------
$counts = @{
    'AI Search services' = 'Microsoft.Search/searchServices'
    'Cosmos accounts'    = 'Microsoft.DocumentDB/databaseAccounts'
    'Virtual WANs'       = 'Microsoft.Network/virtualWans'
    'Azure Firewalls'    = 'Microsoft.Network/azureFirewalls'
}
foreach ($k in $counts.Keys) {
    $res = Invoke-Az @('resource','list','--resource-type',$counts[$k],'-o','json')
    $n = if ($res) { @($res).Count } else { 0 }
    Add-Result "Existing $k" 'INFO' "$n"
}

# --- Verdict ------------------------------------------------------------------
Write-Host "`n=== Verdict ===" -ForegroundColor Cyan
$fails = $script:Results | Where-Object Status -eq 'FAIL'
$warns = $script:Results | Where-Object Status -eq 'WARN'
Write-Host ("FAIL: {0}   WARN: {1}   PASS: {2}" -f $fails.Count, $warns.Count, ($script:Results | Where-Object Status -eq 'PASS').Count)
if ($fails) {
    Write-Host "`nBlocking:" -ForegroundColor Red
    $fails | ForEach-Object { Write-Host "  - $($_.Check): $($_.Detail)" -ForegroundColor Red }
}
if ($warns) {
    Write-Host "`nNeeds attention:" -ForegroundColor Yellow
    $warns | ForEach-Object { Write-Host "  - $($_.Check): $($_.Detail)" -ForegroundColor Yellow }
}
$script:Results | Export-Csv -NoTypeInformation -Path (Join-Path $PSScriptRoot 'preflight-results.csv')
Write-Host "`nSaved: $(Join-Path $PSScriptRoot 'preflight-results.csv')"
