# Waits for the Search shared private link connection to appear on the Foundry account,
# then approves it. Shared private links land in Pending and never complete on their own.
[CmdletBinding()]
param(
    [string]$FoundryId,
    [string]$SearchId,
    [int]$MaxAttempts = 30
)

$ErrorActionPreference = 'Continue'

# The name suffix is regenerated on every rebuild, so resolve rather than hardcode.
if (-not $FoundryId -or -not $SearchId) {
    $lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1')
    if (-not $FoundryId) { $FoundryId = $lab.FoundryId }
    if (-not $SearchId) { $SearchId = $lab.SearchId }
}
$cogApi = '2025-06-01'
$searchApi = '2025-05-01'

for ($i = 1; $i -le $MaxAttempts; $i++) {
    $conns = az rest --method get `
        --url "https://management.azure.com$FoundryId/privateEndpointConnections?api-version=$cogApi" -o json | ConvertFrom-Json

    $pending = $conns.value | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq 'Pending' }

    if ($pending) {
        foreach ($p in $pending) {
            # The API returns the name as "<account>/<connection>"; the PUT path needs
            # only the child segment or the URL becomes invalid.
            $childName = ($p.name -split '/')[-1]
            Write-Host "Approving $childName" -ForegroundColor Cyan
            $body = @{
                properties = @{
                    privateLinkServiceConnectionState = @{
                        status      = 'Approved'
                        description = 'Approved for Foundry IQ query planner'
                    }
                }
            } | ConvertTo-Json -Depth 10 -Compress

            $tmp = Join-Path $env:TEMP 'approve.json'
            [System.IO.File]::WriteAllText($tmp, $body)

            az rest --method put `
                --url "https://management.azure.com$FoundryId/privateEndpointConnections/$childName`?api-version=$cogApi" `
                --body "@$tmp" -o none
            Write-Host "  approved" -ForegroundColor Green
        }
        break
    }

    $spl = az rest --method get --url "https://management.azure.com$SearchId/sharedPrivateLinkResources?api-version=$searchApi" -o json | ConvertFrom-Json
    $status = ($spl.value | Where-Object name -eq 'spl-foundry').properties.status
    Write-Host "[$i/$MaxAttempts] no pending connection yet (shared link status: $status)"
    Start-Sleep -Seconds 20
}

Write-Host ""
Write-Host "=== Final state ===" -ForegroundColor Cyan
az rest --method get --url "https://management.azure.com$SearchId/sharedPrivateLinkResources?api-version=$searchApi" `
    --query "value[].{name:name,group:properties.groupId,status:properties.status,prov:properties.provisioningState}" -o table
