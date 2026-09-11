[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$subscription = '11111111-1111-4111-8111-111111111111'
$scope = "/subscriptions/$subscription/resourceGroups/mock-rg/providers"
$searchId = "$scope/Microsoft.Search/searchServices/mock-search"
$storageId = "$scope/Microsoft.Storage/storageAccounts/mockstorage"
$foundryId = "$scope/Microsoft.CognitiveServices/accounts/mock-foundry"
$identityId = "$scope/Microsoft.ManagedIdentity/userAssignedIdentities/mock-ingestion"
$nativeLinkTest = @{ checks = 0 }
$calls = [Collections.Generic.List[object]]::new()
$outputs = @{
    subscription_id = @{ value = $subscription }; resource_groups = @{ value = @{ primary = 'mock-rg' } }
    foundry_primary = @{ value = @{ search = 'mock-search' } }
    native_ingestion = @{ value = @{
        storage_resource_id = $storageId; identity_resource_id = $identityId
        ai_services_endpoint = 'https://mock-foundry.services.ai.azure.com'; openai_endpoint = 'https://mock-foundry.openai.azure.com'
        shared_private_links = @{}
    } }
}
$resources = @{}
$resources[$searchId] = @{
    id = $searchId; sku = @{ name = 'standard2' }; properties = @{ provisioningState = 'succeeded'; hostingMode = 'Default' }
    identity = @{ type = 'SystemAssigned, UserAssigned'; userAssignedIdentities = @{ $identityId = @{} } }
}
foreach ($entry in @(@('spl-native-staging-blob', 'blob', $storageId), @('spl-native-foundry', 'foundry_account', $foundryId), @('spl-native-openai', 'openai_account', $foundryId))) {
    $name = $entry[0]
    $id = "$searchId/sharedPrivateLinkResources/$name"
    $outputs.native_ingestion.value.shared_private_links[$name] = @{ id = $id; target_resource_id = $entry[2]; group_id = $entry[1] }
    $resources[$id] = @{ id = $id; properties = @{ privateLinkResourceId = $entry[2]; groupId = $entry[1]; status = 'Approved'; provisioningState = 'Succeeded' } }
}
$baselineOutputs = $outputs | ConvertTo-Json -Depth 20
$baselineResources = $resources | ConvertTo-Json -Depth 20
$mock = @{ terraformExit = 0; azureExit = 0; invalidJson = $false }

function Assert-NativeLinks {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $nativeLinkTest.checks++
}
function terraform {
    Assert-NativeLinks (($args -join '|') -eq "-chdir=$(Join-Path $root 'terraform')|output|-json") 'Only Terraform output is read'
    $global:LASTEXITCODE = $mock.terraformExit
    $outputs | ConvertTo-Json -Depth 20
}
function az {
    $calls.Add(@($args))
    Assert-NativeLinks ($args[0] -eq 'rest' -and $args[2] -eq 'get' -and $args[4] -eq $subscription) 'Only subscription-scoped ARM GETs are allowed'
    $url = [string]$args[[array]::IndexOf($args, '--url') + 1]
    Assert-NativeLinks ($url.StartsWith('https://management.azure.com/') -and $url.EndsWith('?api-version=2025-05-01')) 'Only the fixed ARM host and API version are allowed'
    $id = $url.Substring('https://management.azure.com'.Length).Split('?')[0]
    Assert-NativeLinks ($null -ne $resources.PSObject.Properties[$id]) 'Only the exact Search and three native links may be read'
    $global:LASTEXITCODE = $mock.azureExit
    if ($mock.invalidJson) { return '{invalid' }
    $resources.$id | ConvertTo-Json -Depth 20
}
function Start-Sleep { throw 'No waits allowed in the native link gate.' }
function Invoke-RestMethod { throw 'Direct HTTP is forbidden in this cloud-free suite.' }
function Invoke-WebRequest { throw 'Direct HTTP is forbidden in this cloud-free suite.' }

$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Test-NativePrivateLinks.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-NativeLinks ($parseErrors.Count -eq 0) 'Native verifier parses'
foreach ($scenario in @('ready', 'standard3', 's1-modern', 's1-system-data', 's1-boundary', 's1-old', 's1-missing-date', 's1-invalid-date',
    'pending-all', 'rejected', 'disconnected', 'provisioning', 'failed', 'missing-properties',
    'live-id', 'live-target', 'live-group', 'search-id', 'search-state', 'basic-tier', 'high-density', 'missing-uami', 'wrong-uami', 'identity-type',
    'missing-output', 'subscription', 'empty-subscription', 'missing-link', 'extra-link', 'renamed-link', 'output-id', 'output-target', 'output-group',
    'foreign-uami', 'foreign-storage', 'foreign-foundry', 'endpoint-mismatch', 'missing-search', 'terraform-failure', 'azure-failure', 'invalid-json')) {
    $outputs = $baselineOutputs | ConvertFrom-Json
    $resources = $baselineResources | ConvertFrom-Json
    $calls.Clear()
    $mock.terraformExit = 0; $mock.azureExit = 0; $mock.invalidJson = $false
    $selectedSubscription = $subscription
    $native = $outputs.native_ingestion.value
    $blobId = "$searchId/sharedPrivateLinkResources/spl-native-staging-blob"
    $blob = $resources.$blobId
    switch ($scenario) {
        'standard3' { $resources.$searchId.sku.name = 'standard3' }
        's1-modern' { $resources.$searchId.sku.name = 'standard'; $resources.$searchId.properties | Add-Member createdAt '2026-09-09T00:00:00Z' }
        's1-system-data' { $resources.$searchId.sku.name = 'standard'; $resources.$searchId | Add-Member systemData @{ createdAt = '2026-09-09T00:00:00Z' } }
        's1-boundary' { $resources.$searchId.sku.name = 'standard'; $resources.$searchId.properties | Add-Member createdAt '2024-04-03T00:00:00Z' }
        's1-old' { $resources.$searchId.sku.name = 'standard'; $resources.$searchId.properties | Add-Member createdAt '2024-04-02T23:59:59Z' }
        's1-missing-date' { $resources.$searchId.sku.name = 'standard' }
        's1-invalid-date' { $resources.$searchId.sku.name = 'standard'; $resources.$searchId.properties | Add-Member createdAt 'not-a-date' }
        'pending-all' { foreach ($name in $native.shared_private_links.PSObject.Properties.Name) { $resources.($native.shared_private_links.$name.id).properties.status = 'Pending' } }
        'rejected' { $blob.properties.status = 'Rejected' }
        'disconnected' { $blob.properties.status = 'Disconnected' }
        'provisioning' { $blob.properties.provisioningState = 'Updating' }
        'failed' { $blob.properties.provisioningState = 'Failed' }
        'missing-properties' { $blob.properties = $null }
        'live-id' { $blob.id += '-wrong' }
        'live-target' { $blob.properties.privateLinkResourceId = $foundryId }
        'live-group' { $blob.properties.groupId = 'account' }
        'search-id' { $resources.$searchId.id += '-wrong' }
        'search-state' { $resources.$searchId.properties.provisioningState = 'Updating' }
        'basic-tier' { $resources.$searchId.sku.name = 'basic' }
        'high-density' { $resources.$searchId.sku.name = 'standard3'; $resources.$searchId.properties.hostingMode = 'highDensity' }
        'missing-uami' { $resources.$searchId.identity.userAssignedIdentities = $null }
        'wrong-uami' { $resources.$searchId.identity.userAssignedIdentities = @{ "$identityId-wrong" = @{} } }
        'identity-type' { $resources.$searchId.identity.type = 'SystemAssigned' }
        'missing-output' { $outputs.native_ingestion = $null }
        'subscription' { $outputs.subscription_id.value = '22222222-2222-4222-8222-222222222222' }
        'empty-subscription' { $selectedSubscription = [guid]::Empty }
        'missing-link' { $native.shared_private_links.PSObject.Properties.Remove('spl-native-openai') }
        'extra-link' { $native.shared_private_links | Add-Member other @{} }
        'renamed-link' { $native.shared_private_links.PSObject.Properties.Remove('spl-native-openai'); $native.shared_private_links | Add-Member wrong @{} }
        'output-id' { $native.shared_private_links.'spl-native-staging-blob'.id = $blobId.Replace('mock-search', 'other-search') }
        'output-target' { $native.shared_private_links.'spl-native-openai'.target_resource_id += '-other' }
        'output-group' { $native.shared_private_links.'spl-native-foundry'.group_id = 'account' }
        'foreign-uami' { $native.identity_resource_id = $identityId.Replace($subscription, '22222222-2222-4222-8222-222222222222') }
        'foreign-storage' { $native.storage_resource_id = $storageId.Replace($subscription, '22222222-2222-4222-8222-222222222222') }
        'foreign-foundry' { $native.shared_private_links.'spl-native-foundry'.target_resource_id = $foundryId.Replace($subscription, '22222222-2222-4222-8222-222222222222') }
        'endpoint-mismatch' { $native.openai_endpoint = 'https://other.openai.azure.com' }
        'missing-search' { $outputs.foundry_primary.value.search = '' }
        'terraform-failure' { $mock.terraformExit = 1 }
        'azure-failure' { $mock.azureExit = 1 }
        'invalid-json' { $mock.invalidJson = $true }
    }
    $failure = $null
    $result = $null
    try { $result = & (Join-Path $root 'scripts\Test-NativePrivateLinks.ps1') -TerraformDir (Join-Path $root 'terraform') -SubscriptionId $selectedSubscription }
    catch { $failure = $_ }
    if ($scenario -in @('ready', 'standard3', 's1-modern', 's1-system-data', 's1-boundary')) {
        Assert-NativeLinks ($null -eq $failure -and $result.status -eq 'passed' -and $result.links.Count -eq 3) "$scenario returns exactly three verified links ($failure)"
    }
    else { Assert-NativeLinks ($null -ne $failure) "$scenario fails closed" }
    if ($scenario -in @('s1-old', 's1-missing-date', 's1-invalid-date')) {
        Assert-NativeLinks ($failure.Exception.Message -like '*createdAt*' -and $failure.Exception.Message -like '*2024-04-03*') "$scenario explains the live creation-date requirement"
        Assert-NativeLinks ($failure.Exception.Message -notmatch 'quota') "$scenario is an eligibility failure, not a quota block"
    }
    if ($scenario -in @('missing-output', 'subscription', 'empty-subscription', 'missing-link', 'extra-link', 'renamed-link', 'output-id', 'output-target',
        'output-group', 'foreign-uami', 'foreign-storage', 'foreign-foundry', 'endpoint-mismatch', 'missing-search', 'terraform-failure')) {
        Assert-NativeLinks ($calls.Count -eq 0) "$scenario fails before ARM reads"
    }
    else { Assert-NativeLinks ($calls.Count -eq 4) "$scenario reads Search and each exact native link once without retry" }
    if ($scenario -eq 'pending-all') {
        foreach ($binding in $native.shared_private_links.PSObject.Properties.Value) {
            Assert-NativeLinks ($failure.Exception.Message.Contains($binding.id) -and $failure.Exception.Message.Contains($binding.target_resource_id)) 'Pending report identifies each exact link and approval target'
        }
        Assert-NativeLinks ($failure.Exception.Message -like '*explicit human approval*' -and $failure.Exception.Message -like '*ambiguous, stop*') 'Pending guidance requires human correlation and approval'
    }
}
$global:LASTEXITCODE = 0
Write-Output "PASS: $($nativeLinkTest.checks) cloud-free native private-link assertions; no Azure writes, approvals, or waits."