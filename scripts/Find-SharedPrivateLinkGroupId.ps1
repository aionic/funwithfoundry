# Finds the valid groupId for a Search shared private link to the Foundry account.
$ErrorActionPreference = 'Continue'

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1')
$searchId = $lab.SearchId
$foundryId = $lab.FoundryId
$api = '2025-05-01'

Write-Host "=== Private link resources exposed by the Foundry account ==="
az rest --method get --url "https://management.azure.com$foundryId/privateLinkResources?api-version=2025-06-01" `
    --query "value[].{groupId:properties.groupId,members:properties.requiredMembers}" -o table

foreach ($gid in @('account', 'openai_account', 'cognitiveservices_account')) {
    Write-Host ""
    Write-Host "=== Trying groupId '$gid' ==="
    $body = @{
        properties = @{
            privateLinkResourceId = $foundryId
            groupId               = $gid
            requestMessage        = 'Foundry IQ query planner'
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $tmp = Join-Path $env:TEMP "spl-$gid.json"
    [System.IO.File]::WriteAllText($tmp, $body)

    $out = az rest --method put `
        --url "https://management.azure.com$searchId/sharedPrivateLinkResources/spl-foundry?api-version=$api" `
        --body "@$tmp" 2>&1
    $text = ($out | Out-String)
    if ($text.Length -gt 700) { $text = $text.Substring(0, 700) }
    Write-Host $text
    if ($text -notmatch 'BadRequest|ERROR|error') { Write-Host "  SUCCESS with groupId '$gid'"; break }
}
