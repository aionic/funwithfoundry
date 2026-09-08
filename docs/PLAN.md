# funwithfoundry - private Foundry lab (Central US + South Central US over secured vWAN)

**Implementation status:** Deployed and verified on 2026-09-08. Use the [README](../README.md)
for deployment commands and [architecture](architecture.md) for the current proof matrix and
diagram links. This file preserves design decisions, constraints, and residual risks.

> Persisted here because VS Code repo memory requires the folder to be open as a workspace.
> Once `d:\git\funwithfoundry` is opened as the workspace, mirror this into `/memories/repo/`.

## What this is

Two Foundry instances joined by a **Standard vWAN with Azure Firewall in both hubs**:

- **Central US** — network-injected private agent platform (hosted agents + Foundry IQ)
- **South Central US** — Content Understanding

A VNet-integrated Flex Consumption Function pulls a SharePoint document, runs Content
Understanding in SCUS, and pushes the result into the private AI Search index in CUS
**across the vWAN**. Foundry IQ serves it to an agent queried from a Bastion-fronted
Windows jumpbox. All Terraform (single root, local modules, local state). Tracked in beads.

## Environment (verified 2026-09-08)

- Subscription: `<your-subscription-name>` / `<your-subscription-id>`
- Tenant / MG root: `<your-tenant-id>`
- PIM: Owner is **eligible at management-group scope**:
  `& "$env:USERPROFILE\Scripts\Invoke-PimElevation.ps1" -Action Elevate -Role Owner -Duration PT8H`
  Owner (not Contributor) is required for `roleAssignments/write` in the standard agent setup.
- Preflight (`scripts/Test-Preflight.ps1`): **51 PASS / 0 FAIL / 0 WARN**
  - All 10 resource providers registered
  - AIServices S0 in both regions
  - `gpt-5.2`, `gpt-4.1`, `gpt-4o`, `text-embedding-3-large` available in both regions
  - Flex Consumption supported in both regions
  - 92 vCPU free in CUS; `Standard_D4s_v5` unrestricted
  - ~999 Standard public IPs free per region
  - Existing footprint: 4 AI Search, 3 Cosmos, 0 vWAN, 0 Azure Firewall

## Locked decisions

Secured hubs (Azure Firewall Standard in both regions, routing intent) · Content Understanding
pipeline as the ingestion showcase · Flex Consumption for the glue · Entra-only data-service
authentication · single Terraform root with local state · Windows Server 2025 jumpbox + Bastion
Standard · `Standard_D4s_v5`.

Explicitly excluded: CMK, AMPLS, multi-region failover, CI/CD, Copilot Studio.

## Address plan

| Scope | CIDR |
|---|---|
| vWAN hub CUS | 10.100.0.0/23 |
| vWAN hub SCUS | 10.101.0.0/23 |
| vnet-cus-foundry | 10.10.0.0/16 **+ 172.16.0.0/16** |
| — snet-agent (delegated `Microsoft.App/environments`) | **172.16.0.0/24** |
| — snet-pe | 10.10.1.0/24 |
| — snet-jumpbox | 10.10.2.0/24 |
| — AzureBastionSubnet | 10.10.3.0/26 |
| vnet-scus-cu | 10.20.0.0/16 |
| — snet-pe | 10.20.1.0/24 |
| — snet-func (delegated `Microsoft.App/environments`) | 10.20.2.0/24 |

## Hard constraints — do not relearn these

1. **Network injection must be set at Foundry account creation.** It cannot be added later for hosted agents.
2. **Capability hosts are immutable and order-dependent.** The account host must exist before the
    project host. Azure renames the account singleton to `<account>@aml_aiagentservice`, so
    `scripts/Ensure-AgentCapabilityHost.ps1` manages it idempotently outside Terraform state.
    Terraform manages the project host.
3. **Standard agent setup requires all three BYO resources** (Storage + AI Search + Cosmos NoSQL),
   or capability host creation fails.
4. **Cosmos needs ≥3000 RU/s** — five containers × 1000. Using 6000.
5. **Private endpoints to Search / Storage / Cosmos are NOT auto-created** by the Foundry deployment.
6. **The Foundry resource must be in the same region as its VNet.** Cosmos, Search, and Storage may differ.
7. **The agent subnet is exclusive per Foundry account**, /24 recommended, RFC1918 only. Avoid
   `169.254/16`, `172.30/16`, `172.31/16`, `192.0.2/24`, `100.64.0.0/11`, `100.100.0.0/17`.
   **The agent subnet uses `172.16.0.0/24` (Class B), not Class A.** Learn's region table says
   Class A (10.x) is fine in Central US, but the official 15b BYO-VNet sample README lists a
   fixed region subset that *excludes* Central US, and Learn's own troubleshooting documents the
   error `Provided subnet must be of the proper address space ... range of 172 or 192`. Class B
   satisfies both readings. The mismatch would otherwise only surface at capability host creation,
   long after the network is built. Tracked as `funwithfoundry-nva.8`.
8. **No TLS inspection on Azure Firewall** — a self-signed cert breaks agent provisioning. Allowlist the
   Container Apps "Managed Identity" FQDN set plus the `AzureActiveDirectory` service tag.
9. **Bastion vs routing intent** — routing intent programs `0.0.0.0/0 → AzFW` onto the spoke connection.
   The obvious mitigation (a route table on `AzureBastionSubnet` with `0.0.0.0/0 → Internet`) is
   **impossible**: Azure rejects it with `RouteTableCannotBeAttachedForAzureBastionSubnet`. Verified
   by deployment failure, not theory. Bastion falls back to platform system routes; whether that
   survives routing intent must be proven with a real RDP test in P5. Fallback if it fails: put
   Bastion in a standalone VNet peered to the spoke and not connected to the hub.
10. **Content Understanding cannot fetch a private blob by URL.** The file-reference `analyze` API has the
    CU service fetch the URL itself. Use **`analyzeBinary`** (bytes in the request body) over the CU private endpoint.
11. **SharePoint Online is never private.** The Graph fetch is a public-internet call. The private boundary
    starts at the Function.
12. **Deletion order** — delete *and purge* Foundry accounts **before** the VNet, or the
    `serviceAssociationLink` on the agent subnet blocks VNet deletion.
13. **Foundry IQ knowledge bases and sources are REST-only** (2026-04-01 GA / 2026-05-01-preview).
    Not in `azurerm` — post-deploy script.
14. Private ACR for hosted agents only works for projects created after 2026-06-25.
15. Code Interpreter in BYO-private mode cannot upload or download files.
16. **`storage_use_azuread = true` is mandatory on the azurerm provider** when storage accounts set
    `shared_access_key_enabled = false`. Otherwise the provider's post-create data-plane probe fails with
    `403 Key based authentication is not permitted on this storage account` and taints the account.
    Verified by deployment failure.
17. **The Foundry account ARM PUT returns while the account is still `Accepted`.** Attaching its private
    endpoint immediately fails with `AccountProvisioningStateInvalid: Account ... in state Accepted`.
    A wait is required between account creation and private endpoint. Model deployments, oddly, succeed
    during `Accepted` — only the private endpoint rejects it.
18. **AI Search takes ~7 minutes and the network-injected Foundry account ~4 minutes** to create. vWAN
    hubs take ~20 minutes and hub firewalls ~8-14 minutes. Budget accordingly.
19. **Azure Firewall evaluates network rules BEFORE application rules — and this breaks private
    endpoints.** With routing intent, cross-spoke traffic to a private endpoint goes through the
    firewall. With no matching network rule it falls through to an application rule (e.g. `*.azure.com`),
    which **proxies the request and re-originates it from the firewall's public IP**. The PaaS service
    then correctly answers `403 "Public access is disabled. Please configure private endpoint."`
    Fix: a `private-to-private` network rule collection covering all spoke CIDRs. Same-region calls hide
    this, because intra-VNet traffic never reaches the firewall.
20. **Azure AI Search needs a shared private link for OUTBOUND calls.** Search is an external PaaS
    service with no VNet integration for egress. Reaching a Foundry account with public access disabled
    requires `sharedPrivateLinkResources`, and the connection must be **manually approved**
    (`scripts/Approve-SharedPrivateLink.ps1`). Without it, retrieval fails with
    `401 "Principal does not have access to API/Operation"` — which looks like RBAC but is not.
21. **The shared private link groupId is `openai_account`, not `account`** — even though the Foundry
    account advertises only `account` under `privateLinkResources`. Using `account` returns
    `"Cannot create private endpoint for requested type 'account'"`.
22. **Foundry IQ retrieval runs as the SEARCH service identity.** It needs
    `Cognitive Services OpenAI User` on the Foundry account, or retrieve fails with a 401 naming the
    missing `chat/completions` data action.
23. **`alwaysQuery` is not accepted** on knowledge base `knowledgeSources` in `2026-05-01-preview` and
    causes a bare 400 with an empty body. `models[]` with `azureOpenAIParameters` IS valid.
24. **The Content Understanding analyzer is `prebuilt-document`**, not `prebuilt-documentAnalyzer`.
25. **The service forces `disableLocalAuth = true`** once public access is disabled. Declaring `false`
    makes Terraform issue a full account PUT on every plan, which resets private endpoint connections
    to Pending and is rejected with `PrivateLinkStatusChangeNotAllowed`.
26. **Root-URL probes prove nothing about Cognitive Services network isolation.** The frontend returns
    200 for `https://<account>.services.ai.azure.com/` regardless of ACLs. Only an authenticated
    data-plane call distinguishes reachable from blocked.
27. **The Search API returns 400s with empty bodies to PowerShell.** Use `curl.exe` to see the real
    error text; several hours of guesswork collapse into one readable message.
28. **Data-service local authentication is disabled.** Foundry sets `disableLocalAuth = true`,
    Storage sets `shared_access_key_enabled = false`, Cosmos DB sets
    `local_authentication_enabled = false`, and AI Search sets `disableLocalAuth = true`.
    Terraform storage data-plane calls require `storage_use_azuread = true`.
29. **Use `gpt-4o` for hosted agents with the `azure_ai_search` tool.** The identical tested agent
    on `gpt-5.2` fails every run with an opaque service error. `gpt-5.2` remains valid as the
    Foundry IQ knowledge-base planner and for agents without tools.
30. **An AzAPI Search update temporarily makes exported identity values unknown during planning.**
    A plan can therefore propose replacing the unchanged Search-to-Foundry role assignment. Apply
    the Search resource first, then rerun the full plan instead of accepting unrelated replacement
    or service-managed storage-network-rule drift.

## Verified end to end (2026-09-08)

`scripts/jumpbox/Invoke-EndToEnd.ps1` and `Ask-KnowledgeBase.ps1` prove the full path:

- All 9 private endpoint FQDNs resolve to private IPs from inside the VNet
- Cross-region reachability CUS (10.10.x) → SCUS (10.20.x) on 443 through both hub firewalls
- Content Understanding **is** available in South Central US — analyzer list returned and
  `analyzeBinary` round trip succeeded
- Document → Content Understanding (SCUS) → AI Search index (CUS, across the vWAN) → Foundry IQ
  knowledge base → grounded retrieval returning the answer with a citation
- All three data-plane endpoints return 403 from a public workstation
- Terraform converged with zero drift after the AI Search keyless-auth apply
- `scripts/Verify-Deployment.ps1` returned 24 PASS, 0 WARN, 0 FAIL
- Account and project `Agents` capability hosts both reached `Succeeded`
- The Function package deployed and the `ingest` trigger synchronized
- A hosted `gpt-4o` agent invoked `azure_ai_search` and completed with a grounded citation
- AI Search local authentication was disabled; Entra-authenticated indexing, Foundry IQ retrieval,
  and the hosted-agent Search tool all passed afterward

The synthetic end-to-end proof bypasses SharePoint and the Function by generating a document on the
jumpbox. Function deployment is proven; its SharePoint-triggered application path is not.

## Reference implementation

`microsoft-foundry/foundry-samples` →
`infrastructure/infrastructure-setup-terraform/15b-private-network-standard-agent-setup-byovnet`

## Tooling gotchas hit on this machine

- `$Args` is a reserved PowerShell automatic variable — never name a parameter that.
- Quota resource names have **no 1:1 mapping** to ARM types. The public IP quota is
  `IPv4StandardSkuPublicIpAddresses`, not `StandardSkuPublicIpAddresses`.
- Never pipe `bd` (or any interactive CLI) through `Select-Object` — it hides prompts and the terminal
  cannot detect that input is needed.
- `bd close <id> "reason"` treats the reason as another ID. Close plainly.

## Beads

Prefix `funwithfoundry-`. Epics P0–P7 with blocking edges
P1←P0, P2←P1, P3←P2, P4←P2, P5←P3+P4, P6←P5, P7←P6. P0 is closed.
Use `bd ready` to drive the run.

## Open risks

1. ~~**Content Understanding in South Central US is unproven.**~~ **RESOLVED 2026-08-29** — analyzer
   list and `analyzeBinary` both succeeded against the private endpoint.
2. ~~Foundry IQ / agentic retrieval against a **private** search service.~~ **RESOLVED** — works, but
   requires the shared private link and the Search identity role in constraints 20-22.
3. Graph app-role consent (`Sites.Selected`) may require a tenant admin. **Still unproven** — the
   SharePoint leg of the pipeline has not been exercised end to end. Content Understanding was fed a
   locally generated document instead.
4. The Azure Firewall FQDN allowlist for Container Apps drifts with platform versions; expect iteration.
5. **Bastion RDP under routing intent is still untested.** All validation ran through
   `az vm run-command`, which does not traverse the Bastion data path.
6. The **account** capability host is not Terraform-managed; the idempotent helper is a required
    deployment phase because Azure renames the singleton.
7. The Function's SharePoint-triggered path still needs Graph consent and an end-to-end run with a
    real SharePoint document; current regression coverage starts with a generated document.

## Cost

Two Azure Firewalls, two vWAN hubs, Bastion Standard, Search S1, Cosmos, and a VM land in the
high hundreds to over $1k/month. `scripts/Stop-Lab.ps1` and `terraform destroy` guidance ship in P7.
