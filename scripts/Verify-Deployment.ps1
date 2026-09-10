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
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [string]$NetworkResourceGroup,
    [string]$PrimaryResourceGroup,
    [string]$SecondaryResourceGroup
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param($Check, $Status, $Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ("[{0,-4}] {1,-52} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}

function Get-Json {
    param([string[]]$CliArgs)
    $raw = & az @CliArgs --subscription $lab.SubscriptionId
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Azure query failed or returned no JSON.' }
    ConvertFrom-Json -InputObject ($raw -join "`n") -NoEnumerate
}

Write-Host "`n=== funwithfoundry :: deployment verification ===" -ForegroundColor Cyan
$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir
if ($LASTEXITCODE -ne 0 -or -not $lab.SubscriptionId) { throw 'Lab environment lookup failed.' }
foreach ($pair in @(
    @($NetworkResourceGroup, $lab.ResourceGroups.Network),
    @($PrimaryResourceGroup, $lab.ResourceGroups.Primary),
    @($SecondaryResourceGroup, $lab.ResourceGroups.Secondary)
)) {
    if (-not $pair[1] -or ($pair[0] -and $pair[0] -ne $pair[1])) { throw 'Resource group override does not match the Terraform-resolved environment.' }
}
$NetworkResourceGroup = $lab.ResourceGroups.Network
$PrimaryResourceGroup = $lab.ResourceGroups.Primary
$SecondaryResourceGroup = $lab.ResourceGroups.Secondary
Push-Location $TerraformDir
try {
    $raw = terraform output -json
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Terraform verification outputs are unavailable.' }
    $outputs = $raw | ConvertFrom-Json
}
finally { Pop-Location }
if ($outputs.foundry_primary_account_id.value -ne $lab.FoundryId) { throw 'Terraform account identity does not match the active subscription/environment.' }

# --- Public network access must be disabled everywhere ------------------------
$targets = @(
    @{ rg = $PrimaryResourceGroup; type = 'Microsoft.CognitiveServices/accounts'; label = 'Foundry (primary)'; name = $lab.Primary.Account; groups = @('account') }
    @{ rg = $SecondaryResourceGroup; type = 'Microsoft.CognitiveServices/accounts'; label = 'Foundry (secondary)'; name = $lab.Secondary.Account; groups = @('account') }
    @{ rg = $PrimaryResourceGroup; type = 'Microsoft.Search/searchServices'; label = 'AI Search'; name = $lab.Primary.Search; groups = @('searchService') }
    @{ rg = $PrimaryResourceGroup; type = 'Microsoft.Storage/storageAccounts'; label = 'Storage (primary)'; name = $lab.Primary.Storage; groups = @('blob') }
    @{ rg = $SecondaryResourceGroup; type = 'Microsoft.Storage/storageAccounts'; label = 'Storage (staging)'; name = $lab.Secondary.StagingStorage; groups = @('blob') }
    @{ rg = $PrimaryResourceGroup; type = 'Microsoft.DocumentDB/databaseAccounts'; label = 'Cosmos DB'; name = $lab.Primary.Cosmos; groups = @('Sql') }
    @{ rg = $PrimaryResourceGroup; type = 'Microsoft.KeyVault/vaults'; label = 'Key Vault'; name = $lab.Primary.KeyVault; groups = @('vault') }
    @{ rg = $SecondaryResourceGroup; type = 'Microsoft.Web/sites'; label = 'Ingestion Function'; name = $lab.Function.Name; groups = @('sites') }
    @{ rg = $SecondaryResourceGroup; type = 'Microsoft.Storage/storageAccounts'; label = 'Function host storage'; name = $outputs.ingest_function.value.storage; groups = @('blob', 'queue', 'table') }
)

foreach ($target in $targets) {
    $target.id = "/subscriptions/$($lab.SubscriptionId)/resourceGroups/$($target.rg)/providers/$($target.type)/$($target.name)"
    try {
        if (-not $target.name) { throw 'Expected resource name is missing from Terraform outputs.' }
        $detail = Get-Json @('resource', 'show', '--ids', $target.id, '-o', 'json')
        if ($detail.id -ne $target.id) { throw 'Expected resource missing or returned identity mismatched.' }
        $pna = $detail.properties.publicNetworkAccess
        $isPrivate = $pna -eq 'Disabled'
        $isSearch = $target.type -eq 'Microsoft.Search/searchServices'
        $localAuthDisabled = $detail.properties.disableLocalAuth
        $status = if ($isPrivate -and (-not $isSearch -or ($localAuthDisabled -is [bool] -and $localAuthDisabled))) { 'PASS' } else { 'FAIL' }
        $authDetail = if ($isSearch) { " disableLocalAuth=$localAuthDisabled" } else { '' }
        Add-Check "$($target.label): $($target.name)" $status "publicNetworkAccess=$pna$authDetail"
    }
    catch { Add-Check $target.label 'FAIL' $_.Exception.Message }
}

# --- Private endpoints must all be Approved ----------------------------------
$approved = @{}
foreach ($rg in @($PrimaryResourceGroup, $SecondaryResourceGroup)) {
    try {
        $peList = Get-Json @('network', 'private-endpoint', 'list', '-g', $rg, '-o', 'json')
        if ($peList -isnot [array] -or -not $peList.Count) { throw 'Expected private endpoints are missing.' }
        foreach ($endpoint in $peList) {
            $connections = @(@($endpoint.privateLinkServiceConnections) + @($endpoint.manualPrivateLinkServiceConnections) | Where-Object { $_ })
            if (-not $connections.Count -or $endpoint.provisioningState -ne 'Succeeded') { throw "Private endpoint $($endpoint.name) is incomplete." }
            foreach ($connection in $connections) {
                $state = $connection.privateLinkServiceConnectionState.status
                $status = if ($state -eq 'Approved' -and $connection.privateLinkServiceId -and $connection.groupIds) { 'PASS' } else { 'FAIL' }
                Add-Check "PE $($endpoint.name)" $status $state
                if ($status -eq 'PASS') {
                    foreach ($groupId in $connection.groupIds) { $approved["$($connection.privateLinkServiceId)/$groupId"] = $true }
                }
            }
        }
    }
    catch { Add-Check "Private endpoints ($rg)" 'FAIL' $_.Exception.Message }
}
foreach ($target in $targets) {
    foreach ($groupId in $target.groups) {
        $status = if ($approved["$($target.id)/$groupId"]) { 'PASS' } else { 'FAIL' }
        Add-Check "Expected PE: $($target.label)/$groupId" $status 'Approved connection to the expected resource required'
    }
}

# --- Agent subnet must stay delegated and free of a route table --------------
try {
    $subnetId = $outputs.foundry_agent_subnet_id.value
    if (-not $subnetId -or -not $subnetId.StartsWith("/subscriptions/$($lab.SubscriptionId)/resourceGroups/$PrimaryResourceGroup/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Expected agent subnet ID is missing or out of scope.' }
    $agent = Get-Json @('network', 'vnet', 'subnet', 'show', '--ids', $subnetId, '-o', 'json')
    if ($agent.id -ne $subnetId) { throw 'Expected agent subnet not found.' }
    $delegations = @($agent.delegations)
    $status = if ($delegations.Count -eq 1 -and $delegations[0].serviceName -eq 'Microsoft.App/environments' -and -not $agent.routeTable.id) { 'PASS' } else { 'FAIL' }
    Add-Check 'Agent subnet delegation and routing' $status 'Microsoft.App/environments delegation and no subnet route table required'
}
catch { Add-Check 'Agent subnet delegation and routing' 'FAIL' $_.Exception.Message }

# --- Capability hosts ---------------------------------------------------------
foreach ($kind in @('Account', 'Project')) {
    try {
        $parentId = $lab.FoundryId
        if ($kind -eq 'Project') {
            if (-not $lab.Primary.Project) { throw 'Expected project name is missing.' }
            $parentId += "/projects/$($lab.Primary.Project)"
            $project = Get-Json @('rest', '--method', 'get', '--url', "https://management.azure.com${parentId}?api-version=2025-06-01", '-o', 'json')
            if ($project.id -ne $parentId) { throw 'Expected project is missing.' }
        }
        $hosts = Get-Json @('rest', '--method', 'get', '--url', "https://management.azure.com$parentId/capabilityHosts?api-version=2025-04-01-preview", '-o', 'json')
        if (-not $hosts.value) { throw 'Expected capability host is missing.' }
        foreach ($hostItem in $hosts.value) {
            $properties = $hostItem.properties
            $ready = $properties.capabilityHostKind -eq 'Agents' -and $properties.provisioningState -eq 'Succeeded'
            if ($kind -eq 'Project') {
                $ready = $ready -and $properties.vectorStoreConnections -contains $lab.Primary.Search -and
                    $properties.storageConnections -contains $lab.Primary.Storage -and $properties.threadStorageConnections -contains $lab.Primary.Cosmos
            }
            $status = if ($ready) { 'PASS' } else { 'FAIL' }
            Add-Check "$kind capability host" $status "$($hostItem.name) state=$($properties.provisioningState)"
        }
    }
    catch { Add-Check "$kind capability host" 'FAIL' $_.Exception.Message }
}

# --- Routing intent -----------------------------------------------------------
# routingIntent is a child resource and is not enumerable via 'az resource list';
# it has to be read off the hub directly.
foreach ($region in @('primary', 'secondary')) {
    try {
        $hubId = $outputs.hub_ids.value.$region
        if (-not $hubId -or -not $hubId.StartsWith("/subscriptions/$($lab.SubscriptionId)/resourceGroups/$NetworkResourceGroup/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Expected hub ID is missing or out of scope.' }
        $intent = Get-Json @('rest', '--method', 'get', '--url', "https://management.azure.com$hubId/routingIntent?api-version=2024-05-01", '-o', 'json')
        $policies = @($intent.value.properties.routingPolicies)
        foreach ($destination in @('Internet', 'PrivateTraffic')) {
            $matching = @($policies | Where-Object { $_.destinations -contains $destination -and $_.nextHop })
            $status = if ($matching.Count -eq 1) { 'PASS' } else { 'FAIL' }
            Add-Check "Routing intent ($region/$destination)" $status 'A next hop for the required destination must exist'
        }
    }
    catch { Add-Check "Routing intent ($region)" 'FAIL' $_.Exception.Message }
}

Write-Host "`n=== Verdict ===" -ForegroundColor Cyan
$fails = @($results | Where-Object Status -eq 'FAIL')
$warns = @($results | Where-Object Status -eq 'WARN')
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

$results
if ($fails.Count -or $warns.Count -or -not $results.Count) { throw 'Deployment verification failed; expected controls are missing, unhealthy, or inconclusive.' }
