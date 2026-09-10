<#
.SYNOPSIS
    Reduce or tear down the funwithfoundry lab.
.DESCRIPTION
    -Mode Pause      Deallocate the jumpbox only. Firewalls and hubs keep billing.
    -Mode Teardown   Full terraform destroy, with the Foundry purge ordering handled first.

    Teardown ordering matters: the Foundry accounts must be deleted AND purged before the
    VNet, or the serviceAssociationLink on the agent subnet blocks VNet deletion.
    Capability hosts must go before the accounts.
#>
[CmdletBinding()]
param(
    [ValidateSet('Pause', 'Teardown')]
    [string]$Mode = 'Pause',

    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [ValidateRange(1, 120)][int]$TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'

function Get-StateResources {
    param($Module)
    @($Module.resources) | Where-Object { $_.mode -eq 'managed' }
    foreach ($child in $Module.child_modules) { Get-StateResources $child }
}

function Invoke-LabAz {
    param([string[]]$CliArgs)
    $raw = & az @CliArgs --subscription $subscriptionId -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure command failed (exit $LASTEXITCODE): $($CliArgs[0..1] -join ' ')" }
    if (-not $raw) { throw 'Azure command returned no JSON result.' }
    ConvertFrom-Json -InputObject ($raw -join "`n") -NoEnumerate
}

function Assert-Deadline {
    if ((Get-Date) -ge $deadline) { throw 'Teardown deadline exceeded; remaining infrastructure was not destroyed.' }
}

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir
if ($LASTEXITCODE -ne 0) { throw 'Lab environment lookup failed.' }
Push-Location $TerraformDir
try {
    $raw = terraform show -json
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Cannot resolve Terraform state for safe teardown.' }
    $state = $raw | ConvertFrom-Json
}
finally { Pop-Location }
$resources = @(Get-StateResources $state.values.root_module)
$groups = @($lab.ResourceGroups.Network, $lab.ResourceGroups.Primary, $lab.ResourceGroups.Secondary)
if (@($groups | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -or @($groups | Select-Object -Unique).Count -ne 3) {
    throw 'Expected three distinct Terraform-resolved lab resource groups.'
}
$groupResources = @($resources | Where-Object { $_.address -in @('azurerm_resource_group.net', 'azurerm_resource_group.primary', 'azurerm_resource_group.secondary') })
if ($groupResources.Count -ne 3) { throw 'Expected resource groups are missing from Terraform state; resolve state before teardown.' }
$subscriptions = @($groupResources | ForEach-Object {
    if ($_.values.id -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)$' -or $Matches[2] -notin $groups) {
        throw 'Terraform resource group identity does not match the lab environment.'
    }
    $Matches[1]
} | Select-Object -Unique)
if ($subscriptions.Count -ne 1 -or $subscriptions[0] -ne $lab.SubscriptionId) {
    throw 'Active subscription does not match Terraform state; select the deployed subscription before continuing.'
}
$subscriptionId = $subscriptions[0]
foreach ($resource in $resources) {
    if ($resource.values.id -match '^/subscriptions/([^/]+)/resourceGroups/([^/]+)(?:/|$)') {
        if ($Matches[1] -ne $subscriptionId -or $Matches[2] -notin $groups) { throw 'Terraform state contains an out-of-scope resource; teardown refused.' }
    }
    elseif ($resource.values.id -match '^/subscriptions/') { throw 'Terraform state contains an unscoped subscription resource; teardown refused.' }
}

if ($Mode -eq 'Pause') {
    if (-not $lab.Jumpbox.name) { throw 'Expected jumpbox name is missing.' }
    Write-Host 'Deallocating jumpbox...' -ForegroundColor Cyan
    az vm deallocate --subscription $subscriptionId -g $lab.ResourceGroups.Primary -n $lab.Jumpbox.name --no-wait
    if ($LASTEXITCODE -ne 0) { throw "Jumpbox deallocation failed (exit $LASTEXITCODE)." }
    Write-Host @'
Jumpbox deallocating.

Note: this saves only the VM cost. The two Azure Firewalls, two vWAN hubs, Bastion,
and AI Search continue to bill. If you are done for more than a day, use -Mode Teardown.
'@ -ForegroundColor Yellow
    return
}

Write-Host 'Full teardown requested.' -ForegroundColor Red
$confirm = Read-Host 'Type DESTROY to confirm'
if ($confirm -ne 'DESTROY') {
    Write-Host 'Aborted.' -ForegroundColor Yellow
    return
}

$accountsToPurge = @(
    @{ Name = $lab.Primary.Account; Group = $lab.ResourceGroups.Primary; Address = 'module.foundry_primary.azapi_resource.foundry' },
    @{ Name = $lab.Secondary.Account; Group = $lab.ResourceGroups.Secondary; Address = 'module.foundry_secondary.azapi_resource.foundry' }
)
foreach ($target in $accountsToPurge) {
    $account = @($resources | Where-Object address -eq $target.Address)
    $expectedId = "/subscriptions/$subscriptionId/resourceGroups/$($target.Group)/providers/Microsoft.CognitiveServices/accounts/$($target.Name)"
    if (-not $target.Name -or $account.Count -ne 1 -or $account[0].values.id -ne $expectedId -or -not $account[0].values.location) {
        throw 'Expected account identity/location is missing or mismatched in Terraform state; teardown refused.'
    }
    $target.Location = $account[0].values.location
    $target.DeletedId = "/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/locations/$($target.Location)/resourceGroups/$($target.Group)/deletedAccounts/$($target.Name)"
}
Write-Host "  will purge: $($accountsToPurge.Name -join ', ')" -ForegroundColor DarkGray

Push-Location $TerraformDir
try {
    # The project capability host must be removed before the accounts, or the accounts
    # refuse to delete and the agent subnet stays linked.
    #
    # There is deliberately no account_capability_host target here. The platform renames
    # that child to "<account>@aml_aiagentservice", which is not addressable under the
    # name we submit, so it is not managed in Terraform. Purging the account is what
    # actually removes it.
    Write-Host 'Removing the project capability host...' -ForegroundColor Cyan
    terraform destroy '-target=module.foundry_primary.azapi_resource.project_capability_host'
    if ($LASTEXITCODE -ne 0) { throw "Capability host destroy failed (exit $LASTEXITCODE)." }

    Write-Host 'Deleting Foundry accounts...' -ForegroundColor Cyan
    terraform destroy `
        '-parallelism=1' `
        '-target=module.foundry_primary.azapi_resource.foundry' `
        '-target=module.foundry_secondary.azapi_resource.foundry'
    if ($LASTEXITCODE -ne 0) { throw "Account destroy failed (exit $LASTEXITCODE)." }
}
finally {
    Pop-Location
}

# A network-injected account can sit in Deleting for 15-20 minutes while it unwinds the
# serviceAssociationLink. Purging before it reaches a terminal state does nothing.
Write-Host 'Waiting for accounts to leave the Deleting state...' -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
foreach ($target in $accountsToPurge) {
    while ($true) {
        Assert-Deadline
        $live = Invoke-LabAz @('cognitiveservices', 'account', 'list', '--resource-group', $target.Group)
        if ($live -isnot [array]) { throw 'Invalid account list response.' }
        $account = @($live | Where-Object name -eq $target.Name)
        if (-not $account.Count) { break }
        if ($account[0].properties.provisioningState -ne 'Deleting') { throw "Account $($target.Name) is not deleting; teardown stopped." }
        Start-Sleep -Seconds 30
    }
}

# Purge must happen BEFORE the VNet is destroyed. A soft-deleted account keeps the
# serviceAssociationLink on the delegated agent subnet, which blocks VNet deletion.
Write-Host 'Purging soft-deleted Foundry accounts...' -ForegroundColor Cyan
foreach ($target in $accountsToPurge) {
    while ($true) {
        Assert-Deadline
        $deleted = Invoke-LabAz @('cognitiveservices', 'account', 'list-deleted')
        if ($deleted -isnot [array]) { throw 'Invalid deleted-account list response.' }
        $matching = @($deleted | Where-Object id -eq $target.DeletedId)
        if ($matching.Count -eq 1) { break }
        if ($matching.Count -gt 1) { throw 'Ambiguous deleted account identity; purge refused.' }
        Start-Sleep -Seconds 30
    }
    Assert-Deadline
    az cognitiveservices account purge --subscription $subscriptionId --location $target.Location --resource-group $target.Group --name $target.Name
    if ($LASTEXITCODE -ne 0) { throw "Purge failed for $($target.Name) (exit $LASTEXITCODE)." }
    do {
        Assert-Deadline
        $deleted = Invoke-LabAz @('cognitiveservices', 'account', 'list-deleted')
        if ($deleted -isnot [array]) { throw 'Invalid purge verification response.' }
        $remaining = @($deleted | Where-Object id -eq $target.DeletedId)
        if ($remaining.Count) { Start-Sleep -Seconds 30 }
    } while ($remaining.Count)
}

Assert-Deadline
Push-Location $TerraformDir
try {
    Write-Host 'Destroying remaining infrastructure...' -ForegroundColor Cyan
    Write-Host '  the two vWAN hubs and firewalls take 15-25 minutes.' -ForegroundColor DarkGray
    terraform destroy
    if ($LASTEXITCODE -ne 0) { throw "Infrastructure destroy failed (exit $LASTEXITCODE)." }
}
finally {
    Pop-Location
}

$stragglers = @(foreach ($group in $groups) {
    $exists = Invoke-LabAz @('group', 'exists', '--name', $group)
    if ($exists -isnot [bool]) { throw 'Invalid resource group existence response.' }
    if ($exists) {
        $remaining = Invoke-LabAz @('resource', 'list', '--resource-group', $group)
        if ($remaining -isnot [array]) { throw 'Invalid residual resource response.' }
        $remaining
    }
})
if ($stragglers) {
    Write-Host "Teardown finished but $($stragglers.Count) resource(s) remain:" -ForegroundColor Yellow
    $stragglers | Select-Object name, type, resourceGroup | Format-Table -AutoSize
    throw 'Teardown incomplete: resources remain in the exact lab resource groups.'
}
else {
    Write-Host 'Teardown complete. No lab resources remain.' -ForegroundColor Green
    [pscustomobject]@{ Outcome = 'Succeeded'; SubscriptionId = $subscriptionId; ResourceGroups = $groups }
}
