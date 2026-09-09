<#
.SYNOPSIS
    Ensure the Foundry account-level Agents capability host exists and is ready.
.DESCRIPTION
    Azure stores this singleton under a platform-generated name, so Terraform cannot
    manage its lifecycle reliably. This script is idempotent and resolves the account
    and injected subnet from Terraform outputs.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [timespan]$Timeout = [timespan]::FromMinutes(30)
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '2025-04-01-preview'

function Invoke-AzRestJson {
    param(
        [ValidateSet('get', 'put')]
        [string]$Method,
        [string]$Url,
        [string]$Body
    )

    $cliArguments = @('rest', '--method', $Method, '--url', $Url, '-o', 'json')
    if ($Body) {
        $cliArguments += @('--body', $Body)
    }

    $raw = & az @cliArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure REST $Method failed for '$Url'."
    }

    if ($raw) {
        return $raw | ConvertFrom-Json
    }
}

$terraformChdir = "-chdir=$TerraformDir"

$accountId = terraform $terraformChdir output -raw foundry_primary_account_id
if ($LASTEXITCODE -ne 0 -or -not $accountId) {
    throw 'Could not resolve foundry_primary_account_id. Apply the primary Foundry account first.'
}

$agentSubnetId = terraform $terraformChdir output -raw foundry_agent_subnet_id
if ($LASTEXITCODE -ne 0 -or -not $agentSubnetId) {
    throw 'Could not resolve foundry_agent_subnet_id. Apply the primary spoke first.'
}
$agentSubnetName = ($agentSubnetId.TrimEnd('/') -split '/')[-1]
if ($agentSubnetName.Length -gt 62) {
    throw "Foundry agent subnet name '$agentSubnetName' is $($agentSubnetName.Length) characters; capability-host creation requires 62 or fewer."
}

$collectionUrl = "https://management.azure.com$accountId/capabilityHosts?api-version=$ApiVersion"
$deadline = (Get-Date).Add($Timeout)

do {
    $account = Invoke-AzRestJson -Method get -Url "https://management.azure.com$accountId`?api-version=2025-06-01"
    if ($account.properties.provisioningState -eq 'Succeeded') {
        break
    }

    if ((Get-Date) -ge $deadline) {
        throw "Foundry account did not reach Succeeded within $($Timeout.TotalMinutes) minutes."
    }

    Write-Host "Foundry account state=$($account.properties.provisioningState); waiting..."
    Start-Sleep -Seconds 30
} while ($true)

$hosts = @(Invoke-AzRestJson -Method get -Url $collectionUrl).value
$agentHost = $hosts | Where-Object { $_.properties.capabilityHostKind -eq 'Agents' } | Select-Object -First 1

if (-not $agentHost) {
    $body = @{
        properties = @{
            capabilityHostKind = 'Agents'
            customerSubnet     = $agentSubnetId
        }
    } | ConvertTo-Json -Depth 5 -Compress

    Write-Host 'Creating account-level Agents capability host...'
    $createUrl = "https://management.azure.com$accountId/capabilityHosts/caphostacct?api-version=$ApiVersion"
    $agentHost = Invoke-AzRestJson -Method put -Url $createUrl -Body $body
}
else {
    Write-Host "Account-level Agents capability host already exists: $($agentHost.name)"
}

do {
    $hosts = @(Invoke-AzRestJson -Method get -Url $collectionUrl).value
    $agentHost = $hosts | Where-Object { $_.properties.capabilityHostKind -eq 'Agents' } | Select-Object -First 1
    $state = $agentHost.properties.provisioningState

    if ($state -eq 'Succeeded') {
        Write-Host "Account-level Agents capability host ready: $($agentHost.name)"
        return
    }

    if ($state -eq 'Failed') {
        throw "Account-level Agents capability host failed: $($agentHost.name)"
    }

    if ((Get-Date) -ge $deadline) {
        throw "Account-level Agents capability host did not reach Succeeded within $($Timeout.TotalMinutes) minutes."
    }

    Write-Host "Account capability host state=$state; waiting..."
    Start-Sleep -Seconds 30
} while ($true)
