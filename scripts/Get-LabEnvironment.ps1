<#
.SYNOPSIS
    Resolve deployed lab resource names from Terraform outputs.
.DESCRIPTION
    Single source of truth for resource names. The name suffix is randomly generated,
    so it changes on every rebuild - scripts must never hardcode it.

    Returns an object with names, endpoints, ARM ids, and the private hostname list.
    Use -AsJsonPath to emit a JSON copy for scripts that run on the jumpbox, where
    Terraform is not available.
.EXAMPLE
    $lab = .\scripts\Get-LabEnvironment.ps1
    $lab.Primary.Account
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [string]$AsJsonPath
)

$ErrorActionPreference = 'Stop'

Push-Location $TerraformDir
try {
    $raw = terraform output -json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw "terraform output failed in '$TerraformDir'. Is the lab deployed?"
    }
}
finally {
    Pop-Location
}

$o = $raw | ConvertFrom-Json

# Outputs carry no subscription id of their own; take it from the signed-in context.
$subId = az account show --query id -o tsv
if (-not $subId) { throw 'Could not resolve the subscription id from the Azure CLI context.' }

$rg = $o.resource_groups.value
$p = $o.foundry_primary.value
$s = $o.foundry_secondary.value

$armBase = "/subscriptions/$subId/resourceGroups/$($rg.primary)/providers"

$lab = [pscustomobject]@{
    SubscriptionId     = $subId
    ResourceGroups     = [pscustomobject]@{
        Network   = $rg.network
        Primary   = $rg.primary
        Secondary = $rg.secondary
    }
    Primary            = [pscustomobject]@{
        Account         = $p.account
        Project         = $p.project
        Search          = $p.search
        Cosmos          = $p.cosmos
        KeyVault        = $p.key_vault
        Storage         = $p.storage
        ProjectEndpoint = $p.project_endpoint
        SearchEndpoint  = $p.search_endpoint
        AgentToolModel  = $p.agent_tool_model
    }
    Secondary          = [pscustomobject]@{
        Account        = $s.account
        Project        = $s.project
        StagingStorage = $s.staging_storage
        Endpoint       = $s.endpoint
    }
    FoundryId          = "$armBase/Microsoft.CognitiveServices/accounts/$($p.account)"
    SearchId           = "$armBase/Microsoft.Search/searchServices/$($p.search)"
    SecondaryFoundryId = "/subscriptions/$subId/resourceGroups/$($rg.secondary)/providers/Microsoft.CognitiveServices/accounts/$($s.account)"
    FirewallPrivateIps = $o.firewall_private_ips.value
    Jumpbox            = $o.jumpbox.value
    SharePoint         = [pscustomobject]@{
        Hostname = $o.sharepoint.value.hostname
        SitePath = $o.sharepoint.value.site_path
        FilePath = $o.sharepoint.value.file_path
    }
    Function           = [pscustomobject]@{
        Name           = $o.ingest_function.value.name
        Hostname       = $o.ingest_function.value.hostname
        IdentityClient = $o.ingest_function.value.identity_client
        IdentityObject = $o.ingest_function.value.identity_object
    }
    Hosts              = [pscustomobject]@{
        FoundryServices = "$($p.account).services.ai.azure.com"
        FoundryCogSvc   = "$($p.account).cognitiveservices.azure.com"
        FoundryOpenAI   = "$($p.account).openai.azure.com"
        Search          = "$($p.search).search.windows.net"
        Storage         = "$($p.storage).blob.core.windows.net"
        Cosmos          = "$($p.cosmos).documents.azure.com"
        KeyVault        = "$($p.key_vault).vault.azure.net"
        ContentUnderstanding = "$($s.account).cognitiveservices.azure.com"
        StagingStorage  = "$($s.staging_storage).blob.core.windows.net"
    }
}

if ($AsJsonPath) {
    $lab | ConvertTo-Json -Depth 10 | Set-Content -Path $AsJsonPath -Encoding UTF8
    Write-Verbose "Wrote lab environment to $AsJsonPath"
}

$lab
