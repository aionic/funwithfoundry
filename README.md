# funwithfoundry

A fully private Microsoft Foundry lab spanning two Azure regions, joined by a secured Virtual WAN.

- **Central US** — network-injected private agent platform (hosted agents + Foundry IQ)
- **South Central US** — Content Understanding
- **Virtual WAN Standard**, Azure Firewall in both hubs, routing intent forcing private *and*
  internet traffic through the firewall
- **Windows Server 2025 jumpbox** behind **Bastion Standard** — the only human entry point

Everything is Terraform. Work is tracked in [beads](https://beads.gascity.com/) (`bd ready`).

## Prerequisites

- Terraform 1.9 or later
- Azure CLI authenticated to the target tenant and subscription
- PowerShell 7
- Python 3.12 or later for the Foundry IQ setup and query scripts
- Azure permissions to create role assignments and the resources in this architecture

Review the [architecture](docs/architecture.md) and [implementation plan](docs/PLAN.md) before
deploying. The default topology is intentionally expensive and creates public-internet egress for
SharePoint through Azure Firewall.

## The honest caveat

**SharePoint Online is never private.** The Microsoft Graph call that fetches the document is a
public-internet call, egressing through Azure Firewall like any other outbound traffic. Nothing in
this lab changes that, and no amount of private networking can.

What *is* private is everything after that fetch: the blob that receives the bytes, the Content
Understanding endpoint that analyses them, the AI Search index that stores the result, the Foundry
account that serves it, and the cross-region hop between the two regions. The private boundary
starts at the Function, and this repo is explicit about where that line sits.

## The showcase

```
SharePoint ──(public Graph call, via AzFW)──> Function (SCUS, VNet-integrated)
                                                  │
                                                  ├─> private blob (SCUS)
                                                  ├─> Content Understanding (SCUS, private endpoint)
                                                  │      analyzeBinary — bytes in body
                                                  │
                                                  └─> AI Search index (CUS, private endpoint)
                                                         ▲
                                                    across the vWAN
                                                         │
                                              Foundry IQ knowledge base
                                                         │
                                                   Foundry agent (CUS)
                                                         │
                                                   jumpbox via Bastion
```

The cross-region push is the point. It is what proves hub-to-hub transit actually works, rather
than leaving the vWAN as expensive decoration.

## Layout

| Path | Purpose |
|---|---|
| `terraform/` | Single root; local modules under `terraform/modules/` |
| `scripts/` | Preflight, backlog bootstrap, RBAC, Foundry IQ setup, teardown |
| `src/ingest_func/` | Flex Consumption Function driving the ingestion pipeline |
| `src/hello_world/` | Agent query client |
| `docs/PLAN.md` | Architecture, address plan, and the hard constraints |

## Getting started

```powershell
# 1. Elevate (Owner is required for the agent-setup role assignments)
& "$env:USERPROFILE\Scripts\Invoke-PimElevation.ps1" -Action Elevate -Role Owner -Duration PT8H

# 2. Gate on capacity before spending anything
pwsh -NoProfile -File .\scripts\Test-Preflight.ps1

# 3. Deploy
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform apply

# 4. See what's next
bd ready
```

## Post-deploy runbook

Everything below runs **from the jumpbox**, because the search service and both Foundry
accounts have public network access disabled.

```powershell
# Connect via Bastion, then on the jumpbox:
az login
$tf = terraform output -json foundry_primary | ConvertFrom-Json

# Create the index, knowledge source, and Foundry IQ knowledge base
python scripts\New-FoundryIqKnowledgeBase.py `
  --search-endpoint  $tf.search_endpoint `
  --foundry-endpoint "https://$($tf.account).cognitiveservices.azure.com"

# Trigger ingestion, then ask a grounded question
python src\hello_world\ask_agent.py `
  --search-endpoint $tf.search_endpoint `
  --question "What does the document say about ...?"
```

Retrieve the jumpbox password with `terraform output -raw jumpbox_admin_password`.

## Cost warning

Two Azure Firewalls, two vWAN hubs, Bastion Standard, AI Search S1, Cosmos, and a VM put this in the
high hundreds to over $1,000 per month. This is a lab, not a deployment you leave running. See
`scripts/Stop-Lab.ps1` and the teardown notes in `docs/PLAN.md`.

**Teardown order matters:** delete *and purge* the Foundry accounts before the VNet. The
`serviceAssociationLink` on the agent subnet will otherwise block VNet deletion.

## Scope

This is a lab. No customer-managed keys, no Azure Monitor Private Link Scope, no multi-region
failover, no CI/CD. Those are deliberate omissions, not oversights.

## Security

Terraform state, variable files, plans, deployment logs, and preflight results are intentionally
excluded from version control because they can contain credentials or deployment identifiers. See
[SECURITY.md](SECURITY.md) for reporting guidance.

## License

Licensed under the [MIT License](LICENSE).
