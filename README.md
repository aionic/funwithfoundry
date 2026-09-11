# funwithfoundry

Build a private document-to-answer workflow on Microsoft Foundry, with infrastructure,
ingestion, a native hosted agent, a working synthetic demo and deployment checks in
one repository. Start with the supplied corpus, prove the private path, then adapt
the source, retrieval and deployment choices to your workload.

**Validated baseline, 2026-09-11:** native ingestion and dual retrieval passed in
the private S1 lab, including repeated verification with safe datasource receipt
refresh. The full local release gate passed. SharePoint is an optional source;
its live validation is deferred because no sample is available. Source integration
and consent requirements are implemented, but no SharePoint end-to-end pass is
claimed. See the [validation record](docs/VALIDATION.md) and
[native ingestion guide](docs/native-ingestion.md).

This is an **Azure engineering solution accelerator with a reference POC baseline**,
not a managed product or production certification. It uses two regions to demonstrate
capability placement and secured transit, not active-active availability.

## What you get

| Included | What it does |
| --- | --- |
| Terraform infrastructure | Two secured Virtual WAN hubs, firewalls, spokes, private DNS/endpoints, Foundry dependencies, Search, Function and jumpbox/Bastion |
| Document staging and ingestion | Entra-authorized Function stages raw bytes; Azure Search executes CU, chunking, embeddings and indexing through six explicitly configured native definitions |
| Native hosted agent | Explicit LangGraph sequence requires Foundry IQ and a versioned Search toolbox before tool-free answer generation |
| Self-contained demo | Project Cedar fixture generated inside the Function; no SharePoint tenant, uploaded test document or API key needed for the default scenario |
| Private deployment workflow | Reviewed Terraform plans, verified tool bundle, temporary Bastion SFTP transfer and native identity reconciliation; existing-lab migration and repeated Verify exercised live |
| Validation and operations | Local tests, hosted CI, live verification scripts, resume checkpoints, troubleshooting and ordered teardown |

The default interaction is a Python command-line client and scripts, not a chat
website. SharePoint is an optional single-file source requiring separate site consent.

## How it works

1. An authorized caller on the private jumpbox invokes the ingestion Function in
   **South Central US** using its managed identity and the `Ingestion.Invoke` app role.
2. The Function generates the fixture, or reads the configured SharePoint file. It
  overwrites `native/{source_id}/source.ext` in Blob Storage and returns HTTP `202`,
  `status: staged`. It does not call Content Understanding or Search.
3. **Central US AI Search** runs `spo-native-indexer` against the staged blobs,
  using an explicit datasource, skillset and index. The `spo-native` knowledge
  source is kind `searchIndex`; it does not auto-generate ingestion resources.
  Configuration validation and fresh indexing must both pass before acceptance.
4. The caller sends a question to the native hosted agent through private Foundry
   ingress. The graph calls IQ, validates its output, then calls the Search toolbox
   with the same full question and validates that result too.
5. Only then does the model synthesize an answer with source metadata. Failed,
   empty or mismatched tool results do not become a successful grounded response.

IQ uses a planner model to retrieve from the index; the toolbox provides a separate
`vector_semantic_hybrid` route to **that same `spo-native-index`**. They are two
required paths, not independent sources of truth. Contract version 2, owned by
`accelerator-native-indexer`, explicitly configures native CU semantic 500-token,
zero-overlap chunks with `gpt-5.2`, images/location metadata, 3072-dimensional
embeddings and child projections. This path passed live fixture validation. Child citations
use the staged blob URL; original source URL metadata remains on the blob. Manual
Blob staging can also feed the indexer without invoking the Function.

See the [architecture guide](docs/architecture.md) for current component ownership,
identities, DNS/routing and failure behavior. The [diagram archive](docs/diagrams/README.md)
is retained as historical reference: its images depict the superseded Function-led
extraction/indexing path, not the native ingestion flow above.

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
- Review the Search **S1** default, ingestion UAMI, three secondary dependency shared
  private links and scheduled model costs. Direct private built-in-skill indexers
  support S1+ on services created after April 3, 2024; embeddings additionally need
  a high-capacity region. The current Central US service was created September 9,
  2026, and passed the exercised native CU/embedding scenario. Root `search_sku` accepts `standard`,
  `standard2` and `standard3`. The generated private Blob KS S2 path is not used.
  Link approvals remain explicit; the primary planner link and security controls
  are unchanged. See [eligibility details](docs/native-ingestion.md#identity-network-and-cost-review).
- Protect Terraform state, plans and azd progress on encrypted, access-controlled
  storage with backups outside the lab's destruction scope. State contains secrets,
  including the jumpbox administrator password.

The detailed [deployment guide](docs/deployment.md) covers prerequisites, setup,
stage outputs, failure recovery and optional SharePoint consent. Deployment has
review gates and can require operator recovery; it is not an unattended one-click install.

## Deploy the accelerator

The commands below describe the accelerator interface. The native baseline was
validated through a reviewed existing-lab migration and repeated Verify runs, not
a clean new-environment rehearsal. Workload orders Function publish, fixture
staging, Knowledge setup, native deployment and runtime RBAC before verification.
Existing definitions and changed deployment fingerprints require explicit review;
do not bypass mismatch or failed-validation gates.

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

The end-to-end verifier requires blob HEAD/provenance, a fresh native indexer run,
child chunks, IQ and the native dual-retrieval response. This fixture workflow and
repeat verification passed in the lab. For interactive questions, follow the
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

- **Connect your document:** supply a SharePoint sample, configure the optional
  single-file source and obtain site-scoped read consent. PDF, PNG, JPEG and UTF-8
  TXT are accepted. There is no end-user SharePoint ACL trimming; real-source
  validation is separate from the supplied fixture demo.
- **Expand the corpus:** add source adapters and deletion reconciliation around
  the native scheduled indexer; the reference is not a bulk crawler.
- **Change retrieval or tools:** review the explicit native-definition contract,
  graph gates, toolbox and strict client together. Chunking/vectors are explicitly
  configured; existing-definition mismatches require approved reconciliation.
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
