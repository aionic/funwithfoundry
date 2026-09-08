<#
.SYNOPSIS
    Run a scripts/jumpbox script on the jumpbox with resolved resource names injected.
.DESCRIPTION
    Terraform is not available on the jumpbox, and the random name suffix changes on
    every rebuild. This prepends a generated variable block to the script body so the
    jumpbox scripts never carry hardcoded names.

    Injected variables: $FoundryAccount, $FoundryProject, $SearchName, $StorageName,
    $CuAccount, $StagingStorage, and the matching $Fqdn* hostnames.
.EXAMPLE
    .\scripts\Invoke-JumpboxScript.ps1 Test-PrivatePath.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Script,
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform')
)

$ErrorActionPreference = 'Stop'

$path = if (Test-Path $Script) { $Script } else { Join-Path $PSScriptRoot "jumpbox\$Script" }
if (-not (Test-Path $path)) { throw "Jumpbox script not found: $Script" }

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir

$prelude = @"
# --- injected by Invoke-JumpboxScript.ps1 (do not hardcode names) ---
`$FoundryAccount = '$($lab.Primary.Account)'
`$FoundryProject = '$($lab.Primary.Project)'
`$SearchName     = '$($lab.Primary.Search)'
`$StorageName    = '$($lab.Primary.Storage)'
`$CuAccount      = '$($lab.Secondary.Account)'
`$StagingStorage = '$($lab.Secondary.StagingStorage)'
`$FqdnFoundrySvc = '$($lab.Hosts.FoundryServices)'
`$FqdnFoundryCog = '$($lab.Hosts.FoundryCogSvc)'
`$FqdnFoundryOAI = '$($lab.Hosts.FoundryOpenAI)'
`$FqdnSearch     = '$($lab.Hosts.Search)'
`$FqdnStorage    = '$($lab.Hosts.Storage)'
`$FqdnCosmos     = '$($lab.Hosts.Cosmos)'
`$FqdnKeyVault   = '$($lab.Hosts.KeyVault)'
`$FqdnCu         = '$($lab.Hosts.ContentUnderstanding)'
`$FqdnCuOpenAI   = '$($lab.Secondary.Account).openai.azure.com'
`$FqdnStaging    = '$($lab.Hosts.StagingStorage)'
`$SpHostname     = '$($lab.SharePoint.Hostname)'
`$SpSitePath     = '$($lab.SharePoint.SitePath)'
`$SpFilePath     = '$($lab.SharePoint.FilePath)'
`$FunctionApp    = '$($lab.Function.Name)'
`$FunctionHost   = '$($lab.Function.Hostname)'
`$ProjectEndpoint = '$($lab.Primary.ProjectEndpoint)'
`$SearchIndex    = 'spo-docs'
`$AgentToolModel = '$($lab.Primary.AgentToolModel)'
# --- end injected block ---

"@

$tmp = Join-Path $env:TEMP ('jumpbox-' + [System.IO.Path]::GetFileName($path))
Set-Content -Path $tmp -Value ($prelude + (Get-Content $path -Raw)) -Encoding UTF8

Write-Host "Running $([System.IO.Path]::GetFileName($path)) on $($lab.Jumpbox.name)..." -ForegroundColor Cyan
az vm run-command invoke `
    --resource-group $lab.ResourceGroups.Primary `
    --name $lab.Jumpbox.name `
    --command-id RunPowerShellScript `
    --scripts "@$tmp" `
    --query 'value[0].message' -o tsv
