# Architecture

## Interpretation

This reference POC separates capabilities across two regions; it does not provide
active-active service or regional disaster recovery. The outcome is an authorized
document-to-grounded-answer demonstration with explicit network, identity and
retrieval failure boundaries. Source review date: **2026-09-09**.

- Central US hosts Foundry accounts/projects and model deployments, native hosted
  agent execution, AI Search/IQ, platform state dependencies and the operator jumpbox.
- South Central US hosts the Flex Consumption ingestion Function, staging/host
  storage and Content Understanding with its Foundry resources.
- Two secured Virtual WAN hubs provide the intended cross-region transit path.
- Synthetic documents are generated inside the actual ingestion Function. Optional
  SharePoint documents are fetched through public Graph HTTPS with site-scoped consent.
- Application success requires IQ and toolbox results for the full current question,
  followed by tool-free synthesis and source metadata. A prompt alone is not proof.
- Resource placement is not inference residency: GlobalStandard processing is not
  pinned to these two regions. Data classification/residency approval is a live gate.

## Diagram contracts

These complete Mermaid files are the review contracts; there are no duplicated
inline diagrams or links to nonexistent PNG deliverables:

| Contract | Approved-design PNG | Viewpoint and meaning |
| --- | --- | --- |
| [Secure multi-region topology](diagrams/capability-host-deployment-azure-architecture.mmd) | [3840 x 2160 PNG](diagrams/capability-host-deployment-azure-architecture.png) | Physical regions, VNets/subnets, PE placement, compute association and secondary control-plane relationships; existing filename retained |
| [Document-to-grounded-answer](diagrams/runtime-flow-azure-architecture.mmd) | [3840 x 2160 PNG](diagrams/runtime-flow-azure-architecture.png) | Numbered application journey, real SCUS Function transit, both required retrieval calls and explicit failure branches |

Solid arrows denote initiating runtime requests or application data/control flow.
Dashed arrows are secondary relationships with explicit labels: deployment,
identity, association, optional source access or a recorded tool result. The
runtime diagram's logical service groups are **not** VNet boundaries.

Both contracts passed pinned Mermaid validation and preview inspection, followed
by explicit approval of their exact contents. The official-icon PNGs were rendered
and inspected for legibility and semantic fidelity. Future semantic changes require
renewed contract approval; rendering may change geometry but not components, edges,
boundaries, directions or flow numbers. See
[automation.md](automation.md#diagram-validation) for local reproduction commands.

## Runtime versus control plane

**Runtime:** the authorized caller uses private Function and Foundry ingress.
The Function identity stages bytes, invokes Content Understanding and writes Search.
The hosted application invokes IQ and its read-only Search toolbox before synthesis.
Search's IQ planner calls a **Foundry model deployment**, not the hosted agent, using
Search's own identity through its approved outbound shared private link.

**Control plane:** Terraform creates network, accounts, projects, connections,
identities, role assignments and project capability host. The account capability
host is handled by the idempotent helper because the platform renames its singleton.
azd and deployment helpers create data-plane definitions and hosted versions from
a private runner where required. ARM VM Run Command transports trusted administrative
scripts; it is not an application proxy and does not give the workstation private
reachability. Entra application registration/role grants require separate tenant
authority from ARM resource permissions.

The staged interface is `Preflight -> Infrastructure -> Workload -> Verify`.
Fresh preflight and the account/capability-host setup passed; remaining deployment
and runtime acceptance are tracked in [status.md](../status.md). Detailed order and bootstrap limits are in
[deployment.md](deployment.md#ordered-stages).

## Components and boundaries

Foundry PaaS accounts, projects, models, Search, Storage, Cosmos DB, Key Vault and
the Function service are **outside** customer VNets. Only PE network interfaces and
their explicit subnet boundaries belong inside a PE subnet. Foundry's platform-managed
agent compute is associated with the dedicated delegated subnet for outbound
execution; the whole Foundry service is not injected into that subnet.

The Function uses a separate delegated outbound integration subnet in SCUS. Its
inbound app/SCM PE is distinct from outbound integration. A private endpoint alone
does not configure a Function's outbound path. Both compute subnets use
`Microsoft.App/environments` delegation in this source, with separate address space.
The CUS agent subnet is /24; the 62-character name check is a repo workaround.

Bastion and the jumpbox have their own CUS subnets. Bastion interactive use remains
unverified here; historical remote tests used Run Command. Do not attach a route
table to `AzureBastionSubnet` as a workaround or install temporary WinRM listeners.
The jumpbox has a local administrator password in Terraform state, so keyless
data-service authentication does not mean the deployment contains no secrets.

### DNS and routing

The [DNS zone inventory](../terraform/locals.tf) links private zones to both spokes:
Foundry cognitive/OpenAI/services hosts, Search, Cosmos, Blob/File/Queue/Table,
Key Vault and Function/SCM. Clients use ordinary service FQDNs; private DNS resolves
them to PE addresses. The reference uses Azure-provided DNS; custom/on-premises
resolvers require explicit forwarding, not an assumption that VNet links reach them.

Routing intent directs applicable private and Internet hub traffic through Azure
Firewall Standard in each region. The critical indexing path is **SCUS Function
integration -> SCUS firewall -> vWAN inter-hub transit -> CUS firewall -> Search PE**.
The reverse CUS-to-SCUS direction is a separate caller ingress journey. Same-spoke
traffic may remain local; not every private request traverses both firewalls.

The [firewall source](../terraform/modules/vwan-secured/main.tf) includes a broad
spoke-to-spoke TCP/UDP network rule plus wildcard application egress and platform
tags. Network rules take precedence over application rules. Historical cross-spoke
traffic fell into an application proxy path without the network rule, causing a
public-origin denial. This is a specific configuration failure, not a universal
Azure Firewall limitation. The current allowlist is POC policy, **not zero-trust**.

Search does not use the customer Function/agent integration subnet for its planner
egress. Its shared private link uses `openai_account`, explicit approval and the
`.openai.azure.com` model URI. The public Graph/SharePoint fetch, package feeds,
identity and selected telemetry remain separate egress dependencies. No AMPLS or
claim of wholly private end-to-end platform traffic is included.

## Primary runtime flow

1. The CUS jumpbox MI invokes the SCUS Function via its PE with an API-audience token
    and assigned `Ingestion.Invoke` role; the application validates token and request.
2. The Function loads the constrained synthetic fixture by default, or fetches the
    one configured SharePoint file via public Graph HTTPS after site-scoped approval.
3. The Function writes selected source bytes to private staging Blob Storage.
4. It sends the bytes to Content Understanding `analyzeBinary` through its PE and
    polls with bounded waits; nonempty extraction is required.
5. Function extraction computes/preserves provenance and indexes through the SCUS-to-CUS
    route. Every Search document result must succeed, not merely the HTTP request.
6. After successful ingestion, the private caller sends the full question to the
    native hosted agent using Responses through Foundry ingress.
7. The application invokes IQ first. IQ retrieves the index and calls its Foundry
    planner model through the approved Search shared private link.
8. After recording that outcome, the application invokes the configured versioned
    toolbox with a simple text Search query and the same full current question.
9. A gate validates both current call IDs, names, arguments and usable outputs.
    Either failure or mismatched/empty result prevents a successful grounded answer.
10. Tool-free synthesis uses the two results as untrusted data and appends retrieved
     source metadata. Insufficient evidence should produce uncertainty; synthesis
     failure produces an explicit failure, not a claimed answer.

Both retrieval routes use **the same index**. Agreement is not independent
corroboration, and source metadata is not proof that every generated statement is
entailed. Unknown-answer and citation quality require functional evaluation.

## Identity matrix

The table describes source assignments, not verified live grants or a claim that
the POC has minimal possible permissions. See [main.tf](../terraform/main.tf),
[Foundry RBAC](../terraform/modules/foundry-agent-private/foundry.tf) and
[ingestion auth](../terraform/modules/ingest-function/auth.tf).

| Identity | Purpose and scope | Important boundary |
| --- | --- | --- |
| Deploying operator/CI | Approved ARM create/update/delete, PE approval and role-assignment rights at reviewed scopes | Separate from tenant Graph authority and from runtime identity |
| AzureAD bootstrap identity | API application/SP creation, caller SP lookup and `Ingestion.Invoke` assignment | ARM PIM is insufficient; review tenant permissions independently |
| Jumpbox MI | Function API role; Function `Website Contributor`; scoped Search service/index contributor, Foundry project manager/cognitive user and staging contributor | Privileged setup/test identity, not the read-only application identity |
| Function user-assigned MI | Host-storage Blob/Queue/Table roles, staging Blob contributor, CU Cognitive Services User and Search Index Data Contributor | Optional Graph `Sites.Selected` plus one site read grant; never tenant-wide fallback |
| Foundry project MI | Cosmos DB Operator/Data Contributor, Storage Account Contributor/Blob Contributor, Search service/index contributor and Foundry User | Platform setup/state privileges are broader than query-only runtime access |
| Project conditional Blob Owner | Blob owner role with a condition in source | Do not advertise universal container-only access; inspect exact condition/actions and other additive grants |
| Hosted runtime principal | Foundry User on project and Search Index Data Reader on Search, after discovery | Distinct from project/jumpbox; missing principal or role is a deployment blocker |
| Search service MI | Cognitive Services OpenAI User on the Foundry account | Planner model inference over approved shared private link, not hosted-agent invocation |

## Data and state

SharePoint is the optional authoritative source; the fixture is versioned test data.
Staging stores source bytes, and Search stores derived text/provenance. The canonical
[index schema](../src/shared/search-index.json) has no vector fields. The provisioned
embedding model does not make this a vector pipeline. IQ wraps the same index through
its knowledge source; the toolbox remains `query_type: simple`.

The ingestion response/document preserves stable source identity, content hash and
document ID, with a separate request ID for correlation. A partial failure may leave
staged bytes; reruns need reconciliation, not success inferred from partial output.
Platform agent state uses configured Storage/Cosmos dependencies; application graph
state is not a claim of a tested durable conversation-recovery mechanism.

Terraform state is deployment truth and contains sensitive values. azd state tracks
environment/toolbox/agent context. Neither should be committed or copied as a login
cache. Retention, deletion propagation, backup restoration and recovery times are
not certified. See [operations.md](operations.md).

## Decisions and Well-Architected review

| Decision | Why | Tradeoff | Validation status |
| --- | --- | --- | --- |
| Split regional capabilities with two secured hubs | Demonstrate actual SCUS Function-to-CUS data movement | More latency, cost and failure dependencies; no HA | Live fixture ingestion and provenance passed |
| PaaS Private Link plus separate compute injection | Separate inbound access from outbound execution | DNS, routing, approval and platform ordering complexity | Live control-plane, public-denial and end-to-end checks passed |
| Entra API app role and workload identities | Authenticate and authorize the caller, not just its IP | Tenant bootstrap and eventual consistency | Seven live authorization/ingestion checks passed; separate unapproved-app token not tested |
| Deterministic dual retrieval before synthesis | Prevent a prompt-only or missing-tool answer from appearing complete | Two serial retrievals and model latency; shared corpus | Local failure tests and live dual-tool golden responses passed |
| One text/semantic index and simple toolbox query | Keep ingestion and both retrieval branches compatible | No vector or per-document end-user ACL capability | Fresh initialization and live retrieval passed |
| Keep GlobalStandard defaults and broad POC egress explicit | Preserve approved reference scope without inventing a new platform | No two-region processing guarantee or zero-trust claim | Deployment and quota preflight passed; residency remains a workload decision |

**Reliability:** one Search replica and single-region Cosmos state are POC constraints.
There is no durable ingestion queue, tested failover, SLO, RTO or RPO. Bounded retries
and explicit failure gates do not provide transactional ingestion or automatic recovery.

**Security:** tokens/roles and private routes are complementary. Shared-index access
does not trim results by SharePoint user ACL. Prompt injection, broad egress,
privileged private runners and state exposure remain risks. Use a uniformly
authorized test corpus, no public/API-key fallback, and reviewed tenant bootstrap.

**Cost optimization:** hubs, firewalls, Bastion and Search persist while the VM is
deallocated. Model tokens, cross-region data, builds, logs and storage add variable
cost. No current pricing estimate has been verified in this pass.

**Operational excellence:** ordered stages, exact-ID teardown/purge, preserved state,
machine-readable outcomes and protected CI are the operating contract. Record tool
versions and request IDs without tokens/document bodies. Diagnostics settings and
alert coverage need live review; no centralized monitoring completeness is claimed.

**Performance efficiency:** serial IQ/toolbox calls and synthesis, CU polling, Function
cold starts and cross-region transfer affect latency. Throughput, concurrency,
throttling and token quotas need measured budgets; no load-test result is implied.

## Evidence status

| Claim | Classification | Evidence or next gate |
| --- | --- | --- |
| Prior infrastructure/DNS/CU/IQ checks and hosted-agent v5 smoke | Historical | Recorded for the previous lab, not rerun here; no old pass count is promoted |
| New Function authorization, fixture path and deterministic runtime | Live verified | Seven ingestion checks, provenance and end-to-end dual retrieval passed |
| Complete Mermaid syntax/render | Locally validated | Pinned CLI `11.12.0`; nonempty temporary previews, visually inspected; see reproduction commands |
| Final modern Azure-native PNGs | Approved and rendered | Both 3840 x 2160 images inspected; source semantics unchanged |
| Fresh deployment, rerun and SCUS Function-to-CUS proof | Live verified with recovery | See [VALIDATION.md](VALIDATION.md); not one uninterrupted script run |
| Optional real SharePoint | Not tested | Tenant/site consent and a successful real Function invocation required |
| Public network denial under revised checks | Live verified | All three endpoints returned explicit network-policy 403s |
| Bastion interactive RDP | Not tested here | Historical Run Command is not RDP evidence |
| Full local release checks | Locally validated | Python, PowerShell 5.1/7, Terraform mocks, YAML/Markdown/links and diagrams |
| GitHub protections and cloud-scored evaluation | Not tested | Separate publication/admin configuration; no cloud scores claimed |

## Review notes

1. Region/SKU/model capacity and customer data-residency acceptance remain live gates.
    GlobalStandard inference can process outside the two resource regions.
2. Private runner tools and workload behavior passed the recorded rehearsal with
    recovery; new environments must validate their own permissions and bootstrap.
3. This diagram intentionally omits detailed telemetry/install-feed edges and exact
    private environment names/IDs. The identity table and guides carry those constraints.
4. Preview API dates are not blanket service-preview labels; use the source matrix
    and dated first-party feature guidance in [compatibility.md](compatibility.md).
5. First-party references accessed 2026-09-09:
    [Foundry network isolation](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link)
    and [deployment types](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types).

## Human review

Review both complete linked Mermaid contracts, including the PaaS/subnet placement,
planner-to-model call, authorized SCUS Function path and separate control plane.
Approval must refer to these exact sources; any semantic revision requires another
validation, preview and approval. The recorded rebuild passed core live acceptance;
future changes must rerun the applicable release and live checks.
