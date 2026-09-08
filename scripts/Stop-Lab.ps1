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

    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform')
)

$ErrorActionPreference = 'Stop'

if ($Mode -eq 'Pause') {
    Write-Host 'Deallocating jumpbox...' -ForegroundColor Cyan
    az vm deallocate -g rg-fwf-cus -n vm-fwf-cus-jump --no-wait
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

# Resolve names up front: once the accounts are destroyed, terraform output can no
# longer tell us what to wait on and purge.
$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir
$accountsToPurge = @(
    @{ Name = $lab.Primary.Account; Group = $lab.ResourceGroups.Primary },
    @{ Name = $lab.Secondary.Account; Group = $lab.ResourceGroups.Secondary }
)
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
    terraform destroy -target='module.foundry_primary.azapi_resource.project_capability_host' -auto-approve -input=false

    # Delete the Foundry accounts ahead of the rest of the graph so the purge below can run
    # while the network is still standing. A failure here is tolerated: the account is
    # often already mid-delete, which surfaces as a non-terminal provisioning state.
    Write-Host 'Deleting Foundry accounts...' -ForegroundColor Cyan
    terraform destroy `
        -target='module.foundry_primary.azapi_resource.foundry' `
        -target='module.foundry_secondary.azapi_resource.foundry' `
        -auto-approve -input=false
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  delete reported an error; continuing to the wait below.' -ForegroundColor Yellow
    }
}
finally {
    Pop-Location
}

# A network-injected account can sit in Deleting for 15-20 minutes while it unwinds the
# serviceAssociationLink. Purging before it reaches a terminal state does nothing.
Write-Host 'Waiting for accounts to leave the Deleting state...' -ForegroundColor Cyan
foreach ($target in $accountsToPurge) {
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        $state = az cognitiveservices account show -n $target.Name -g $target.Group `
            --query 'properties.provisioningState' -o tsv 2>$null
        if (-not $state) { break }
        Write-Host "  $($target.Name) state=$state"
        Start-Sleep -Seconds 30
    }
}

# Purge must happen BEFORE the VNet is destroyed. A soft-deleted account keeps the
# serviceAssociationLink on the delegated agent subnet, which blocks VNet deletion.
Write-Host 'Purging soft-deleted Foundry accounts...' -ForegroundColor Cyan
$deleted = az cognitiveservices account list-deleted -o json | ConvertFrom-Json
foreach ($acct in $deleted) {
    if ($acct.name -notlike 'fwf*') { continue }
    # The deleted-account id carries the original resource group. The resourceGroup
    # property on this payload is the provider namespace, not the spoke group.
    $rg = ($acct.id -split '/')[8]
    Write-Host "  purging $($acct.name) in $($acct.location) (rg $rg)"
    az cognitiveservices account purge --location $acct.location --resource-group $rg --name $acct.name
}

Push-Location $TerraformDir
try {
    Write-Host 'Destroying remaining infrastructure...' -ForegroundColor Cyan
    Write-Host '  the two vWAN hubs and firewalls take 15-25 minutes.' -ForegroundColor DarkGray
    terraform destroy -auto-approve -input=false
}
finally {
    Pop-Location
}

$stragglers = az resource list -o json | ConvertFrom-Json | Where-Object { $_.resourceGroup -like '*fwf*' }
if ($stragglers) {
    Write-Host "Teardown finished but $($stragglers.Count) resource(s) remain:" -ForegroundColor Yellow
    $stragglers | Select-Object name, type, resourceGroup | Format-Table -AutoSize
}
else {
    Write-Host 'Teardown complete. No lab resources remain.' -ForegroundColor Green
}
