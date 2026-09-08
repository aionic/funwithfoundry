# funwithfoundry

A fully private Microsoft Foundry lab spanning two Azure regions, joined by a secured Virtual WAN.

- **Central US** — network-injected private agent platform (hosted agents + Foundry IQ)
- **South Central US** — Content Understanding
- **Virtual WAN Standard**, Azure Firewall in both hubs, routing intent forcing private *and*
  internet traffic through the firewall
- **Windows Server 2025 jumpbox** behind **Bastion Standard** - the only human entry point

Terraform owns the infrastructure and project capability host. Small post-deploy scripts handle the
platform-renamed account capability host, private Function package deployment, shared private-link
approval, and Foundry IQ data-plane objects.

## Deployment status

Verified on 2026-09-08:

- Terraform converged with zero drift after deployment.
- `scripts/Verify-Deployment.ps1` returned 24 PASS, 0 WARN, 0 FAIL.
- Account and project `Agents` capability hosts reached `Succeeded`.
- The Function package deployed and its `ingest` trigger synchronized.
- Private DNS, cross-region HTTPS, Content Understanding, AI Search indexing, Foundry IQ grounded
  retrieval, and a hosted `gpt-4o` agent using `azure_ai_search` all completed successfully.

The SharePoint Graph fetch and an interactive Bastion RDP session remain untested. The synthetic
end-to-end test starts with a generated document on the jumpbox.

## Prerequisites

- Terraform 1.9 or later
- Azure CLI authenticated to the target tenant and subscription
- PowerShell 7
- Python 3.12 or later for the Foundry IQ setup and query scripts
- Azure permissions to create role assignments and the resources in this architecture

Review the [architecture](docs/architecture.md), [runtime-flow diagram](docs/diagrams/runtime-flow-azure-architecture.mmd),
and [implementation plan](docs/PLAN.md) before deploying. The default topology is intentionally
expensive and creates public-internet egress for SharePoint through Azure Firewall.

## The honest caveat

**SharePoint Online is never private.** The Microsoft Graph call that fetches the document is a
public-internet call, egressing through Azure Firewall like any other outbound traffic. Nothing in
this lab changes that, and no amount of private networking can.

What *is* private is everything after that fetch: the blob that receives the bytes, the Content
Understanding endpoint that analyses them, the AI Search index that stores the result, the Foundry
account that serves it, and the cross-region hop between the two regions. The private boundary
starts at the Function, and this repo is explicit about where that line sits.

## The showcase

The intended ingestion flow is SharePoint to the VNet-integrated Function, private staging storage,
Content Understanding in South Central US, and AI Search in Central US across the secured vWAN.
Foundry IQ and the hosted agent then retrieve from Search privately. See the
[runtime flow](docs/diagrams/runtime-flow-azure-architecture.mmd) and
[capability-host deployment flow](docs/diagrams/capability-host-deployment-azure-architecture.mmd).

The cross-region push is the point. It is what proves hub-to-hub transit actually works, rather
than leaving the vWAN as expensive decoration.

## Layout

| Path | Purpose |
|---|---|
| `terraform/` | Single root; local modules under `terraform/modules/` |
| `scripts/` | Preflight, backlog bootstrap, RBAC, Foundry IQ setup, teardown |
| `src/ingest_func/` | Flex Consumption Function driving the ingestion pipeline |
| `src/hello_world/` | Agent query client |
| `docs/diagrams/` | Reviewable Mermaid architecture contracts |
| `docs/PLAN.md` | Architecture, address plan, and the hard constraints |

## Getting started

```powershell
# 1. Elevate (Owner is required for the agent-setup role assignments)
& "$env:USERPROFILE\Scripts\Invoke-PimElevation.ps1" -Action Elevate -Role Owner -Duration PT8H

# 2. Gate on capacity before spending anything
pwsh -NoProfile -File .\scripts\Test-Preflight.ps1

# 3. Initialize
Copy-Item .\terraform\terraform.tfvars.example .\terraform\terraform.tfvars
terraform -chdir=terraform init

# 4. Create the network-injected account and its dependencies first
terraform -chdir=terraform apply -target='module.foundry_primary.azapi_resource.foundry'

# Azure stores the account-level Agents capability host under a platform-generated
# name, so this idempotent helper owns that one control-plane operation.
pwsh -NoProfile -File .\scripts\Ensure-AgentCapabilityHost.ps1

# 5. Complete the graph, including the project-level Agents capability host
terraform -chdir=terraform apply

# 6. Approve Search's outbound shared private link and deploy Function code
pwsh -NoProfile -File .\scripts\Approve-SharedPrivateLink.ps1
pwsh -NoProfile -File .\scripts\Deploy-IngestFunction.ps1
```

The `azurerm` provider already sets `storage_use_azuread = true`. Storage, Cosmos DB, Foundry,
and AI Search disable local or shared-key authentication; deployment and runtime scripts use Entra
tokens and managed identities.

## Verify

Run the orchestration commands from the repository root. `Invoke-JumpboxScript.ps1` resolves random
resource suffixes and runs the selected check inside the private VNet using VM Run Command.

```powershell
pwsh -NoProfile -File .\scripts\Verify-Deployment.ps1
pwsh -NoProfile -File .\scripts\Invoke-JumpboxScript.ps1 -Script Test-PrivatePath.ps1
pwsh -NoProfile -File .\scripts\Invoke-JumpboxScript.ps1 -Script Invoke-EndToEnd.ps1
pwsh -NoProfile -File .\scripts\Invoke-JumpboxScript.ps1 -Script Invoke-FoundryAgent.ps1
```

`Invoke-EndToEnd.ps1` uses a generated document and proves Content Understanding to Search to
Foundry IQ. It does not prove the SharePoint Graph leg. `Invoke-FoundryAgent.ps1` uses `gpt-4o`
because `gpt-5.2` currently fails when the `azure_ai_search` tool is attached, although it works as
the Foundry IQ knowledge-base planner.

Retrieve the jumpbox password only when interactive RDP is needed:

```powershell
terraform -chdir=terraform output -raw jumpbox_admin_password
```

## Cost warning

Two Azure Firewalls, two vWAN hubs, Bastion Standard, AI Search S1, Cosmos, and a VM put this in the
high hundreds to over $1,000 per month. This is a lab, not a deployment you leave running. See
`scripts/Stop-Lab.ps1` and the teardown notes in `docs/PLAN.md`.

**Teardown order matters:** delete *and purge* the Foundry accounts before the VNet. The
`serviceAssociationLink` on the agent subnet will otherwise block VNet deletion.

## Deliberate scope limits

This is a lab. No customer-managed keys, no Azure Monitor Private Link Scope, no multi-region
failover, no CI/CD, and no production SLO are included. Those are deliberate omissions, not
oversights.

## Security

Terraform state, variable files, plans, deployment logs, and preflight results are intentionally
excluded from version control because they can contain credentials or deployment identifiers. See
[SECURITY.md](SECURITY.md) for reporting guidance.

## License

Licensed under the [MIT License](LICENSE).
