<#
.SYNOPSIS
    One-time beads backlog bootstrap for the funwithfoundry lab.
.DESCRIPTION
    Creates the phase epics, their child tasks, and the blocking edges between
    phases. Idempotency is NOT attempted - run once on a fresh bd database.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function New-Bead {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Type = 'task',
        [int]$Priority = 2,
        [string]$Description = '',
        [string]$Parent
    )
    $cliArgs = @('create', $Title, '-t', $Type, '-p', "$Priority", '--json')
    if ($Description) { $cliArgs += @('-d', $Description) }
    if ($Parent)      { $cliArgs += @('--parent', $Parent) }

    $raw = & bd @cliArgs 2>$null
    $json = ($raw | Where-Object { $_ -notmatch '^NOTE:' }) -join "`n"
    $obj = $json | ConvertFrom-Json
    if (-not $obj.id) { throw "Failed to create bead: $Title" }
    Write-Host ("  {0}  {1}" -f $obj.id.PadRight(24), $Title) -ForegroundColor DarkGray
    return $obj.id
}

$epics = [ordered]@{}

Write-Host "`nCreating phase epics..." -ForegroundColor Cyan

# P0 already exists - locate it rather than duplicating.
$existing = (& bd list --json 2>$null | Where-Object { $_ -notmatch '^NOTE:' }) -join "`n" | ConvertFrom-Json
$p0 = $existing | Where-Object { $_.title -like 'P0 Gate*' } | Select-Object -First 1
if (-not $p0) { throw 'P0 epic not found - expected it to exist already.' }
$epics['P0'] = $p0.id
Write-Host ("  {0}  {1} (existing)" -f $p0.id.PadRight(24), $p0.title) -ForegroundColor DarkGray

$epics['P1'] = New-Bead -Title 'P1 Workspace: repo scaffold, beads, plan persistence' -Type epic -Priority 0 `
    -Description 'Create repo structure, initialise beads, persist the architecture plan into repo memory.'
$epics['P2'] = New-Bead -Title 'P2 Network: secured vWAN, spokes, private DNS, Bastion, jumpbox' -Type epic -Priority 0 `
    -Description 'Virtual WAN Standard with Azure Firewall in both hubs, two spokes, private DNS zones linked to both, Bastion Standard and Windows jumpbox.'
$epics['P3'] = New-Bead -Title 'P3 Foundry Central US: private network-injected agent platform' -Type epic -Priority 0 `
    -Description 'BYO Storage/Cosmos/Search/KeyVault with private endpoints, Foundry account with network injection, project, capability hosts, RBAC.'
$epics['P4'] = New-Bead -Title 'P4 Foundry South Central US: Content Understanding' -Type epic -Priority 1 `
    -Description 'AIServices account with private endpoint, project, gpt-5.2 and text-embedding-3-large deployments, private staging storage.'
$epics['P5'] = New-Bead -Title 'P5 Validate the private path end to end' -Type epic -Priority 1 `
    -Description 'DNS resolution, public access disabled everywhere, capability hosts succeeded, cross-region transit proven.'
$epics['P6'] = New-Bead -Title 'P6 Workload: SharePoint -> Content Understanding -> AI Search -> Foundry IQ' -Type epic -Priority 1 `
    -Description 'VNet-integrated Flex Consumption Function driving the ingestion pipeline across the vWAN.'
$epics['P7'] = New-Bead -Title 'P7 Hello world, docs, and teardown' -Type epic -Priority 2 `
    -Description 'Agent wired to the knowledge base, architecture diagram, stop/destroy tooling.'

Write-Host "`nCreating child tasks..." -ForegroundColor Cyan

# --- P0 (retrospective - work already done) ---
$p0Tasks = @(
    @{ t = 'PIM elevate to Owner'; d = 'Owner required for roleAssignments/write in the standard agent setup.' }
    @{ t = 'Run capacity and SKU preflight in both regions'; d = 'scripts/Test-Preflight.ps1 - 51 PASS / 0 FAIL / 0 WARN.' }
)
$p0Ids = @()
foreach ($x in $p0Tasks) { $p0Ids += New-Bead -Title $x.t -Priority 0 -Description $x.d -Parent $epics['P0'] }

# --- P1 ---
$p1 = @(
    'Scaffold repo structure (terraform/, scripts/, src/, docs/)',
    'Initialise beads and load the phase backlog',
    'Persist architecture plan to repo memory',
    'Write README with the SharePoint-is-not-private caveat stated plainly'
)
foreach ($t in $p1) { [void](New-Bead -Title $t -Priority 0 -Parent $epics['P1']) }

# --- P2 ---
$p2 = @(
    @{ t = 'Terraform root: providers, locals, variables, tfvars example'; d = 'azurerm ~>4, azapi ~>2, azuread, random. Local state.' }
    @{ t = 'Module: vwan-secured (Standard vWAN, 2 hubs, AzFW Standard, routing intent)'; d = 'Hub CUS 10.100.0.0/23, hub SCUS 10.101.0.0/23. Hub-to-hub transit is automatic on Standard.' }
    @{ t = 'Module: spoke-cus (10.10.0.0/16)'; d = 'snet-agent /24 delegated Microsoft.App/environments, snet-pe /24, snet-jumpbox /24, AzureBastionSubnet /26.' }
    @{ t = 'Module: spoke-scus (10.20.0.0/16)'; d = 'snet-pe /24, snet-func /24 delegated Microsoft.App/environments.' }
    @{ t = 'Module: private-dns - all zones linked to BOTH spokes'; d = 'Zones are global; cross-region VNet links avoid needing a DNS Private Resolver.' }
    @{ t = 'Module: jumpbox-bastion (Win2025 + Bastion Standard)'; d = 'Route table on AzureBastionSubnet with 0.0.0.0/0 -> Internet to override routing intent, or Bastion breaks.' }
    @{ t = 'Firewall policy: ACA egress FQDN allowlist, no TLS inspection'; d = 'Container Apps Managed Identity FQDN set + AzureActiveDirectory tag. TLS inspection breaks agent provisioning.' }
)
foreach ($x in $p2) { [void](New-Bead -Title $x.t -Priority 0 -Description $x.d -Parent $epics['P2']) }

# --- P3 ---
$p3 = @(
    @{ t = 'BYO dependencies + private endpoints (Storage, Cosmos 6000 RU/s, Search S1, Key Vault)'; d = 'PEs to Search/Storage/Cosmos are NOT auto-created. Cosmos needs 5 containers x 1000 RU/s.' }
    @{ t = 'Foundry account with networkInjections and publicNetworkAccess Disabled'; d = 'Network injection MUST be set at account creation. Cannot be added later for hosted agents.' }
    @{ t = 'Project, connections, and model deployments'; d = 'gpt-5.2 for the agent and the Foundry IQ query planner; text-embedding-3-large for vectorization.' }
    @{ t = 'Account and project capability hosts'; d = 'Immutable once created - a change means deleting and recreating the project.' }
    @{ t = 'RBAC grants for the project managed identity'; d = 'Cosmos DB Operator, Storage Account Contributor, Search Index Data Contributor, Search Service Contributor, Storage Blob Data Contributor on azureml-blobstore, Storage Blob Data Owner on agents-blobstore, Cosmos DB Built-in Data Contributor on enterprise_memory.' }
)
foreach ($x in $p3) { [void](New-Bead -Title $x.t -Priority 0 -Description $x.d -Parent $epics['P3']) }

# --- P4 ---
$p4 = @(
    @{ t = 'AIServices account + private endpoint + project (SCUS)'; d = 'No agent subnet and no capability host needed - Content Understanding only.' }
    @{ t = 'Model deployments for Content Understanding'; d = 'CU requires BYO generative + embedding deployments.' }
    @{ t = 'Private staging storage account + blob private endpoint'; d = 'Landing zone for the SharePoint document before analysis.' }
    @{ t = 'RISK: prove Content Understanding is actually enabled in South Central US'; d = 'AIServices S0 availability does NOT prove CU availability - docs never list CU regions. Definitively proven only by creating an analyzer. Fallback: West US / Sweden Central / East US.' }
)
foreach ($x in $p4) { [void](New-Bead -Title $x.t -Priority 1 -Description $x.d -Parent $epics['P4']) }

# --- P5 ---
$p5 = @(
    'nslookup every private endpoint FQDN from the jumpbox',
    'Confirm publicNetworkAccess Disabled on every resource',
    'Confirm both capability hosts report Succeeded',
    'Prove hub-to-hub transit: SCUS function subnet -> CUS Search private IP',
    'Confirm a public workstation is refused'
)
foreach ($t in $p5) { [void](New-Bead -Title $t -Priority 1 -Parent $epics['P5']) }

# --- P6 ---
$p6 = @(
    @{ t = 'Flex Consumption Function, VNet-integrated, user-assigned MI'; d = 'Subnet delegated to Microsoft.App/environments.' }
    @{ t = 'Grant Graph app role to the function managed identity'; d = 'Sites.Selected or Files.Read.All. Needs tenant admin consent. Fallback: app registration + secret in Key Vault.' }
    @{ t = 'Ingestion: SharePoint -> private blob'; d = 'The Graph fetch is a public-internet call egressing via Azure Firewall. The private boundary starts here.' }
    @{ t = 'Content Understanding via analyzeBinary (NOT the URL-reference analyze API)'; d = 'The file-reference API has the CU service fetch the blob URL itself, which is impossible against private storage.' }
    @{ t = 'Push extracted content into the CUS AI Search index across the vWAN'; d = 'This is the step that actually exercises the inter-region private link.' }
    @{ t = 'Create Foundry IQ knowledge source + knowledge base'; d = 'REST API only - not available in azurerm. Post-deploy script.' }
)
foreach ($x in $p6) { [void](New-Bead -Title $x.t -Priority 1 -Description $x.d -Parent $epics['P6']) }

# --- P7 ---
$p7 = @(
    @{ t = 'Wire the agent to the knowledge base and query it from the jumpbox'; d = '' }
    @{ t = 'Architecture diagram and README'; d = 'Must state that SharePoint Online itself is never private.' }
    @{ t = 'Stop-Lab.ps1 and teardown guidance'; d = 'Delete AND purge Foundry accounts before the VNet - the serviceAssociationLink on the agent subnet blocks VNet deletion otherwise.' }
)
foreach ($x in $p7) { [void](New-Bead -Title $x.t -Priority 2 -Description $x.d -Parent $epics['P7']) }

Write-Host "`nWiring phase dependencies..." -ForegroundColor Cyan
$edges = @(
    @{ from = 'P1'; to = 'P0' },
    @{ from = 'P2'; to = 'P1' },
    @{ from = 'P3'; to = 'P2' },
    @{ from = 'P4'; to = 'P2' },
    @{ from = 'P5'; to = 'P3' },
    @{ from = 'P5'; to = 'P4' },
    @{ from = 'P6'; to = 'P5' },
    @{ from = 'P7'; to = 'P6' }
)
foreach ($e in $edges) {
    & bd dep add $epics[$e.from] $epics[$e.to] | Out-Null
    Write-Host ("  {0} blocked by {1}" -f $e.from, $e.to) -ForegroundColor DarkGray
}

Write-Host "`nBacklog created." -ForegroundColor Green
$epics.GetEnumerator() | ForEach-Object { Write-Host ("  {0} = {1}" -f $_.Key, $_.Value) }
