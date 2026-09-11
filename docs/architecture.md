# Architecture

## Interpretation

This reference POC separates capabilities across two regions; it does not provide
active-active service or regional disaster recovery. The outcome is an authorized
document-to-grounded-answer demonstration with explicit network, identity and
retrieval failure boundaries. Source review date: **2026-09-11**.

The explicit S1 native-indexer pipeline passed live fixture-backed acceptance and
two subsequent normal Verify runs in the existing lab. The full local release gate
passed. Actual SharePoint integration is deferred because no sample is available;
acceptance of the structure is not source-acquisition proof or permission approval.
A clean full orchestrator run and deletion acceptance remain unproven. Earlier
custom Function proof and the failed S2 attempt are historical.
See [native ingestion](native-ingestion.md) for explicit-definition ownership,
S1 prerequisites, recovery and distinct Blob versus actual SharePoint proof gates.

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

These unchanged Mermaid files and PNGs are **historical custom-ingestion contracts**.
They show Function-owned extraction/indexing, not the new native knowledge source.
Do not use them as approval or deployment proof for the refactor:

| Historical contract | Historical approved-design PNG | Viewpoint and meaning |
| --- | --- | --- |
| [Secure multi-region topology](diagrams/capability-host-deployment-azure-architecture.mmd) | [3840 x 2160 PNG](diagrams/capability-host-deployment-azure-architecture.png) | Physical regions, VNets/subnets, PE placement, compute association and secondary control-plane relationships; existing filename retained |
| [Document-to-grounded-answer](diagrams/runtime-flow-azure-architecture.mmd) | [3840 x 2160 PNG](diagrams/runtime-flow-azure-architecture.png) | Numbered application journey, real SCUS Function transit, both required retrieval calls and explicit failure branches |

Solid arrows denote initiating runtime requests or application data/control flow.
Dashed arrows are secondary relationships with explicit labels: deployment,
identity, association, optional source access or a recorded tool result. The
runtime diagram's logical service groups are **not** VNet boundaries.

Both original contracts passed pinned Mermaid validation and preview inspection, followed
by explicit approval of their exact contents. The official-icon PNGs were rendered
and inspected for legibility and semantic fidelity. Future semantic changes require
renewed contract approval; rendering may change geometry but not components, edges,
boundaries, directions or flow numbers. A new native diagram contract must first
be reviewed for explicit-definition ownership, UAMI/private-link paths, staged-blob
provenance and validation gates. See
[automation.md](automation.md#diagram-validation) for local reproduction commands.

## Runtime versus control plane

**Runtime:** the authorized caller uses private Function and Foundry ingress.
The Function identity stages raw bytes and returns `202 staged`; it calls neither
Content Understanding nor Search. Azure Search executes scheduled private ingestion
through an explicit datasource, indexer, skillset and index. The `searchIndex`
knowledge source references that index; it does not generate ingestion resources.
Manual Blob staging can also feed the indexer independently of the Function.
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
The historical custom-ingestion rebuild and v1 acceptance passed with scoped recovery, as
recorded in [VALIDATION.md](VALIDATION.md), not as one uninterrupted script run.
Historical hosted CI also passed; `main` remains unprotected and passing checks are not enforced
merge requirements. Current follow-up work is tracked in [STATUS.md](STATUS.md).
Detailed order and bootstrap limits are in
[deployment.md](deployment.md#ordered-stages).

The deployment sequence orders Function publish, fixture staging, Knowledge
initialization, native deployment and runtime RBAC before verification. The existing
lab passed reviewed manual migration/recovery and repeated normal Verify without
agent redeployment; this is not evidence of a clean full orchestrator run.

## Components and boundaries

### Source ownership map

Use this map to find the current local code that controls a behavior. Source
assignments and requested validation contracts are not proof of live deployment.

| Component | Owning source/configuration | Responsibility and change boundary |
| --- | --- | --- |
| Accelerator stages | [Invoke-Accelerator.ps1](../scripts/Invoke-Accelerator.ps1), [outputs.tf](../terraform/outputs.tf) | Reviewed stages, source fingerprints, private-runner payloads, output-derived endpoints and native identity readback; changed source is not an unchanged resume |
| Regional wiring and private transit | [main.tf](../terraform/main.tf), [locals.tf](../terraform/locals.tf), [secured hubs](../terraform/modules/vwan-secured/main.tf) | Two spokes/hubs, address spaces, DNS inventory, routing intent and egress policy; region names alone do not define a new topology |
| Foundry platform and planner | [foundry.tf](../terraform/modules/foundry-agent-private/foundry.tf), [platform dependencies](../terraform/modules/foundry-agent-private/main.tf), [Ensure-AgentCapabilityHost.ps1](../scripts/Ensure-AgentCapabilityHost.ps1) | Accounts/projects, models, connections, RBAC, capability host, Search shared private link and Storage/Cosmos state |
| Function hosting and API identity | [Function infrastructure](../terraform/modules/ingest-function/main.tf), [auth.tf](../terraform/modules/ingest-function/auth.tf), [authorization.py](../src/ingest_func/authorization.py) | Private ingress, separate outbound integration, workload MI, app settings, API role and token/caller checks |
| Source acquisition and staging | [function_app.py](../src/ingest_func/function_app.py), [synthetic_fixture.py](../src/ingest_func/synthetic_fixture.py), [CU/staging infrastructure](../terraform/modules/foundry-content-understanding/main.tf) | Constrained source selection, bounded fetch and stable raw-blob overwrite; no Function CU/Search calls |
| Native ingestion dependencies | [native-ingestion.tf](../terraform/native-ingestion.tf) | Search ingestion UAMI, scoped roles and three secondary shared private links; live approval required |
| Optional SharePoint consent | [Grant-SharePointAccess.ps1](../scripts/Grant-SharePointAccess.ps1) | Graph application role plus one site grant for the Function MI; does not configure caller-level Search filtering |
| Knowledge definitions | [native-ingestion.json](../src/shared/native-ingestion.json), [search-index.json](../src/shared/search-index.json), [Initialize-KnowledgeBase.ps1](../scripts/Initialize-KnowledgeBase.ps1), [New-FoundryIqKnowledgeBase.py](../scripts/New-FoundryIqKnowledgeBase.py) | Version 2, owner `accelerator-native-indexer`: six explicit native definitions and strict read-back; Python delegates to PowerShell, not a second writer |
| Required retrieval and synthesis | [main.py](../src/foundry_native_agent/main.py), [toolbox.yaml](../toolbox.yaml) | LangGraph enforces IQ then Search, matching call/output gates and tool-free synthesis; toolbox contributes exactly one read-only Search tool |
| Hosted packaging and version deployment | [azure.yaml](../azure.yaml), [Deploy-NativeFoundryAgent.ps1](../scripts/Deploy-NativeFoundryAgent.ps1) | Python 3.13 Responses host, runtime environment, compute allocation, toolbox reconciliation and hosted deployment/readback |
| Caller and acceptance harness | [ask_agent.py](../src/hello_world/ask_agent.py), [Invoke-IngestFunction.ps1](../scripts/jumpbox/Invoke-IngestFunction.ps1), [Invoke-EndToEnd.ps1](../scripts/jumpbox/Invoke-EndToEnd.ps1) | Private caller auth, ingestion result checks, provenance readback and validation of exactly two current tool exchanges before accepting an answer |
| Regression contracts | [test_ingestion.py](../tests/test_ingestion.py), [test_knowledge_schema.py](../tests/test_knowledge_schema.py), [test_retrieval.py](../tests/test_retrieval.py), [Test-NativeDeployment.ps1](../tests/Test-NativeDeployment.ps1) | Cloud-free ingestion/auth failures, producer/schema agreement, graph/client failure gates and deployment-helper compatibility |

### Service placement

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
Firewall Standard in each region. The **historical** Function-to-Search indexing
path crossed SCUS integration, both firewalls and vWAN transit to the CUS Search PE.
Native ingestion moves extraction/indexing ownership to Search and its secondary
dependency shared private links; it is not that Function network path. The
CUS-to-SCUS Function invocation remains a caller ingress journey. Same-spoke
traffic may remain local; not every private request traverses both firewalls.

The [firewall source](../terraform/modules/vwan-secured/main.tf) includes a broad
spoke-to-spoke TCP/UDP network rule plus wildcard application egress and platform
tags. Network rules take precedence over application rules. Historical cross-spoke
traffic fell into an application proxy path without the network rule, causing a
public-origin denial. This is a specific configuration failure, not a universal
Azure Firewall limitation. The current allowlist is POC policy, **not zero-trust**.

Search does not use the customer Function/agent integration subnet for its planner
egress. The preserved primary planner link uses `openai_account`, explicit approval
and the `.openai.azure.com` model URI. Native ingestion adds separately approved
links to secondary storage (`blob`), CU (`foundry_account`) and OpenAI
(`openai_account`) with a new ingestion UAMI. The public Graph/SharePoint fetch, package feeds,
identity and selected telemetry remain separate egress dependencies. No AMPLS or
claim of wholly private end-to-end platform traffic is included.

## Primary runtime flow

1. The CUS jumpbox MI invokes the SCUS Function via its PE with an API-audience token
    and assigned `Ingestion.Invoke` role; the application validates token and request.
2. The Function loads the constrained synthetic fixture by default, or fetches the
    one configured SharePoint file via public Graph HTTPS after site-scoped approval.
3. The Function overwrites `native/{source_id}/source.ext` in staging Blob Storage
    with original identity/hash metadata and returns HTTP `202`, `status: staged`.
4. `spo-native-indexer` runs on creation and a `PT5M` schedule in private execution.
    Azure Search executes the explicit CU skill with `gpt-5.2`, semantic 500-token/
    zero-overlap chunks and images/location metadata, then 3072-dimensional
    embeddings and child projections. The Function does none of this processing.
5. A separate live gate must establish blob HEAD provenance, a fresh successful
    native indexer run and child chunks in `spo-native-index`; staging is not indexing.
6. After that gate, the private caller sends the full question to the
    native hosted agent using Responses through Foundry ingress.
7. The application invokes IQ first. IQ retrieves the index and calls its Foundry
    planner model through the approved Search shared private link.
8. After recording that outcome, the application invokes the configured versioned
    toolbox with `vector_semantic_hybrid` and the same full current question.
9. A gate validates both current call IDs, names, arguments and usable outputs.
    Either failure or mismatched/empty result prevents a successful grounded answer.
10. Tool-free synthesis uses the two results as untrusted data and appends retrieved
     source metadata. Insufficient evidence should produce uncertainty; synthesis
     failure produces an explicit failure, not a claimed answer.

Both retrieval routes use **the same index**. Agreement is not independent
corroboration, and source metadata is not proof that every generated statement is
entailed. Unknown-answer and citation quality require functional evaluation.

## Identity matrix

The table describes source assignments used by the fixture-validated lab, not a
claim that the POC has minimal possible permissions. Optional Graph consent remains
unproven. See [main.tf](../terraform/main.tf),
[Foundry RBAC](../terraform/modules/foundry-agent-private/foundry.tf) and
[ingestion auth](../terraform/modules/ingest-function/auth.tf).

| Identity | Purpose and scope | Important boundary |
| --- | --- | --- |
| Deploying operator/CI | Approved ARM create/update/delete, PE approval and role-assignment rights at reviewed scopes | Separate from tenant Graph authority and from runtime identity |
| AzureAD bootstrap identity | API application/SP creation, caller SP lookup and `Ingestion.Invoke` assignment | ARM PIM is insufficient; review tenant permissions independently |
| Jumpbox MI | Function API role; Function `Website Contributor`; scoped Search service/index contributor, Foundry project manager/cognitive user and staging contributor | Privileged setup/test identity, not the read-only application identity |
| Function user-assigned MI | Host-storage Blob/Queue/Table roles and staging Blob contributor; no CU/Search roles | Optional Graph `Sites.Selected` plus one site read grant; never tenant-wide fallback |
| Search ingestion UAMI | Secondary staging Blob Data Reader, Cognitive Services User and Cognitive Services OpenAI User | Native datasource/skills/vectorizer identity, distinct from Function and primary planner |
| Foundry project MI | Cosmos DB Operator/Data Contributor, Storage Account Contributor/Blob Contributor, Search service/index contributor and Foundry User | Platform setup/state privileges are broader than query-only runtime access |
| Project conditional Blob Owner | Blob owner role with a condition in source | Do not advertise universal container-only access; inspect exact condition/actions and other additive grants |
| Hosted runtime principal | Foundry User on project and Search Index Data Reader on Search, after discovery | Distinct from project/jumpbox; missing principal or role is a deployment blocker |
| Search service MI | Cognitive Services OpenAI User on the Foundry account | Planner model inference over approved shared private link, not hosted-agent invocation |

### Application identity versus caller authorization

Outbound workload authentication and inbound caller authorization are separate
contracts. `DefaultAzureCredential` lets the Function acquire service-specific
tokens for Blob and optional Graph access. Native CU/Search processing belongs to
Search, not the Function identity. Those grants do not authorize
someone to invoke ingestion or read every indexed document.

The HTTP trigger uses `AuthLevel.ANONYMOUS` to avoid Function keys, but
[authorization.py](../src/ingest_func/authorization.py) validates the bearer token
before any source fetch. It checks the RS256 signature, tenant-specific v2 issuer,
API audience, token times and app-only claims, requires `Ingestion.Invoke`, rejects
delegated `scp` claims, and matches `azp` plus `oid` to the configured client/principal
allowlist. Proxy identity headers and network location are not sufficient. Missing
or invalid credentials return 401; disallowed claims return 403; unavailable identity
validation or missing auth configuration fails closed with 503.

The private Foundry caller separately needs a Foundry-audience token and appropriate
project access. The hosted runtime's Search reader role belongs to the application,
not the requesting user. Neither retrieval route carries a SharePoint user's ACL
into a Search filter. `Sites.Selected` limits what the ingestion identity can fetch;
it is **not per-document or per-user answer authorization**. Use a corpus uniformly
authorized for all application callers. Mixed-access content requires a separately
designed authorization boundary on ingestion, both retrieval routes and source
metadata, with negative cross-user tests; it is not implemented here.

## Data and state

SharePoint is the optional authoritative source; the fixture is versioned test data.
Staging stores raw bytes; the explicitly configured Search index stores child
snippets and vectors. The [index contract](../src/shared/search-index.json) supplies
the initializer's index/projection definition and read-back expectations. Pipeline
names are `spo-native-datasource`, `spo-native-index`, `spo-native-skillset` and
`spo-native-indexer`. IQ uses `spo-native-knowledge-base` and the `searchIndex` KS
`spo-native`; the toolbox queries the same index. This path passed live fixture-backed
indexing and strict IQ-then-hybrid-Search retrieval.

The staging response preserves stable source identity, content hash, original source
URL and staged blob URL, with a separate request ID for correlation. A successful
staging response says nothing about indexing; reruns require fresh read-back evidence.
Platform agent state uses configured Storage/Cosmos dependencies; application graph
state is not a claim of a tested durable conversation-recovery mechanism.

### Schema and integrity contract

The [Function](../src/ingest_func/function_app.py) produces a raw blob, not Search
documents. Search executes the native skillset and projects child chunks and keys.
See the [explicit definitions](native-ingestion.md#explicit-native-search-definitions) for
semantic 500-token/zero-overlap chunking, images/location metadata, secondary
`gpt-5.2` and 3072-dimensional `text-embedding-3-large` validation targets.

| Field or identifier | Current meaning | Extension constraint |
| --- | --- | --- |
| Child key / `snippet_parent_id` | Service-generated chunk identity and parent association | Not the Function's `source_id`; verify child projection and current source association |
| `source_id` | SHA-256 of canonical JSON containing source kind, lowercased hostname and NFC-normalized/lowercased site/file paths | Path-based identity, not a SharePoint immutable item ID; renames require reconciliation |
| `content_hash` | SHA-256 of original bytes, in staging response and Blob metadata | Child URL alone does not prove this digest; verify blob HEAD metadata |
| `snippet`, `snippet_vector` | Configured child text and 3072-dimensional vector | Definition read-back and fresh indexing must pass; no ACL trimming is implied |
| `source_url` | Original SharePoint web URL or fixture URN returned by Function | Encoded original URL metadata is stored on the blob; not the child citation URL |
| `doc_url` | Generated projection of `/document/metadata_storage_path` | Staged blob URL, not original SharePoint URL or an access grant |
| `request_id` | New UUID per invocation, returned in JSON and `X-Request-ID` and used in logs/upstream requests | Correlation only; not a deduplication key or Search schema field |

Canonical validation accepts any safe embedding output name (such as `text_vector`)
only when the projection consistently references that output. Omitted/null semantic
overlap means zero. Projected `doc_url` aliases `/metadata_storage_path` and
`/document/doc_url` require the exact untransformed indexer mapping
`metadata_storage_path` to `doc_url`. The final citation remains the staged blob,
not `originalSource`; retain the original-source/hash blob metadata.

Staging overwrites the stable `native/{source_id}/source.ext` path. The Function
returns `staged` with HTTP `202`, never an `indexed` receipt or `document_id`.
Original `source_id` and `content_hash` metadata stay on the blob; generated child
fields must not be described as carrying them unless separately verified. Native
indexing is asynchronous, not exactly-once or a Blob/Search transaction. Rename,
delete, stale-child reconciliation and historical-version retention remain separate
requirements. Initialization checks all six definitions before creating missing
ones and refuses mismatches. It never deletes definitions or migrates the old index.
The datasource-only exceptions are reviewed `-RebindDataSource` and opt-in
`-RefreshDataSourceBinding` for a valid configuration-matched receipt with a stale
ETag; both use a conditional PUT. A matching current receipt remains read-only.
See [receipt gates](native-ingestion.md#datasource-receipt-and-resume). Creation of
an enabled indexer starts indexing, but initialization does not wait for it or
report indexed acceptance.

Requests are bounded JSON commands, not upload bodies: only
`{"mode":"fixture","fixtureId":"accelerator-v1"}` or `{"mode":"sharepoint"}`
is accepted. Source overrides, query parameters, duplicate JSON keys and arbitrary
URLs are rejected. PDF, PNG and JPEG are checked by extension, media type and file
signature. TXT requires valid UTF-8, optionally with a BOM, and `text/plain` with
an optional UTF-8 charset. Raw bytes are preserved. The default source limit is
5 MiB, with a configurable ceiling of 10 MiB;
request JSON is capped at 4 KiB and upstream results at 10 MiB. Extraction and
chunking are no longer bounded by a Function CU polling loop. The `PT5M` indexer
schedule is not a whole-request latency or freshness guarantee.

Terraform state is deployment truth and contains sensitive values. azd state tracks
environment/toolbox/agent context. Neither should be committed or copied as a login
cache. Retention, deletion propagation, backup restoration and recovery times are
not certified. See [operations.md](operations.md).

## Configuration versus implementation

### Exposed inputs

[Root variables](../terraform/variables.tf) are the accelerator's Terraform input
surface. [Root wiring](../terraform/main.tf) decides which module options are actually
exposed. Editing an app setting in the portal is not a durable substitute for
changing its source owner; a later apply/deploy can replace it.

| Input surface | Existing controls | What they do not do |
| --- | --- | --- |
| Root Terraform deployment | `subscription_id`, `prefix`, `primary_region`, `secondary_region`, `tags` | Region defaults are `centralus`/`southcentralus`; changing them can replace resources, not replicate or fail over data |
| Root Search tier | `search_sku`, default `standard` (S1); also accepts `standard2` and `standard3` | Direct private enrichment requires eligible service creation date and high-capacity region for embeddings; not the generated private Blob KS S2 path |
| Root operator/runner | `jumpbox_size`, `jumpbox_admin_username`, `my_object_id` | VM sizing or operator grants do not add application callers |
| Root runtime identity | `native_agent_principal_id` | Grants the discovered hosted instance its roles; do not substitute a blueprint, project or arbitrary principal |
| Root source selection | `sharepoint_hostname`, `sharepoint_site_path`, `sharepoint_file_path` | Selects one file in the site's default drive; does not enumerate a library, grant consent or sync changes |
| Stage entrypoint | `-Stage`, `-SubscriptionId`, `-EnvironmentName`, `-TerraformDir`, `-ToolManifestPath`, `-Resume` | Orchestrates reviewed work; it is not a GitHub/OIDC deployment entrypoint |
| Preflight overrides on entrypoint | `-PrimaryRegion`, `-SecondaryRegion`, `-JumpboxSize` | Feed preflight and the source fingerprint; keep them aligned with Terraform inputs, not as a replacement for those inputs |
| Planner and ingestion definitions | Initializer requires output-derived Search, primary planner, secondary storage/UAMI/CU/OpenAI and model inputs | Planner and ingestion accounts must be distinct; configuration read-back is separate from indexing acceptance |
| Native deployment helper | `-ProjectId`, `-Location`, `-ProjectEndpoint`, `-ModelDeployment`, `-SearchEndpoint`, `-SearchConnectionName`, `-EnvironmentName`, `-ReadOnly`, `-AzdDebug` | Defaults come from Terraform outputs when project ID is omitted; explicit project overrides must supply the full matching set. Read-only metadata is not runtime acceptance |

The staged workflow resolves names from Terraform outputs into runner manifests.
Keep that flow when extending it: do not hardcode generated resource suffixes,
copy login caches or erase an unresolved deployment attempt to force a new version.

### Module and runtime controls

These controls exist, but are **not all root Terraform variables or CLI switches**.

| Owner | Current setting | Required change surface |
| --- | --- | --- |
| [Function module inputs](../terraform/modules/ingest-function/variables.tf) | `enable_synthetic_fixture = true`, `max_document_bytes = 5242880` | Source/staging controls only; no Function Search index or extraction ownership |
| Function module caller map | `authorized_caller_principal_ids` | Root supplies only the jumpbox MI; add an approved principal in root wiring so auth settings and API app-role assignments remain consistent |
| Function app settings | `INGEST_*`, `SP_*`, `STAGING_BLOB_ENDPOINT`, `STAGING_CONTAINER` | Managed in Function Terraform; CU/Search settings and roles are removed from this path |
| Function code bounds | Three HTTP attempts, capped retry delay, allowed file types and request/result limits | Constants and validation in the Function, not extraction/chunking tuning flags |
| [Foundry module inputs](../terraform/modules/foundry-agent-private/variables.tf) | Search SKU, model definitions and platform capacities | Search S1 is the local default; review root overrides, eligibility, live cost and approval before changing a deployed tier |
| Search/Cosmos resource code | Search has one replica/partition; Cosmos has one `geo_location` | Capacity/availability changes require resource design and code, not an existing HA flag |
| Function/host compute | Function maximum 40 instances with 2048 MiB; hosted agent 1 CPU/2 GiB | Function resource code and agent manifest respectively; these allocations are not tested throughput promises |
| Hosted environment | `FOUNDRY_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`, `SEARCH_ENDPOINT`, `SEARCH_TOOL_NAME`, `FOUNDRY_IQ_KNOWLEDGE_BASE`, `TOOLBOX_NAME` | Current binding is `spo-native-knowledge-base`/`foundry-rag`; use this environment's outputs, never another sample's IDs |
| Hosted timeout | `RETRIEVAL_TIMEOUT_SECONDS`, default 120, greater than zero and at most 900 | Runtime reads it, but the manifest does not currently pass it. Wire the environment explicitly; it bounds tool/synthesis operations, not a single overall SLA |
| Caller timeout | `ask_agent.py --timeout`, default 900, greater than zero and at most 900 | Separate from runtime timeout. Client also takes `--project-endpoint`, `--agent-name`, `--model`, `--search-tool-name`, `--question` |
| Search toolbox | `index_name: spo-native-index`, `query_type: vector_semantic_hybrid`, `top_k: 5` | Template, deployment matching and current-question validation must agree; live fixture retrieval passed |
| Knowledge initializer | Shared ingestion/index contracts and `-SchemaPath`/`-ContractPath` | Six explicit definitions with configuration-only read-back; existing mismatches require approved resolution, not automatic updates |

Direct private indexers with built-in skills support S1+ on services created after
April 3, 2024; embeddings also need a high-capacity region. The current Central US
Search service was created September 9, 2026. Its exact CU/embedding path passed
live fixture acceptance. The generated private `azureBlob` KS S2+ requirement and
earlier S2 quota failure do not govern this `searchIndex` path. See
[the eligibility references](native-ingestion.md#identity-network-and-cost-review).

## Extension playbooks

The following distinguish the deployed native contract from additional development.
Chunking and hybrid retrieval passed fixture-backed validation; broader corpus,
quality and lifecycle changes need separate acceptance and approval.

### Connect a real SharePoint document

**Implemented path; actual integration deferred because no sample is available.**
The structure is accepted for publication, not as technical proof or permission
approval. This is a configured-file import, not a SharePoint crawler or
per-document security-trimming service. A manual Blob test or fixture cannot prove
SharePoint access. The attempted source read and consent blockers are preserved in
[VALIDATION.md](VALIDATION.md#current-native-follow-up).

1. Choose a uniformly authorized test document and set the root SharePoint inputs.
    Use a tenant `*.sharepoint.com` hostname, an absolute site path such as
    `/sites/Example`, and a file path relative to the default drive, without a leading
    slash. Start with a PDF/PNG/JPEG or valid UTF-8 TXT within the configured byte limit. Apply reviewed
    configuration through the deployment process; request bodies cannot override it.
2. Have the tenant/site administrator approve the Function MI's Graph
    `Sites.Selected` application role **and** a `read` grant on that site using
    [Grant-SharePointAccess.ps1](../scripts/Grant-SharePointAccess.ps1) with `-Role read`.
    `Sites.Selected` alone grants no site access. If the consenting client needs
    `Sites.FullControl.All`, that belongs to the approved administrative client,
    never the Function. Stop on denied consent; do not fall back to tenant-wide read.
3. Verify public Graph HTTPS egress and the configured SharePoint download host from
    the private runner/Function path. The fetcher validates redirects against the
    configured host and does not forward the Graph bearer token to the download URL.
    An unexpected redirect or unsupported document type is a failure to investigate,
    not a reason to remove host/type checks.
4. Use [Invoke-IngestFunction.ps1](../scripts/jumpbox/Invoke-IngestFunction.ps1) with
    `-Mode sharepoint`, the output-derived `-FunctionHostname` and `-ApiClientId`,
    from the approved private caller. Require `202 staged`, verify blob HEAD metadata
    against `source_id`/`content_hash`, then verify fresh native indexing and child
    `doc_url` equal to `blob_url`. Ask a fact through the native client and rerun
    unchanged staging/indexing; child citations are not original SharePoint links.

**Acceptance:** authorized import and stable rerun pass, both retrieval results
ground a known fact with real source metadata, and an unknown fact remains unknown.
Keep missing/invalid/unapproved caller and source-override rejection tests. Denied
site consent must not produce successful ingestion. The existing
[end-to-end harness](../scripts/jumpbox/Invoke-EndToEnd.ps1) defaults to fixture;
`-Mode sharepoint` requires explicit `-Question` and `-ExpectedAnswer` from the
intended file and retains all provenance/indexing/retrieval guards. See the
[private verification example](native-ingestion.md#private-sharepoint-verification).

### Use a custom corpus and chunking

**Native chunking is deployed; broader source management needs code.** The native contract
requires semantic 500-token/zero-overlap chunks and child-only projections. The
service owns their generation, not a custom Function writer. There is no arbitrary
upload, library enumeration or complete source-sync/deletion implementation.

For new adapters, retain allowed-source, credential, byte/type and canonical-identity
checks. Review rename/delete behavior and stale-child reconciliation explicitly.
Test provider-generated keys, parent associations, unchanged restaging, changed
bytes, concurrent overwrites and missing/empty chunks. The skillset is explicit,
but the initializer will not update an existing mismatch: stop for an approved
compatibility/migration decision as described in [native ingestion](native-ingestion.md).

**Acceptance:** fresh indexed children retain correct staged-source associations,
both retrieval paths answer known facts, and absent facts remain unknown. Images,
location metadata, deletion and larger-corpus behavior need their own live evidence.

### Add vector or hybrid retrieval

**Deployed and fixture-validated.** Native ingestion uses
secondary `text-embedding-3-large`, a 3072-dimensional child vector and a query-time
vectorizer. The toolbox now selects `vector_semantic_hybrid`. Strict read-back must
establish the embedding identity, endpoint, model, dimensions, vector profile and
semantic configuration. These are explicit skillset/index settings, not generated
KS template options. Mismatches block; do not add custom Function embedding code.

**Acceptance:** explicit definitions, IQ, toolbox, graph, caller and deployment
read-back agree, fresh child indexing succeeds, and both required current tool calls
pass. Verify dimension mismatches, missing vectors, failures and citations in local
tests; compare live known/unknown questions, relevance, latency and costs only after
separate approval. Vectors were not retrievable in the accepted run: the evidence
is the 3072-dimensional schema and successful query pipeline, not an array readback
or a relevance benchmark.

### Add another tool

**Code extension required.** Adding a YAML entry or prompt instruction is insufficient:
the runtime and deployment helper enforce exactly one toolbox tool, and the caller
expects exactly IQ then Search. The graph, not the model, initiates these calls.

1. Define the new tool's typed arguments, read/write authority, identity, endpoint,
    result shape and whether its result is required for an answer. Any action-taking
    tool needs a separately approved authorization/confirmation design; current
    synthesis has no tools or action authority.
2. Update toolbox/connection deployment and its matching predicate. In
    [create_graph](../src/foundry_native_agent/main.py), add explicit invocation and
    result-gate behavior with current call IDs, bounded timeouts and usable-output
    checks. Update the evidence-set gate before synthesis. Keep retrieved content
    untrusted and final synthesis tool-free.
3. Change the runtime name/schema allowlist, source metadata handling, caller trace
    validator and private end-to-end expectations together. Required-tool failure must
    prevent success; any optional-tool degradation needs an explicit tested contract.
4. Extend [test_retrieval.py](../tests/test_retrieval.py) and
    [Test-NativeDeployment.ps1](../tests/Test-NativeDeployment.ps1) for ordering, duplicate
    or stale IDs, truncated arguments, empty/error outputs, timeout, extra unexpected
    tools and synthesis failure. Retain the full current question across turns.

**Acceptance:** a prompt cannot skip a required tool or accept an old result; client
and graph reject the same invalid traces. Exercise prompt-like instructions in tool
data, check citations and test the new version from a private caller. Any approved
change to diagram semantics requires separate review, not an automatic rerender.

### Operationalize ingestion and retention

**Not implemented:** durable application work queues, scheduled SharePoint source sync, chunk reconciliation,
dead-letter handling, lifecycle deletion and a tested recovery SLO. Host-storage
Queue/Table permissions do not mean the application has a durable ingestion queue.

1. Preserve the distinction between `202 staged` and indexed completion. The native
    `PT5M` schedule is not a durable application work queue. Choose an idempotency key
    using source/version identity, and persist processing state that can survive a
    Function restart. Keep the caller's request ID as correlation, not deduplication.
2. Implement bounded workers, backpressure, per-stage retry policy, poison-work
    handling and explicit replay. Reconcile staged bytes and native indexer results
    after ambiguous failures; do not blindly retry an indexer run or KS creation.
    Couple batching and concurrency to measured CU, Search, model and Function limits.
3. For large sources, validate the [chunking contract](#use-a-custom-corpus-and-chunking)
    before increasing limits. The Function's 40-instance maximum and 2048 MiB setting
    are source allocations, not a proven workload envelope. Test contention on the
    same source, throttling, partial batches and extraction expansion in memory.
4. Define retention/deletion separately for source files, stable staging blobs, current
    Search documents/chunks, platform agent state, diagnostic exports and Terraform/azd
    state. Implement propagation and reconciliation, including external SharePoint
    grants. The fixture's **30-day retention answer is corpus content**, not a configured
    Azure lifecycle policy. Decide backup/restore ownership and verify recoverability.

**Acceptance:** interrupt after staging, extraction and partial indexing; replay must
converge without lost work or stale searchable content. Poison work must be visible
and recoverable. Demonstrate deletion and restore against an approved test source,
measure recovery time and verify access to retained copies. These are new acceptance
tests, not results claimed by the current fixture rehearsal.

### Expand regions versus add HA or DR

**Placement inputs exist; HA/DR and additional-region orchestration do not.** The
two regions host different capabilities, so SCUS cannot replace the CUS application
stack merely because it has a Foundry account.

1. For relocation, review `primary_region`/`secondary_region` and matching preflight
    arguments together. Check region/model/SKU capacity, delegated subnet support,
    private-link features and data-residency policy in the intended environment.
    GlobalStandard resource placement does not guarantee two-region inference residency.
2. Review [locals.tf](../terraform/locals.tf): the two hub/spoke address plans and
    `cus`/`scus` naming tokens are fixed for the two roles. Then review DNS links,
    firewall transit, capability-host dependencies, output contracts and private-runner
    scripts. A third region requires new reviewed wiring; there is no region-list flag.
    Do not use identical primary/secondary values as an assumed single-region mode.
3. Review a full Terraform plan for replacements and migration consequences before
    applying. Preserve source/index/state recovery options, and follow the existing
    account-delete/purge ordering if approved replacements require removal. Region
    changes must not silently discard a corpus or reuse stale deployment checkpoints.
4. For availability or disaster recovery, first choose failure scenarios, SLO, RTO and
    RPO. Design state/data replication or rebuild, traffic selection, independent
    capacity, identities, DNS, ingestion continuity and failback as a separate change.
    Search currently has one replica/partition; Cosmos has one region and
    `automatic_failover_enabled = false`. Storage redundancy alone does not recover
    the full application. No existing Terraform flag adds application HA/DR.

**Acceptance:** relocated deployments repeat private DNS/routing, authorized ingestion,
provenance, both retrieval paths and public-refusal checks. HA/DR additionally needs
approved outage/failback drills proving the chosen RTO/RPO, correct authorization and
no stale or missing evidence. The accepted two-region fixture run is not that proof.

### Introduce private deployment CI

**Hosted validation exists; automated private deployment CI is not implemented.**
[repository.yml](../.github/workflows/repository.yml) runs pinned cloud-free Windows
release checks, Linux runtime checks and a secret scan with read-only repository
permissions. Its successful run does not prove hosted runners can reach private
data planes. The current entrypoint explicitly rejects GitHub/OIDC authentication.

1. Keep pull-request checks separate from deployment authority. Have a repository
    administrator configure reviewed required checks/protections; `main` is currently
    unprotected. Do not give untrusted pull-request code a privileged private runner,
    tenant consent authority, saved state or cloud credentials.
2. Design and implement a supported noninteractive deployment-auth path before adding
    a workflow. Scope ARM and tenant Graph/AzureAD permissions separately, define
    approval gates, and retain plan review and instance-principal readback. Merely
    setting `ARM_USE_OIDC` on the existing entrypoint will fail.
3. Supply approved private reachability, DNS and scoped data-plane permissions for
    workload initialization and acceptance. Preserve the verified artifact/version/hash
    flow in [Send-RunnerArtifacts.ps1](../scripts/Send-RunnerArtifacts.ps1) and deployment
    helpers; do not copy workstation login caches. Protect Terraform state and stage
    checkpoints, serialize mutations and reconcile unknown attempts before rerunning.
4. Run cloud-free regression gates first, then separately approved infrastructure,
    workload and live verification stages. Retain build status, source/package hashes,
    agent/toolbox versions and sanitized acceptance evidence, not raw state or tokens
    in public workflow artifacts.

**Acceptance:** an unauthorized branch cannot deploy; an approved identity can perform
only the intended scoped actions; incompatible or failed gates block promotion.
Exercise interrupted-run recovery without duplicate deployments. Private acceptance
must validate actual Function/agent calls, not just a successful ARM Run Command.

### Add observability and cost controls

**Partial foundation, not a complete monitoring or cost-management solution.**
The Function logs request ID, stage, status and elapsed time, and
[host.json](../src/ingest_func/host.json) contains Application Insights sampling
settings. These do not establish a telemetry destination, all service diagnostic
categories, alert delivery or private monitoring ingestion. No AMPLS, tested alert
coverage or current pricing estimate is claimed.

1. Define a correlation and metrics contract across ingestion, CU, indexing, IQ,
    toolbox and synthesis: request/source IDs as appropriate, versions, outcome,
    latency, throttling, empty evidence and failures. Instrument missing spans and
    preserve current sanitized error behavior. Sampling must not hide required failure
    evidence; document what is measured versus inferred.
2. Configure approved diagnostic destinations/categories and access/retention for each
    relevant service, including network denials and private-runner deployment failures.
    Assess telemetry egress separately from application Private Link. Never collect
    bearer tokens, raw documents or credential/state files as default diagnostics.
3. Add dashboards and actionable alert thresholds with named responders. Test delivery
    with controlled failure evidence, including auth rejection, indexing item failure,
    retrieval timeout and missing source metadata. Distinguish service denial from
    identity denial; track cold starts and the latency of two serial retrievals plus
    synthesis before setting a latency target.
4. Inventory persistent charges for two secured hubs/firewalls, Bastion, Search,
    Cosmos, storage and disks, plus model tokens, CU, Function/build usage, logs and
    cross-region transfer. Obtain a dated estimate for actual region/SKU/volume choices,
    configure budgets/alerts and measure cost per ingestion/answer. Adjust capacity
    only with measured performance and availability tradeoffs.

**Acceptance:** a test request can be followed across the intended stages without
sensitive content leakage; an injected failure reaches the responsible operator;
retention is demonstrable. Compare measured usage with the estimate and record the
cost/latency effect of changes. [Stop-Lab.ps1](../scripts/Stop-Lab.ps1) `-Mode Pause`
only deallocates the jumpbox; it is not a zero-cost pause. Teardown is a separately
approved destructive operation, not a budget-control automation toggle.

### Close an extension with evidence

1. Record the changed source/configuration owners, expected data/trace contract and
    compatible package, schema, agent and toolbox versions. Decide rollback and
    migration handling before mutating an existing environment.
2. Add focused tests at the owning boundary, then run applicable repository gates as
    described in [automation.md](automation.md). Use its isolated, pinned runtime
    environments; Function and hosted-agent Python versions differ. For a release,
    [Test-Repository.ps1](../scripts/Test-Repository.ps1) `-Terraform -Release` is the
    full local gate, not a cloud acceptance check.
3. After scoped deployment approval, rerun the relevant private acceptance path and
    [public refusal checks](../scripts/Test-PublicDataPlaneRefused.ps1). Keep known-fact,
    exact technical-value and unknown-answer cases, provenance readback and caller
    denial tests. A separate valid-but-unapproved app token remains a live test gap
    in the recorded baseline.
4. Record local and live results separately using [VALIDATION.md](VALIDATION.md) as
    the evidence model. Do not promote an untested extension, a model-generated answer
    or the optional evaluation seed into a passed deployment or cloud evaluator score.
    Track residual work in Beads and summarize evidence in [STATUS.md](STATUS.md). Any topology change needs renewed
    approval of the complete diagram contracts; these docs do not authorize it.

## Decisions and Well-Architected review

| Decision | Why | Tradeoff | Validation status |
| --- | --- | --- | --- |
| Split regional capabilities with two secured hubs | Separate source staging, ingestion dependencies and retrieval | More latency/cost/dependencies; no HA | Native Search dependency paths passed fixture-backed acceptance |
| PaaS Private Link plus separate compute injection | Separate inbound access from outbound execution | DNS, routing, approval and platform ordering complexity | Three secondary links and primary planner link Approved/Succeeded; public denial passed |
| Entra API app role and distinct workload identities | Authorize callers separately from staging and ingestion | Tenant bootstrap, new UAMI/RBAC and propagation | Seven live authorization/staging probes passed; SharePoint consent remains unproven |
| Deterministic dual retrieval before synthesis | Reject missing/current-question tool failures | Two serial retrievals and model latency; shared corpus | Strict IQ-then-hybrid-Search with cited sources passed on agent 3/toolbox 2 |
| Explicit native ingestion and hybrid index | Azure Search executes configured CU/chunks/vectors without Function processing | Preview compatibility and existing mismatches can block; no automatic migration or ACL trimming | Fixture indexing and repeated normal Verify passed |
| Keep GlobalStandard defaults and broad POC egress explicit | Expose placement/security tradeoffs | No two-region processing guarantee or zero-trust claim | Historical preflight only; current capacity, cost and residency remain gates |

**Reliability:** one Search replica and single-region Cosmos state are POC constraints.
There is no durable ingestion queue, tested failover, SLO, RTO or RPO. Bounded retries
and explicit failure gates do not provide transactional ingestion or automatic recovery.

**Security:** tokens/roles and private routes are complementary. Shared-index access
does not trim results by SharePoint user ACL. Prompt injection, broad egress,
privileged private runners and state exposure remain risks. Use a uniformly
authorized test corpus, no public/API-key fallback, and reviewed tenant bootstrap.

**Cost optimization:** hubs, firewalls, Bastion and Search persist while the VM is
deallocated. Model tokens, cross-region data, builds, logs and storage add variable
cost. Search S1, scheduled CU/image/embedding processing and query vectorization
need explicit cost review. No current pricing estimate has been verified in this pass.

**Operational excellence:** ordered stages, exact-ID teardown/purge, preserved state,
and machine-readable outcomes exist. The full local release gate and repeated
normal Verify passed; a clean full orchestrator run and deletion acceptance remain
unproven.
Historical hosted CI passed, but protected
branches/required merge checks are not configured. Record tool
versions and request IDs without tokens/document bodies. Diagnostics settings and
alert coverage need live review; no centralized monitoring completeness is claimed.

**Performance efficiency:** scheduled native extraction/indexing, serial IQ/toolbox
calls and synthesis, Function cold starts and cross-region dependencies affect latency. Throughput, concurrency,
throttling and token quotas need measured budgets; no load-test result is implied.

## Evidence status

| Claim | Classification | Evidence or next gate |
| --- | --- | --- |
| Prior infrastructure/DNS/CU/IQ checks and hosted-agent v5 smoke | Historical | Recorded for the previous lab, not rerun here; no old pass count is promoted |
| Original Function authorization, custom fixture pipeline and deterministic runtime | Historical v1 live evidence | Dated ingestion/provenance/dual-tool results in [VALIDATION.md](VALIDATION.md), not native KS acceptance |
| Original Mermaid syntax/render and PNGs | Historical approved assets | Original custom-ingestion design; unchanged and not rerendered here |
| Native Function staging and explicit definitions | Fixture-validated live | Six version-2 definitions; full local gate and live acceptance in [VALIDATION.md](VALIDATION.md#current-native-follow-up) |
| Native orchestration | Manual migration/recovery and repeated normal Verify passed | Clean full orchestrator run and deletion acceptance remain unproven |
| Fresh native indexer, child chunks, IQ/hybrid acceptance | Passed live | Blob HEAD/provenance, fresh indexing and strict matched retrieval; no direct vector-array readback |
| New native diagram contract | Review pending | Approval required before authoring/rendering; historical images are not this contract |
| Actual SharePoint cross-region ingestion | Deferred; no sample available | Structure accepted, not acquisition proof or grant approval; attempted-source blockers retained in validation history |
| Public network denial | Passed live | Three authenticated endpoints returned explicit `NetworkDenied` 403s; new deployments must repeat |
| Bastion interactive RDP | Not tested here | Historical Run Command is not RDP evidence |
| Full local release checks | Passed | 81 Python tests, zero skips, PowerShell 7/5.1 checks, five mocked Terraform tests and documentation checks; dated evidence in [VALIDATION.md](VALIDATION.md#current-native-follow-up) |
| Hosted GitHub CI | Historical pass | Linked publication run in [VALIDATION.md](VALIDATION.md#publication), not current refactor evidence |
| Required merge checks on `main` | Not configured | Read-only publication verification found no branch protection or rulesets; passing CI is not enforcement |
| Cloud-scored evaluation | Not run | Direct golden questions are not evaluator scores |

## Review notes

1. Region/SKU/model capacity and customer data-residency acceptance remain live gates.
    GlobalStandard inference can process outside the two resource regions.
2. Private runner tools and workload behavior passed the recorded rehearsal with
    recovery; new environments must validate their own permissions and bootstrap.
3. The historical diagrams intentionally omit detailed telemetry/install-feed edges and exact
    private environment names/IDs. The identity table and guides carry those constraints.
4. Preview API dates are not blanket service-preview labels; use the source matrix
    and dated first-party feature guidance in [compatibility.md](compatibility.md).
5. First-party references accessed 2026-09-09:
    [Foundry network isolation](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link)
    and [deployment types](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types).

## Human review

Keep the linked original Mermaid contracts and PNGs historical and unchanged.
Review the native ownership, UAMI/three-secondary-link topology, preserved primary
planner path, generated chunks, staged-blob citations and failure gates before
authoring a replacement contract. Approval must identify the exact new semantics
before rendering. The current baseline is the fixture-backed S1 acceptance and
repeated normal Verify, not the historical v1 rebuild. SharePoint integration is
deferred without blocking publication; acceptance of the structure grants no
additional access and makes no production-readiness claim.
