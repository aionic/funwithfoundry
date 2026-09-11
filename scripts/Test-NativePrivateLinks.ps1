<#
.SYNOPSIS
    Read-only native ingestion private-link readiness gate (PowerShell 5.1 compatible).
.DESCRIPTION
    Validates Terraform bindings before ARM reads, then checks Search tier/age/UAMI and
    exactly three shared links. Never approves connections, changes roles, runs an
    indexer, or polls. Effective RBAC and data-plane reachability require private E2E.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [Parameter(Mandatory)][guid]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-NativeLinkField {
    param($Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return ,$Value[$Name] }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Get-NativeLinkResource {
    param([string]$ResourceId)
    $global:LASTEXITCODE = 0
    $response = & az rest --method get --subscription ([string]$SubscriptionId) --url "https://management.azure.com${ResourceId}?api-version=2025-05-01" --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "ARM read failed for $ResourceId. Check Reader access and resource existence; no changes attempted." }
    $response | ConvertFrom-Json
}

if ($SubscriptionId -eq [guid]::Empty) { throw 'Specify a nonempty SubscriptionId for native private-link verification.' }
$TerraformDir = (Resolve-Path -LiteralPath $TerraformDir -ErrorAction Stop).Path
$global:LASTEXITCODE = 0
$raw = & terraform "-chdir=$TerraformDir" output -json
if ($LASTEXITCODE -ne 0) { throw 'Terraform output read failed; native private links were not queried.' }
$outputs = $raw | ConvertFrom-Json
if ([string](Get-NativeLinkField (Get-NativeLinkField $outputs 'subscription_id') 'value') -ne [string]$SubscriptionId) {
    throw 'Terraform subscription output is missing or mismatched; native private links were not queried.'
}
$ingestion = Get-NativeLinkField (Get-NativeLinkField $outputs 'native_ingestion') 'value'
$primary = Get-NativeLinkField (Get-NativeLinkField $outputs 'foundry_primary') 'value'
$groups = Get-NativeLinkField (Get-NativeLinkField $outputs 'resource_groups') 'value'
$searchName = [string](Get-NativeLinkField $primary 'search')
$resourceGroup = [string](Get-NativeLinkField $groups 'primary')
if ($searchName -cnotmatch '^[a-z0-9][a-z0-9-]{1,58}[a-z0-9]$' -or $resourceGroup -notmatch '^[a-zA-Z0-9_.()-]+$') {
    throw 'Missing or invalid primary Search ARM binding in Terraform outputs.'
}
$scope = '^/subscriptions/' + [regex]::Escape([string]$SubscriptionId) + '/resourceGroups/[a-zA-Z0-9_.()-]+/providers/'
$searchId = "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Search/searchServices/$searchName"
$storageId = [string](Get-NativeLinkField $ingestion 'storage_resource_id')
$identityId = [string](Get-NativeLinkField $ingestion 'identity_resource_id')
if ($storageId -notmatch ($scope + 'Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}$') -or
    $identityId -notmatch ($scope + 'Microsoft\.ManagedIdentity/userAssignedIdentities/[a-zA-Z0-9_-]+$')) {
    throw 'Native storage/UAMI output is missing, malformed, or outside the selected subscription.'
}
$links = Get-NativeLinkField $ingestion 'shared_private_links'
$expectedGroups = [ordered]@{ 'spl-native-staging-blob' = 'blob'; 'spl-native-foundry' = 'foundry_account'; 'spl-native-openai' = 'openai_account' }
if ($null -eq $links -or @($links.PSObject.Properties).Count -ne 3 -or
    @($links.PSObject.Properties.Name | Where-Object { $_ -cnotin @($expectedGroups.Keys) }).Count -ne 0) {
    throw 'Native ingestion requires exactly spl-native-staging-blob, spl-native-foundry, and spl-native-openai; refresh Terraform outputs.'
}
$foundryId = [string](Get-NativeLinkField (Get-NativeLinkField $links 'spl-native-foundry') 'target_resource_id')
if ($foundryId -notmatch ($scope + 'Microsoft\.CognitiveServices/accounts/[a-zA-Z0-9_-]+$')) { throw 'Native Foundry target is missing, malformed, or outside the selected subscription.' }
$foundryName = ($foundryId -split '/')[-1]
if (([string](Get-NativeLinkField $ingestion 'openai_endpoint')).TrimEnd('/') -cne "https://$foundryName.openai.azure.com" -or
    ([string](Get-NativeLinkField $ingestion 'ai_services_endpoint')).TrimEnd('/') -cne "https://$foundryName.services.ai.azure.com") {
    throw 'Native Foundry private-link target does not match the ingestion endpoint bindings.'
}
foreach ($name in $expectedGroups.Keys) {
    $link = Get-NativeLinkField $links $name
    $target = if ($name -eq 'spl-native-staging-blob') { $storageId } else { $foundryId }
    if ([string](Get-NativeLinkField $link 'id') -ne "$searchId/sharedPrivateLinkResources/$name" -or
        [string](Get-NativeLinkField $link 'group_id') -cne $expectedGroups[$name] -or
        [string](Get-NativeLinkField $link 'target_resource_id') -ne $target) {
        throw "Native private-link output mismatch for $name. Expected $searchId/sharedPrivateLinkResources/$name -> $target (group $($expectedGroups[$name])); no ARM reads attempted."
    }
}
$failures = [Collections.Generic.List[string]]::new()
$verified = [Collections.Generic.List[object]]::new()
try {
    $search = Get-NativeLinkResource $searchId
    $sku = [string](Get-NativeLinkField (Get-NativeLinkField $search 'sku') 'name')
    $searchProperties = Get-NativeLinkField $search 'properties'
    $hostingMode = [string](Get-NativeLinkField $searchProperties 'hostingMode')
    $identity = Get-NativeLinkField $search 'identity'
    $assigned = Get-NativeLinkField $identity 'userAssignedIdentities'
    if ([string](Get-NativeLinkField $search 'id') -ne $searchId -or $sku -notin @('standard', 'standard2', 'standard3') -or
        $hostingMode -notin @('', 'default') -or [string](Get-NativeLinkField $searchProperties 'provisioningState') -ne 'Succeeded') {
        $failures.Add("$searchId must be Succeeded on standard (S1), standard2, or standard3 (not high-density); verify the Terraform Search tier.")
    }
    if ($sku -eq 'standard') {
        $createdAt = [string](Get-NativeLinkField $searchProperties 'createdAt')
        if ([string]::IsNullOrWhiteSpace($createdAt)) {
            $createdAt = [string](Get-NativeLinkField (Get-NativeLinkField $search 'systemData') 'createdAt')
        }
        $created = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($createdAt, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$created) -or
            $created -lt [DateTimeOffset]'2024-04-03T00:00:00Z') {
            $failures.Add("$searchId S1 directly configured private enrichment requires live ARM properties.createdAt or systemData.createdAt >= 2024-04-03 (UTC); received '$createdAt'. Verify the service creation date before running the native CU indexer.")
        }
    }
    if ([string](Get-NativeLinkField $identity 'type') -notmatch '(?:^|,\s*)UserAssigned(?:\s*,|$)' -or
        $null -eq $assigned -or @($assigned.PSObject.Properties.Name | Where-Object { $_ -eq $identityId }).Count -ne 1) {
        $failures.Add("$searchId must attach ingestion UAMI $identityId; repair the reviewed Terraform identity assignment.")
    }
}
catch { $failures.Add("Unable to verify $searchId; check ARM Reader access, response shape, and Search availability. No changes attempted.") }
foreach ($name in $expectedGroups.Keys) {
    $binding = Get-NativeLinkField $links $name
    $id = [string]$binding.id
    $target = [string]$binding.target_resource_id
    $group = [string]$binding.group_id
    try {
        $live = Get-NativeLinkResource $id
        $properties = Get-NativeLinkField $live 'properties'
        $status = [string](Get-NativeLinkField $properties 'status')
        $provisioning = [string](Get-NativeLinkField $properties 'provisioningState')
        if ([string](Get-NativeLinkField $live 'id') -ne $id -or
            [string](Get-NativeLinkField $properties 'privateLinkResourceId') -ne $target -or
            [string](Get-NativeLinkField $properties 'groupId') -cne $group) {
            $failures.Add("$id target/group/ID mismatch. Expected $target (group $group); inspect the exact Search shared link and correct the reviewed binding. Do not approve unrelated connections.")
        }
        elseif ($status -ne 'Approved' -or $provisioning -ne 'Succeeded') {
            $failures.Add("$id -> $target (group $group): status='$status', provisioningState='$provisioning'. On target $target, inspect private endpoint connections and correlate this exact Search shared link before explicit human approval. If correlation is ambiguous, stop. Rerun this gate only after Approved and Succeeded; no automatic approval or retry is performed.")
        }
        else { $verified.Add([pscustomobject]@{ id = $id; target_resource_id = $target; group_id = $group; status = $status; provisioning_state = $provisioning }) }
    }
    catch { $failures.Add("Unable to verify $id -> $target (group $group). Check ARM Reader access and the exact link response; no approval attempted.") }
}
if ($failures.Count) { throw ("Native private-link gate blocked:`n" + ($failures -join "`n")) }
[pscustomobject]@{ status = 'passed'; search_id = $searchId; identity_resource_id = $identityId; links = $verified.ToArray() }