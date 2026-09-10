# funwithfoundry

Build a private document-to-answer workflow on Microsoft Foundry, with infrastructure,
ingestion, a native hosted agent, a working synthetic demo and deployment checks in
one repository. Start with the supplied corpus, prove the private path, then adapt
the source, retrieval and deployment choices to your workload.

This is an **Azure engineering solution accelerator with a reference POC baseline**,
not a managed product or production certification. It uses two regions to demonstrate
capability placement and secured transit, not active-active availability.

## What you get

| Included | What it does |
| --- | --- |
| Terraform infrastructure | Two secured Virtual WAN hubs, firewalls, spokes, private DNS/endpoints, Foundry dependencies, Search, Function and jumpbox/Bastion |
| Document ingestion | Entra-authorized Python Function stages a document, extracts it with Content Understanding and indexes text with provenance |
| Native hosted agent | Explicit LangGraph sequence requires Foundry IQ and a versioned Search toolbox before tool-free answer generation |
| Self-contained demo | Project Cedar fixture generated inside the Function; no SharePoint tenant, uploaded test document or API key needed for the default scenario |
| Private deployment workflow | Reviewed Terraform plans, verified tool bundle, temporary Bastion SFTP transfer, Function publishing, index/IQ initialization and native identity reconciliation |
| Validation and operations | Local tests, hosted CI, live verification scripts, resume checkpoints, troubleshooting and ordered teardown |

The default interaction is a Python command-line client and scripts, not a chat
website. SharePoint is an optional single-file source requiring separate site consent.

## How it works

1. An authorized caller on the private jumpbox invokes the ingestion Function in
   **South Central US** using its managed identity and the `Ingestion.Invoke` app role.
2. The Function generates the fixture, or reads the configured SharePoint file. It
   stages the bytes in Blob Storage and calls Content Understanding for extraction.
3. Extracted text and source identifiers are written to **Central US AI Search**
   through secured cross-region transit. Document-level indexing must succeed.
4. The caller sends a question to the native hosted agent through private Foundry
   ingress. The graph calls IQ, validates its output, then calls the Search toolbox
   with the same full question and validates that result too.
5. Only then does the model synthesize an answer with source metadata. Failed,
   empty or mismatched tool results do not become a successful grounded response.

IQ uses a planner model to retrieve from the index; the toolbox provides a separate
simple-text retrieval route to **that same index**. They are two required paths,
not independent sources of truth. The supplied index is text/semantic, not vector.

![Private regional topology and service boundaries](docs/diagrams/capability-host-deployment-azure-architecture.png)

See the [runtime diagram](docs/diagrams/runtime-flow-azure-architecture.png) and
[architecture guide](docs/architecture.md) for component ownership, identities,
DNS/routing, failure behavior and the source files behind each part.

## Before you deploy

- Use a Windows workstation with PowerShell 7.3+, Git, Azure CLI and its Bastion
  extension, Terraform, azd, uv, Node.js and native Windows OpenSSH clients.
  The [version matrix](docs/compatibility.md) records the tested toolchain.
- Obtain Azure resource/RBAC authority and **separate Entra application and app-role
  assignment authority**. ARM Owner/PIM alone does not grant tenant consent.
- Validate regional model/VM/network capacity, policy and data-residency requirements.
  `GlobalStandard` does not pin inference to the two resource regions.
- Budget for two firewalls, two hubs, Bastion, Search and Cosmos, even when idle.
  **VM deallocation is not a zero-cost pause.** No fixed deployment time or cost is promised.
- Protect Terraform state, plans and azd progress on encrypted, access-controlled
  storage with backups outside the lab's destruction scope. State contains secrets,
  including the jumpbox administrator password.

The detailed [deployment guide](docs/deployment.md) covers prerequisites, setup,
stage outputs, failure recovery and optional SharePoint consent. Deployment has
review gates and can require operator recovery; it is not an unattended one-click install.

## Deploy the accelerator

Run these from a **new checkout** for a new environment. Do not replace an existing
lab's variable file or state. No teardown is required to start a new deployment.

```powershell
git clone https://github.com/aionic/funwithfoundry.git
Set-Location funwithfoundry
if (Test-Path .\terraform\terraform.tfvars) { throw 'Existing configuration: review it instead of overwriting.' }
Copy-Item .\terraform\terraform.tfvars.example .\terraform\terraform.tfvars
```

Edit the private variable file with your subscription and a unique resource prefix;
leave `native_agent_principal_id` empty on first deployment. Complete the
[local setup and release checks](docs/TESTING.md#prepare-local-environments), then
authenticate and prepare the tool bundle:

```powershell
$SubscriptionId = '<your-subscription-guid>'
$EnvironmentName = 'funwithfoundry-dev'
az login
az account set --subscription $SubscriptionId
az account show --output table
pwsh -NoProfile -File .\scripts\Get-RunnerToolManifest.ps1 -OutputPath .\.azure\runner-tools.json -PythonVersion 3.13.7
```

Confirm that the subscription matches your Terraform input. Review the generated
manifest and its adjacent artifact cache, then run the stages in order, stopping
on any error and approving only the intended plans:

```powershell
$ErrorActionPreference = 'Stop'
$ToolManifestPath = (Resolve-Path .\.azure\runner-tools.json).Path
$Deployment = @{
    SubscriptionId = $SubscriptionId
    EnvironmentName = $EnvironmentName
    ToolManifestPath = $ToolManifestPath
}
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Preflight
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Infrastructure
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Workload -Resume
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Verify -Resume
```

`Preflight` reads Azure; `Infrastructure` provisions resources; `Workload` installs
the private runner tools and publishes code/retrieval definitions; `Verify` checks
the deployed flow. The jumpbox authenticates with its own identity, not a copied
workstation login cache. Runtime RBAC is reconciled after the agent identity exists.

`EnvironmentName` separates progress records, **not Terraform state**. Use a separate
checkout/state and unique naming for another lab. Keep the same reviewed settings
and manifest through all stages. Region or VM-size changes also need matching
[preflight arguments](docs/deployment.md#configure-the-environment).
See [resume guidance](docs/deployment.md#resume-and-release) before retrying a timeout.

## Try the demo

The `Verify` stage invokes the real Function fixture and checks provenance, IQ and
the native dual-retrieval response. For interactive questions, follow the
[private client setup](src/hello_world/README.md) and
[complete demo](docs/deployment.md#complete-demo). Workstation login alone does not
provide a network route to the private agent endpoint.

| Ask about Project Cedar | Expected fixture fact |
| --- | --- |
| Who is the fictional project owner? | Morgan Example |
| When is the fictional launch date? | 15 October 2026 |
| What is the document retention period? | 30 days |
| What is the approved budget? | Not present; the answer should acknowledge uncertainty |

These are expected demo outcomes, not claims about your deployment. Record your
own results using the [testing guide](docs/TESTING.md).

## Adapt it to your workload

Start with a uniformly authorized test corpus, then change one layer at a time:

- **Connect your document:** configure the existing SharePoint source and obtain
  site-scoped read consent. There is no end-user SharePoint ACL trimming.
- **Expand the corpus:** add source adapters, chunk identity, ingestion scheduling
  and deletion reconciliation; the reference is not a bulk crawler.
- **Change retrieval or tools:** evolve the schema, graph gates, toolbox and strict
  client together. Enabling embeddings alone does not create vector search.
- **Operationalize:** design queueing, retention, telemetry, remote state and a trusted
  private deployment runner before adding throughput or a user-facing interface.
- **Change regions or resilience:** review quotas, subnet/routing assumptions, state
  replication and failover. A region-name change is not an HA/DR implementation.

The [architecture extension playbooks](docs/architecture.md#extension-playbooks)
identify what is configurable today, what requires code and how to validate each change.

## Operate and maintain

Use the [operations guide](docs/operations.md) for troubleshooting, pause, rollback
and exact-state teardown. Foundry capability-host/account deletion and verified purge
must precede network removal. Never purge by a broad name prefix.

Private endpoints are only part of the security boundary: Graph, identity, build
feeds and selected telemetry still use public HTTPS. The firewall allowlist is a
POC tradeoff, and no production SLO or complete exfiltration control is claimed.
Read [SECURITY.md](SECURITY.md) before using sensitive data.

[Documentation index](docs/README.md) links deployment, architecture, testing,
operations and extension guidance. Dated [status](docs/STATUS.md) and
[validation evidence](docs/VALIDATION.md) live under `docs`, separate from these
instructions. See [CONTRIBUTING.md](CONTRIBUTING.md) for contributions and
[automation.md](docs/automation.md) for CI and dependency review. Updates do not
automatically deploy Azure resources. The default branch has no support SLA.

## License

Licensed under the [MIT License](LICENSE).
