<#
.SYNOPSIS
    Verify the funwithfoundry lab is actually private and correctly wired.
.DESCRIPTION
    Read-only. Checks public network access, private endpoint health, subnet delegation,
    and capability host state. Control-plane checks only - DNS resolution and data-plane
    reachability must be tested from the jumpbox.
#>
[CmdletBinding()]
param(
    [string]$NetworkResourceGroup   = 'rg-fwf-net',
    [string]$PrimaryResourceGroup   = 'rg-fwf-cus',
    [string]$SecondaryResourceGroup = 'rg-fwf-scus'
)

$ErrorActionPreference = 'Continue'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param($Check, $Status, $Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ("[{0,-4}] {1,-52} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}

function Get-Json {
    param([string[]]$CliArgs)
    $raw = & az @CliArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

Write-Host "`n=== funwithfoundry :: deployment verification ===" -ForegroundColor Cyan

# --- Public network access must be disabled everywhere ------------------------
$targets = @(
    @{ rg = $PrimaryResourceGroup;   type = 'Microsoft.CognitiveServices/accounts'; label = 'Foundry (primary)' }
    @{ rg = $SecondaryResourceGroup; type = 'Microsoft.CognitiveServices/accounts'; label = 'Foundry (secondary)' }
    @{ rg = $PrimaryResourceGroup;   type = 'Microsoft.Search/searchServices';      label = 'AI Search' }
    @{ rg = $PrimaryResourceGroup;   type = 'Microsoft.Storage/storageAccounts';    label = 'Storage (primary)' }
    @{ rg = $SecondaryResourceGroup; type = 'Microsoft.Storage/storageAccounts';    label = 'Storage (staging)' }
    @{ rg = $PrimaryResourceGroup;   type = 'Microsoft.DocumentDB/databaseAccounts';label = 'Cosmos DB' }
    @{ rg = $PrimaryResourceGroup;   type = 'Microsoft.KeyVault/vaults';            label = 'Key Vault' }
)

foreach ($t in $targets) {
    $items = Get-Json @('resource', 'list', '-g', $t.rg, '--resource-type', $t.type, '-o', 'json')
    if (-not $items) { Add-Check $t.label 'WARN' 'not found'; continue }
    foreach ($item in @($items)) {
        $detail = Get-Json @('resource', 'show', '--ids', $item.id, '-o', 'json')
        $pna = $detail.properties.publicNetworkAccess
        $isPrivate = "$pna" -in @('Disabled', 'SecuredByPerimeter')
        $isSearch = $t.type -eq 'Microsoft.Search/searchServices'
        $localAuthDisabled = $detail.properties.disableLocalAuth
        $status = if ($isPrivate -and (-not $isSearch -or $localAuthDisabled)) { 'PASS' } else { 'FAIL' }
        $authDetail = if ($isSearch) { " disableLocalAuth=$localAuthDisabled" } else { '' }
        Add-Check "$($t.label): $($item.name)" $status "publicNetworkAccess=$pna$authDetail"
    }
}

# --- Private endpoints must all be Approved ----------------------------------
foreach ($rg in @($PrimaryResourceGroup, $SecondaryResourceGroup)) {
    $peList = Get-Json @('network', 'private-endpoint', 'list', '-g', $rg, '-o', 'json')
    if (-not $peList) { Add-Check "Private endpoints ($rg)" 'WARN' 'none found'; continue }
    foreach ($pe in @($peList)) {
        $conn = $pe.privateLinkServiceConnections[0]
        $state = $conn.privateLinkServiceConnectionState.status
        $status = if ($state -eq 'Approved') { 'PASS' } else { 'FAIL' }
        $ip = ($pe.customDnsConfigs | Select-Object -First 1).ipAddresses -join ','
        Add-Check "PE $($pe.name)" $status "$state ip=$ip"
    }
}

# --- Agent subnet must stay delegated and free of a route table --------------
$agent = Get-Json @('network', 'vnet', 'subnet', 'show', '-g', $PrimaryResourceGroup,
    '--vnet-name', 'vnet-fwf-cus', '-n', 'snet-agent', '-o', 'json')
if ($agent) {
    $deleg = $agent.delegations[0].serviceName
    $status = if ($deleg -eq 'Microsoft.App/environments') { 'PASS' } else { 'FAIL' }
    Add-Check 'Agent subnet delegation' $status "$deleg prefix=$($agent.addressPrefix)"
}

# --- Capability hosts ---------------------------------------------------------
$accounts = Get-Json @('resource', 'list', '-g', $PrimaryResourceGroup,
    '--resource-type', 'Microsoft.CognitiveServices/accounts', '-o', 'json')
foreach ($acct in @($accounts)) {
    $acctHosts = Get-Json @('rest', '--method', 'get', '--url',
        "https://management.azure.com$($acct.id)/capabilityHosts?api-version=2025-04-01-preview", '-o', 'json')
    foreach ($h in @($acctHosts.value)) {
        $kind = $h.properties.capabilityHostKind
        $state = $h.properties.provisioningState
        $status = if ($kind -eq 'Agents' -and $state -eq 'Succeeded') { 'PASS' } else { 'FAIL' }
        Add-Check "Account capability host" $status "$($h.name) kind=$kind state=$state"
    }

    $projects = Get-Json @('rest', '--method', 'get', '--url',
        "https://management.azure.com$($acct.id)/projects?api-version=2025-06-01", '-o', 'json')
    foreach ($proj in @($projects.value)) {
        $projHosts = Get-Json @('rest', '--method', 'get', '--url',
            "https://management.azure.com$($proj.id)/capabilityHosts?api-version=2025-04-01-preview", '-o', 'json')
        foreach ($h in @($projHosts.value)) {
            $properties = $h.properties
            $connectionsReady = $properties.vectorStoreConnections -and
                $properties.storageConnections -and $properties.threadStorageConnections
            $status = if ($properties.capabilityHostKind -eq 'Agents' -and
                $properties.provisioningState -eq 'Succeeded' -and $connectionsReady) { 'PASS' } else { 'FAIL' }
            $connections = "search=$($properties.vectorStoreConnections -join ',') storage=$($properties.storageConnections -join ',') thread=$($properties.threadStorageConnections -join ',')"
            Add-Check "Project capability host" $status "$($h.name) kind=$($properties.capabilityHostKind) state=$($properties.provisioningState) $connections"
        }
    }
}

# --- Routing intent -----------------------------------------------------------
# routingIntent is a child resource and is not enumerable via 'az resource list';
# it has to be read off the hub directly.
$hubs = Get-Json @('resource', 'list', '-g', $NetworkResourceGroup,
    '--resource-type', 'Microsoft.Network/virtualHubs', '-o', 'json')
foreach ($hub in @($hubs)) {
    $intent = Get-Json @('rest', '--method', 'get', '--url',
        "https://management.azure.com$($hub.id)/routingIntent?api-version=2024-05-01", '-o', 'json')
    $policy = @($intent.value)[0].properties.routingPolicies
    $status = if ($policy) { 'PASS' } else { 'FAIL' }
    Add-Check "Routing intent ($($hub.name))" $status (($policy | ForEach-Object { $_.name }) -join ', ')
}

Write-Host "`n=== Verdict ===" -ForegroundColor Cyan
$fails = $results | Where-Object Status -eq 'FAIL'
$warns = $results | Where-Object Status -eq 'WARN'
Write-Host ("FAIL: {0}   WARN: {1}   PASS: {2}" -f $fails.Count, $warns.Count, ($results | Where-Object Status -eq 'PASS').Count)
if ($fails) {
    Write-Host "`nBlocking:" -ForegroundColor Red
    $fails | ForEach-Object { Write-Host "  - $($_.Check): $($_.Detail)" -ForegroundColor Red }
}

Write-Host @'

Not covered here - these require the jumpbox:
  * nslookup of each private endpoint FQDN returning a private IP
  * Bastion RDP actually working under vWAN routing intent
  * cross-region reachability from the SCUS function subnet to CUS AI Search
  * Content Understanding availability in South Central US (only proven by running an analyzer)
'@ -ForegroundColor DarkGray
