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

function Test-SharedPrivateLink {
    param([string]$Label, [string]$Id, [string]$TargetId, [string]$GroupId)
    try {
        $link = Get-Json @('rest', '--method', 'get', '--url', "https://management.azure.com${Id}?api-version=2025-05-01", '-o', 'json')
        $ready = $link.id -eq $Id -and $link.properties.privateLinkResourceId -eq $TargetId -and
            $link.properties.groupId -eq $GroupId -and $link.properties.status -eq 'Approved' -and $link.properties.provisioningState -eq 'Succeeded'
        $status = if ($ready) { 'PASS' } else { 'FAIL' }
        Add-Check $Label $status "status=$($link.properties.status); provisioningState=$($link.properties.provisioningState)"
    }
    catch { Add-Check $Label 'FAIL' $_.Exception.Message }
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

$native = $lab.NativeIngestion
$nativeReady = $false
try {
    foreach ($field in @('storage_resource_id', 'storage_endpoint', 'container_name', 'folder_path', 'identity_resource_id', 'ai_services_endpoint', 'openai_endpoint', 'chat_deployment', 'chat_model', 'embedding_deployment', 'embedding_model')) {
        if ($native.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($native.$field)) { throw "native_ingestion.$field is required; apply the native ingestion Terraform configuration first." }
    }
    $stagingId = "/subscriptions/$($lab.SubscriptionId)/resourceGroups/$SecondaryResourceGroup/providers/Microsoft.Storage/storageAccounts/$($lab.Secondary.StagingStorage)"
    $identityPrefix = "/subscriptions/$($lab.SubscriptionId)/resourceGroups/$PrimaryResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/"
    if ($native.storage_resource_id -ne $stagingId -or
        -not $native.identity_resource_id.StartsWith($identityPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $native.identity_resource_id.Substring($identityPrefix.Length) -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Native ingestion resource identities are missing or out of scope.' }
    if ($native.storage_endpoint.TrimEnd('/') -ne "https://$($lab.Hosts.StagingStorage)" -or
        $native.ai_services_endpoint.TrimEnd('/') -ne "https://$($lab.Secondary.Account).services.ai.azure.com" -or
        $native.openai_endpoint.TrimEnd('/') -ne "https://$($lab.Secondary.Account).openai.azure.com") { throw 'Native ingestion endpoints must match the Terraform staging storage and secondary Foundry account.' }
    $nativeLinks = @($native.shared_private_links.PSObject.Properties)
    if ($native.shared_private_links -isnot [pscustomobject] -or $nativeLinks.Count -ne 3) { throw 'Native ingestion requires exactly three declared shared private links.' }
    foreach ($groupId in @('blob', 'foundry_account', 'openai_account')) {
        $matching = @($nativeLinks | Where-Object { $_.Value.group_id -eq $groupId })
        if ($matching.Count -ne 1) { throw "Native ingestion requires exactly one $groupId shared private link." }
        $link = $matching[0]
        $targetId = if ($groupId -eq 'blob') { $stagingId } else { $lab.SecondaryFoundryId }
        if ($link.Name -notmatch '^[a-zA-Z0-9_-]+$' -or
            $link.Value.id -ne "$($lab.SearchId)/sharedPrivateLinkResources/$($link.Name)" -or
            $link.Value.target_resource_id -ne $targetId) { throw "Native ingestion $groupId shared private link identity or target is out of scope." }
    }
    $nativeReady = $true
    Add-Check 'Native ingestion output contract' 'PASS' 'Staging inputs, secondary model endpoints, UAMI and three scoped SPLs are present'
}
catch { Add-Check 'Native ingestion output contract' 'FAIL' $_.Exception.Message }

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

$resources = @{}
foreach ($target in $targets) {
    $target.id = "/subscriptions/$($lab.SubscriptionId)/resourceGroups/$($target.rg)/providers/$($target.type)/$($target.name)"
    try {
        if (-not $target.name) { throw 'Expected resource name is missing from Terraform outputs.' }
        $detail = Get-Json @('resource', 'show', '--ids', $target.id, '-o', 'json')
        if ($detail.id -ne $target.id) { throw 'Expected resource missing or returned identity mismatched.' }
        $resources[$target.id] = $detail
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

if ($nativeReady) {
    try {
        $search = $resources[$lab.SearchId]
        if (-not $search) { throw 'Search resource readback is unavailable.' }
        $eligible = $search.sku.name -in @('standard', 'standard2', 'standard3')
        $status = if ($eligible) { 'PASS' } else { 'FAIL' }
        Add-Check 'Native ingestion Search tier' $status "sku=$($search.sku.name); directly configured native CU indexers support standard (S1), standard2 and standard3"
        if ($search.sku.name -eq 'standard') {
            $dateSource = 'properties.createdAt'
            $createdAt = [string]$search.properties.createdAt
            if ([string]::IsNullOrWhiteSpace($createdAt)) {
                $dateSource = 'systemData.createdAt'
                $createdAt = [string]$search.systemData.createdAt
            }
            $created = [DateTimeOffset]::MinValue
            $ageEligible = [DateTimeOffset]::TryParse($createdAt, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$created) -and
                $created -ge [DateTimeOffset]'2024-04-03T00:00:00Z'
            $status = if ($ageEligible) { 'PASS' } else { 'FAIL' }
            Add-Check 'Native ingestion Search creation date' $status "Live ARM ${dateSource}='$createdAt'; S1 directly configured private enrichment requires createdAt >= 2024-04-03 (UTC). If missing or invalid, verify properties.createdAt or systemData.createdAt before running the native CU indexer."
        }
        else { Add-Check 'Native ingestion Search creation date' 'PASS' 'S1 createdAt >= 2024-04-03 eligibility check is not required for this tier; see the separate tier check' }
        $status = if ($search.properties.provisioningState -eq 'Succeeded' -and $search.properties.semanticSearch -eq 'standard' -and $search.properties.hostingMode -eq 'Default' -and $search.properties.networkRuleSet.bypass -eq 'None') { 'PASS' } else { 'FAIL' }
        Add-Check 'Native Search runtime' $status "provisioningState=$($search.properties.provisioningState); Succeeded, semantic ranker enabled, default hosting mode and no trusted-service bypass required"
        $ingestionIdentity = Get-Json @('resource', 'show', '--ids', $native.identity_resource_id, '-o', 'json')
        if ($ingestionIdentity.id -ne $native.identity_resource_id -or -not $ingestionIdentity.properties.principalId -or -not $ingestionIdentity.properties.clientId) { throw 'Native ingestion UAMI readback is missing or mismatched.' }
        $searchIdentities = @($search.identity.userAssignedIdentities.PSObject.Properties)
        $assigned = $searchIdentities | Where-Object { $_.Name -eq $native.identity_resource_id }
        $functionId = "/subscriptions/$($lab.SubscriptionId)/resourceGroups/$SecondaryResourceGroup/providers/Microsoft.Web/sites/$($lab.Function.Name)"
        $function = $resources[$functionId]
        $functionIdentities = @($function.identity.userAssignedIdentities.PSObject.Properties)
        $segregated = $lab.Function.IdentityObject -and $lab.Function.IdentityClient -and $search.identity.principalId -and
            $search.identity.type -match 'SystemAssigned' -and $search.identity.type -match 'UserAssigned' -and
            $assigned -and $assigned.Value.principalId -eq $ingestionIdentity.properties.principalId -and
            $assigned.Value.clientId -eq $ingestionIdentity.properties.clientId -and
            $ingestionIdentity.properties.principalId -ne $lab.Function.IdentityObject -and
            $ingestionIdentity.properties.clientId -ne $lab.Function.IdentityClient -and
            $search.identity.principalId -ne $ingestionIdentity.properties.principalId -and
            $search.identity.principalId -ne $lab.Function.IdentityObject -and
            @($searchIdentities | Where-Object { $_.Value.principalId -eq $lab.Function.IdentityObject -or $_.Value.clientId -eq $lab.Function.IdentityClient }).Count -eq 0 -and
            @($functionIdentities | Where-Object { $_.Value.principalId -eq $lab.Function.IdentityObject -and $_.Value.clientId -eq $lab.Function.IdentityClient }).Count -eq 1 -and
            @($functionIdentities | Where-Object { $_.Name -eq $native.identity_resource_id -or $_.Value.principalId -eq $ingestionIdentity.properties.principalId }).Count -eq 0
        $status = if ($segregated) { 'PASS' } else { 'FAIL' }
        Add-Check 'Native ingestion identity segregation' $status 'Search system identity, Search ingestion UAMI and staging Function identity must be distinct and correctly attached'
    }
    catch { Add-Check 'Native ingestion identity segregation' 'FAIL' $_.Exception.Message }

    foreach ($entry in $nativeLinks) {
        $expected = $entry.Value
        Test-SharedPrivateLink -Label "Native ingestion SPL: $($expected.group_id)" -Id $expected.id -TargetId $expected.target_resource_id -GroupId $expected.group_id
    }
}

Test-SharedPrivateLink -Label 'Primary planner SPL' -Id "$($lab.SearchId)/sharedPrivateLinkResources/spl-foundry" -TargetId $lab.FoundryId -GroupId 'openai_account'

$deployments = @(
    @{ Label = 'Primary planner deployment'; Account = $lab.FoundryId; Deployment = $lab.Primary.PlannerDeployment; Model = $lab.Primary.PlannerModel }
    @{ Label = 'Primary agent tool deployment'; Account = $lab.FoundryId; Deployment = $lab.Primary.AgentToolModel; Model = $lab.Primary.AgentToolModel }
)
if ($nativeReady) {
    $deployments += @(
        @{ Label = 'Native ingestion chat deployment'; Account = $lab.SecondaryFoundryId; Deployment = $native.chat_deployment; Model = $native.chat_model }
        @{ Label = 'Native ingestion embedding deployment'; Account = $lab.SecondaryFoundryId; Deployment = $native.embedding_deployment; Model = $native.embedding_model }
    )
}
foreach ($expected in $deployments) {
    try {
        if ($expected.Deployment -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -or -not $expected.Model) { throw 'Expected model deployment is missing or invalid in Terraform outputs.' }
        $deploymentId = "$($expected.Account)/deployments/$($expected.Deployment)"
        $deployment = Get-Json @('rest', '--method', 'get', '--url', "https://management.azure.com${deploymentId}?api-version=2025-06-01", '-o', 'json')
        $ready = $deployment.id -eq $deploymentId -and $deployment.properties.provisioningState -eq 'Succeeded' -and $deployment.properties.model.name -eq $expected.Model
        $status = if ($ready) { 'PASS' } else { 'FAIL' }
        Add-Check $expected.Label $status "model=$($deployment.properties.model.name); provisioningState=$($deployment.properties.provisioningState)"
    }
    catch { Add-Check $expected.Label 'FAIL' $_.Exception.Message }
}

$roleChecks = @(
    @{ Label = 'Primary planner role'; Scope = $lab.FoundryId; Principal = $resources[$lab.SearchId].identity.principalId; Roles = @('Cognitive Services OpenAI User'); Absent = $false }
    @{ Label = 'Function Search privileges removed'; Scope = $lab.SearchId; Principal = $lab.Function.IdentityObject; Roles = @('Search Index Data Contributor', 'Search Index Data Reader', 'Search Service Contributor', 'Owner', 'Contributor'); Absent = $true }
)
foreach ($accountId in @($lab.FoundryId, $lab.SecondaryFoundryId)) {
    $region = if ($accountId -eq $lab.FoundryId) { 'primary' } else { 'secondary' }
    $roleChecks += @{ Label = "Function Foundry privileges removed ($region)"; Scope = $accountId; Principal = $lab.Function.IdentityObject; Roles = @('Cognitive Services User', 'Cognitive Services Contributor', 'Cognitive Services OpenAI User', 'Cognitive Services OpenAI Contributor', 'Owner', 'Contributor'); Absent = $true }
}
if ($nativeReady) {
    $ingestionPrincipal = $ingestionIdentity.properties.principalId
    $roleChecks += @(
        @{ Label = 'Native ingestion Blob reader role'; Scope = $native.storage_resource_id; Principal = $ingestionPrincipal; Roles = @('Storage Blob Data Reader'); Absent = $false }
        @{ Label = 'Native ingestion Cognitive Services role'; Scope = $lab.SecondaryFoundryId; Principal = $ingestionPrincipal; Roles = @('Cognitive Services User'); Absent = $false }
        @{ Label = 'Native ingestion OpenAI role'; Scope = $lab.SecondaryFoundryId; Principal = $ingestionPrincipal; Roles = @('Cognitive Services OpenAI User'); Absent = $false }
        @{ Label = 'Function staging writer role'; Scope = $native.storage_resource_id; Principal = $lab.Function.IdentityObject; Roles = @('Storage Blob Data Contributor'); Absent = $false }
        @{ Label = 'Native ingestion Blob write privileges absent'; Scope = $native.storage_resource_id; Principal = $ingestionPrincipal; Roles = @('Storage Blob Data Contributor', 'Storage Blob Data Owner', 'Owner', 'Contributor'); Absent = $true }
        @{ Label = 'Native ingestion Search write privileges absent'; Scope = $lab.SearchId; Principal = $ingestionPrincipal; Roles = @('Search Index Data Contributor', 'Search Service Contributor', 'Owner', 'Contributor'); Absent = $true }
    )
}
$roleReadbacks = @{}
foreach ($scope in @($roleChecks.Scope | Sort-Object -Unique)) {
    try {
        $assignments = Get-Json @('role', 'assignment', 'list', '--scope', $scope, '--include-inherited', '--fill-principal-name', 'false', '-o', 'json')
        if ($assignments -isnot [array] -or @($assignments | Where-Object {
            $_.principalId -isnot [string] -or [string]::IsNullOrWhiteSpace($_.principalId) -or
            $_.scope -isnot [string] -or [string]::IsNullOrWhiteSpace($_.scope) -or
            $_.roleDefinitionName -isnot [string] -or [string]::IsNullOrWhiteSpace($_.roleDefinitionName)
        }).Count) { throw 'Role assignment readback is malformed.' }
        $roleReadbacks[$scope] = $assignments
    }
    catch { Add-Check 'Role assignment readback' 'FAIL' 'Role assignments could not be read; required grants and removed privileges cannot be confirmed' }
}
foreach ($expected in $roleChecks) {
    if (-not $expected.Principal -or -not $roleReadbacks.ContainsKey($expected.Scope)) {
        Add-Check $expected.Label 'FAIL' 'Identity or role readback unavailable; no permission conclusion can be made'
        continue
    }
    $matching = @($roleReadbacks[$expected.Scope] | Where-Object {
        $_.principalId -eq $expected.Principal -and $_.roleDefinitionName -in $expected.Roles -and
        ($_.scope -eq $expected.Scope -or $expected.Scope.StartsWith("$($_.scope.TrimEnd('/'))/", [StringComparison]::OrdinalIgnoreCase))
    })
    $ready = if ($expected.Absent) { $matching.Count -eq 0 } else { $matching.Count -gt 0 }
    $status = if ($ready) { 'PASS' } else { 'FAIL' }
    $detail = if ($expected.Absent) { 'Removed or excessive built-in grants must be absent, including inherited assignments' } else { 'Required role must apply to the expected principal and scope' }
    Add-Check $expected.Label $status $detail
}

try {
    $settingNames = Get-Json @('functionapp', 'config', 'appsettings', 'list', '-g', $SecondaryResourceGroup, '-n', $lab.Function.Name, '--query', '[].name', '-o', 'json')
    if ($settingNames -isnot [array] -or -not $settingNames.Count -or @($settingNames | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count) { throw 'Function setting names are unavailable.' }
    $legacyNames = @($settingNames | Where-Object { $_ -in @('CU_ENDPOINT', 'CU_ANALYZER_ID', 'SEARCH_ENDPOINT', 'SEARCH_INDEX') })
    $status = if ($legacyNames.Count -eq 0) { 'PASS' } else { 'FAIL' }
    Add-Check 'Function Search/CU settings removed' $status 'Setting names only: legacy Search and Content Understanding settings must be absent'
}
catch { Add-Check 'Function Search/CU settings removed' 'FAIL' 'Function setting-name readback is unavailable or invalid; no setting values are reported' }

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
    * Function staging upload and directly configured native CU indexer ingestion
    * Search indexer calls through its three ingestion SPLs (not through the lab hubs)
    * Content Understanding and secondary model availability during native ingestion
'@ -ForegroundColor DarkGray

$results
if ($fails.Count -or $warns.Count -or -not $results.Count) { throw 'Deployment verification failed; expected controls are missing, unhealthy, or inconclusive.' }
