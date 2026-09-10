# Architecture

## Interpretation

This reference POC separates capabilities across two regions; it does not provide
active-active service or regional disaster recovery. The outcome is an authorized
document-to-grounded-answer demonstration with explicit network, identity and
retrieval failure boundaries. Source review date: **2026-09-10**.

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
The full live rebuild and end-to-end acceptance passed with scoped recovery, as
recorded in [VALIDATION.md](VALIDATION.md), not as one uninterrupted script run.
Hosted CI also passed; `main` remains unprotected and passing checks are not enforced
merge requirements. Current follow-up work is tracked in [STATUS.md](STATUS.md).
Detailed order and bootstrap limits are in
[deployment.md](deployment.md#ordered-stages).

## Components and boundaries

### Source ownership map

Use this map to find the code that controls a behavior before changing a deployment
setting. These are existing components, not additions to the approved topology.

| Component | Owning source/configuration | Responsibility and change boundary |
| --- | --- | --- |
| Accelerator stages | [Invoke-Accelerator.ps1](../scripts/Invoke-Accelerator.ps1), [outputs.tf](../terraform/outputs.tf) | Reviewed stages, source fingerprints, private-runner payloads, output-derived endpoints and native identity readback; changed source is not an unchanged resume |
| Regional wiring and private transit | [main.tf](../terraform/main.tf), [locals.tf](../terraform/locals.tf), [secured hubs](../terraform/modules/vwan-secured/main.tf) | Two spokes/hubs, address spaces, DNS inventory, routing intent and egress policy; region names alone do not define a new topology |
| Foundry platform and planner | [foundry.tf](../terraform/modules/foundry-agent-private/foundry.tf), [platform dependencies](../terraform/modules/foundry-agent-private/main.tf), [Ensure-AgentCapabilityHost.ps1](../scripts/Ensure-AgentCapabilityHost.ps1) | Accounts/projects, models, connections, RBAC, capability host, Search shared private link and Storage/Cosmos state |
| Function hosting and API identity | [Function infrastructure](../terraform/modules/ingest-function/main.tf), [auth.tf](../terraform/modules/ingest-function/auth.tf), [authorization.py](../src/ingest_func/authorization.py) | Private ingress, separate outbound integration, workload MI, app settings, API role and token/caller checks |
| Source acquisition and extraction | [function_app.py](../src/ingest_func/function_app.py), [synthetic_fixture.py](../src/ingest_func/synthetic_fixture.py), [CU/staging infrastructure](../terraform/modules/foundry-content-understanding/main.tf) | Constrained source selection, bounded fetch, immutable byte staging, CU polling/extraction and checked Search writes |
| Optional SharePoint consent | [Grant-SharePointAccess.ps1](../scripts/Grant-SharePointAccess.ps1) | Graph application role plus one site grant for the Function MI; does not configure caller-level Search filtering |
| Knowledge definitions | [search-index.json](../src/shared/search-index.json), [Initialize-KnowledgeBase.ps1](../scripts/Initialize-KnowledgeBase.ps1), [New-FoundryIqKnowledgeBase.py](../scripts/New-FoundryIqKnowledgeBase.py) | Canonical text/semantic schema and IQ knowledge source/base; the staged initializer is PowerShell, and the Python helper must remain schema-compatible |
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

### Application identity versus caller authorization

Outbound workload authentication and inbound caller authorization are separate
contracts. `DefaultAzureCredential` lets the Function acquire service-specific
tokens for Blob, CU, Search and optional Graph access. Those grants do not authorize
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
Staging stores source bytes, and Search stores derived text/provenance. The canonical
[index schema](../src/shared/search-index.json) has no vector fields. The provisioned
embedding model does not make this a vector pipeline. IQ wraps the same index through
its knowledge source; the toolbox remains `query_type: simple`.

The ingestion response/document preserves stable source identity, content hash and
document ID, with a separate request ID for correlation. A partial failure may leave
staged bytes; reruns need reconciliation, not success inferred from partial output.
Platform agent state uses configured Storage/Cosmos dependencies; application graph
state is not a claim of a tested durable conversation-recovery mechanism.

### Schema and integrity contract

The schema and [Function implementation](../src/ingest_func/function_app.py) are a
single producer/consumer contract. Today, one accepted source becomes **one Search
document**, not a collection of chunks.

| Field or identifier | Current meaning | Extension constraint |
| --- | --- | --- |
| `id` / response `document_id` | Search key equals `source_id` | Preserve repeat-ingestion identity; chunking needs a new key strategy |
| `source_id` | SHA-256 of canonical JSON containing source kind, lowercased hostname and NFC-normalized/lowercased site/file paths | Path-based identity, not a SharePoint immutable item ID; renames require reconciliation |
| `content_hash` | SHA-256 of the original bytes, stored in Search and Blob metadata | Detects byte changes, not extraction quality or factual correctness |
| `title`, `content` | Filename and nonempty CU Markdown; searchable/retrievable text | Semantic configuration prioritizes these fields; no vector or ACL fields exist |
| `source_url` | Validated SharePoint web URL or fixture URN | Provenance only; not an access grant or proof of sentence-level entailment |
| `request_id` | New UUID per invocation, returned in JSON and `X-Request-ID` and used in logs/upstream requests | Correlation only; not a deduplication key or Search schema field |

Staging uses `source_id/content_hash` plus the source extension and does not overwrite
existing blobs. Search uses `mergeOrUpload` by stable source key. The response is
`indexed` only after the one expected Search result has the matching key,
`status: true` and status code 200 or 201. An HTTP success with an item-level failure
is rejected. Repeating unchanged input retains document identity but still performs
extraction/indexing; this is not exactly-once processing or a transaction across
Blob, CU and Search. Changed bytes can leave older staging blobs, and deleting or
renaming a source does not delete its Search entry automatically.

Requests are bounded JSON commands, not upload bodies: only
`{"mode":"fixture","fixtureId":"accelerator-v1"}` or `{"mode":"sharepoint"}`
is accepted. Source overrides, query parameters, duplicate JSON keys and arbitrary
URLs are rejected. PDF, PNG and JPEG are checked by extension, media type and file
signature. The default source limit is 5 MiB, with a configurable ceiling of 10 MiB;
request JSON is capped at 4 KiB, upstream results at 10 MiB and extracted Markdown
at 2 MiB. CU polling has a 180-second deadline check and at most 40 iterations;
network timeouts/retries mean this is not a whole-request latency guarantee.

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
| Root operator/runner | `jumpbox_size`, `jumpbox_admin_username`, `my_object_id` | VM sizing or operator grants do not add application callers |
| Root runtime identity | `native_agent_principal_id` | Grants the discovered hosted instance its roles; do not substitute a blueprint, project or arbitrary principal |
| Root source selection | `sharepoint_hostname`, `sharepoint_site_path`, `sharepoint_file_path` | Selects one file in the site's default drive; does not enumerate a library, grant consent or sync changes |
| Stage entrypoint | `-Stage`, `-SubscriptionId`, `-EnvironmentName`, `-TerraformDir`, `-ToolManifestPath`, `-Resume` | Orchestrates reviewed work; it is not a GitHub/OIDC deployment entrypoint |
| Preflight overrides on entrypoint | `-PrimaryRegion`, `-SecondaryRegion`, `-JumpboxSize` | Feed preflight and the source fingerprint; keep them aligned with Terraform inputs, not as a replacement for those inputs |
| Planner definition | Entrypoint `-PlannerDeployment`/`-PlannerModel`; initializer `-FoundryOpenAIEndpoint`, `-SearchEndpoint`, `-PlannerDeployment`, `-PlannerModel` | Selects an existing deployment for IQ; it neither creates model capacity nor changes the synthesis model |
| Native deployment helper | `-ProjectId`, `-Location`, `-ProjectEndpoint`, `-ModelDeployment`, `-SearchEndpoint`, `-SearchConnectionName`, `-EnvironmentName`, `-ReadOnly`, `-AzdDebug` | Defaults come from Terraform outputs when project ID is omitted; explicit project overrides must supply the full matching set. Read-only metadata is not runtime acceptance |

The staged workflow resolves names from Terraform outputs into runner manifests.
Keep that flow when extending it: do not hardcode generated resource suffixes,
copy login caches or erase an unresolved deployment attempt to force a new version.

### Module and runtime controls

These controls exist, but are **not all root Terraform variables or CLI switches**.

| Owner | Current setting | Required change surface |
| --- | --- | --- |
| [Function module inputs](../terraform/modules/ingest-function/variables.tf) | `enable_synthetic_fixture = true`, `max_document_bytes = 5242880`, `search_index = "spo-docs"` | Root currently uses defaults; wire module arguments or deliberately expose new root inputs. Runtime fixture enablement fails closed when the setting is absent |
| Function module caller map | `authorized_caller_principal_ids` | Root supplies only the jumpbox MI; add an approved principal in root wiring so auth settings and API app-role assignments remain consistent |
| Function app settings | `INGEST_*`, `SP_*`, `CU_ENDPOINT`, `SEARCH_ENDPOINT`, `STAGING_BLOB_ENDPOINT`; fixed `CU_ANALYZER_ID = prebuilt-document`, `STAGING_CONTAINER = spo-staging` | Managed in Function Terraform; analyzer/container changes need compatible permissions, extraction handling and tests |
| Function code bounds | Three HTTP attempts, capped retry delay, CU polling limit, allowed file types, request/result/extraction limits | Constants and validation in the Function, not root tuning flags; increasing input size alone does not remove extraction or timeout limits |
| [Foundry module inputs](../terraform/modules/foundry-agent-private/variables.tf) | `search_sku`, `cosmos_total_throughput_limit`, `chat_model`, `agent_tool_model`, `embedding_model` | Root currently leaves module defaults. Models specify name/version/capacity; deployment SKU is defined in the resource code |
| Search/Cosmos resource code | Search has one replica/partition; Cosmos has one `geo_location` | Capacity/availability changes require resource design and code, not an existing HA flag |
| Function/host compute | Function maximum 40 instances with 2048 MiB; hosted agent 1 CPU/2 GiB | Function resource code and agent manifest respectively; these allocations are not tested throughput promises |
| Hosted environment | `FOUNDRY_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`, `SEARCH_ENDPOINT`, `SEARCH_TOOL_NAME`, `FOUNDRY_IQ_KNOWLEDGE_BASE`, `TOOLBOX_NAME` | Manifest passes deployment context; helper fixes KB/toolbox names to `spo-knowledge-base`/`foundry-rag`, so a rename is coordinated work |
| Hosted timeout | `RETRIEVAL_TIMEOUT_SECONDS`, default 120, greater than zero and at most 900 | Runtime reads it, but the manifest does not currently pass it. Wire the environment explicitly; it bounds tool/synthesis operations, not a single overall SLA |
| Caller timeout | `ask_agent.py --timeout`, default 900, greater than zero and at most 900 | Separate from runtime timeout. Client also takes `--project-endpoint`, `--agent-name`, `--model`, `--search-tool-name`, `--question` |
| Search toolbox | `index_name: spo-docs`, `query_type: simple`, `top_k: 5` | Change the template **and** deployment helper's matching predicate. Runtime/client permit only the current single-question argument contract |
| Index initializer | `-SchemaPath` defaults to canonical schema | Still rejects a name other than `spo-docs` or a changed six-field name/order list; not a generic schema-migration switch |

## Extension playbooks

The following are bounded development paths, **not implemented additions to the
approved topology**. Each calls out today's support and the acceptance needed for
a changed workload. Live checks below are future operator actions in an approved
environment, not cloud calls performed for this documentation update.

### Connect a real SharePoint document

**Implemented path; real tenant/site acceptance not run.** This is a configured-file
import, not a SharePoint crawler or per-document security-trimming service.

1. Choose a uniformly authorized test document and set the root SharePoint inputs.
    Use a tenant `*.sharepoint.com` hostname, an absolute site path such as
    `/sites/Example`, and a file path relative to the default drive, without a leading
    slash. Start with a PDF/PNG/JPEG within the configured byte limit. Apply reviewed
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
    from the approved private caller. Read Search back by returned `document_id` and
    compare `source_id`, `content_hash` and source URL. Ask a fact from that document
    through the native client and rerun unchanged ingestion.

**Acceptance:** authorized import and stable rerun pass, both retrieval results
ground a known fact with real source metadata, and an unknown fact remains unknown.
Keep missing/invalid/unapproved caller and source-override rejection tests. Denied
site consent must not produce successful ingestion. The existing
[end-to-end harness](../scripts/jumpbox/Invoke-EndToEnd.ps1) always ingests the fixture
and reports `sharepoint = not_tested`; changing its question is not SharePoint proof.

### Use a custom corpus and chunking

**Code extension required.** There is no arbitrary upload, library enumeration,
incremental sync or chunking mode. The fixture is deliberately small and constrained.

1. Define a source adapter contract in the
    [ingestion implementation](../src/ingest_func/function_app.py): allowed sources,
    credentials, canonical identity, byte/type limits and delete/rename behavior.
    Retain strict request validation; do not turn a caller-supplied URL into an
    unrestricted fetcher. Add formats only with format validation and tested CU or
    alternative extraction handling, not by widening the extension list alone.
2. Specify deterministic chunk boundaries, overlap, parent identity, chunk order and
    extraction/chunker version. Choose keys that distinguish chunks while retaining
    parent `source_id`, content hash and citation location. Define how replacing or
    deleting a parent removes obsolete chunks. Long documents currently fail the
    extraction bound rather than being automatically divided into indexed chunks.
3. Change the canonical schema, Function writer, both knowledge initializers and
    schema guards together. Use a reviewed migration/reindex plan for incompatible
    fields; the initializer never deletes an incompatible index automatically.
    Update IQ definitions, toolbox index/selection and source collection so a retrieved
    chunk cites its parent and location instead of inventing a document URL.
4. Extend [ingestion tests](../tests/test_ingestion.py),
    [schema tests](../tests/test_knowledge_schema.py) and
    [retrieval tests](../tests/test_retrieval.py) before deploying. Update readback
    helpers that currently expect one `document_id == source_id`. Check every item in
    a batch result; today's writer checks exactly one result, not a general batch.

**Acceptance:** unchanged reingestion preserves the intended chunk set; changed,
renamed and deleted parents leave no stale searchable chunks after reconciliation.
Cover filename collisions, partial batch failures, oversized/empty extraction and
malformed input. A multi-chunk known fact must retain correct source locations in
both retrieval paths; unknown-answer behavior must still pass.

### Add vector or hybrid retrieval

**Not implemented.** A provisioned embedding deployment is unused by this text
pipeline. Neither setting an embedding model nor changing `query_type` alone enables
vector retrieval.

1. Choose an embedding model/version and dimensionality, chunk strategy and migration
    plan. Extend [search-index.json](../src/shared/search-index.json) with the required
    vector fields/profiles and compatible search configuration. Update both initializer
    implementations and their strict schema checks; retain provenance fields.
2. Implement bounded embedding generation in ingestion, with identity/role and private
    endpoint dependencies, retries, batch validation and embedding-version tracking.
    Re-embed/reindex the corpus consistently; define handling of partial embedding
    failures and model/dimension changes. No embedding call exists in ingestion today.
3. Review IQ knowledge-source/base definitions and query behavior against the selected
    API/model capabilities. Update [toolbox.yaml](../toolbox.yaml) and the deployment
    matching logic for the intended vector/hybrid query. Update runtime argument/result
    validation and [the caller validator](../src/hello_world/ask_agent.py) wherever
    the query or response contract changes. Do not bypass the current-question and
    matched-output gates to accommodate a new payload.
4. Replace the current text-only schema assertion with tests for the new contract and
    add dimension mismatch, missing embedding, reindex, failure and citation tests.
    Compare known/unknown questions, retrieval relevance, latency and model/token cost
    against the accepted text baseline from a private runner.

**Acceptance:** producer, schema, IQ, toolbox, graph, caller and deployment readback
agree on the new contract. No successful answer is accepted after a required retrieval
failure. Record measured relevance/cost changes; do not assert an improvement from
the presence of vectors alone.

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

**Not implemented:** durable work queues, scheduled source sync, chunk reconciliation,
dead-letter handling, lifecycle deletion and a tested recovery SLO. Host-storage
Queue/Table permissions do not mean the application has a durable ingestion queue.

1. Define the accepted request and completion contract before introducing asynchronous
    work. Separate enqueue acknowledgement from `indexed`, choose an idempotency key
    using source/version identity, and persist processing state that can survive a
    Function restart. Keep the caller's request ID as correlation, not deduplication.
2. Implement bounded workers, backpressure, per-stage retry policy, poison-work
    handling and explicit replay. Reconcile staged bytes and checked index writes
    after ambiguous failures; do not blindly retry a non-idempotent extraction request.
    Couple batching and concurrency to measured CU, Search, model and Function limits.
3. For large sources, implement the [chunking contract](#use-a-custom-corpus-and-chunking)
    before increasing limits. The Function's 40-instance maximum and 2048 MiB setting
    are source allocations, not a proven workload envelope. Test contention on the
    same source, throttling, partial batches and extraction expansion in memory.
4. Define retention/deletion separately for source files, old staging hashes, current
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
    Record residual work in [STATUS.md](STATUS.md). Any topology change needs renewed
    approval of the complete diagram contracts; these docs do not authorize it.

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
and machine-readable outcomes are implemented. Hosted CI passed, but protected
branches/required merge checks are not configured. Record tool
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
| Hosted GitHub CI | Passed | Windows release checks, Linux runtime checks and secret scan; linked run in [VALIDATION.md](VALIDATION.md#publication) |
| Required merge checks on `main` | Not configured | Read-only publication verification found no branch protection or rulesets; passing CI is not enforcement |
| Cloud-scored evaluation | Not run | Direct golden questions are not evaluator scores |

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
