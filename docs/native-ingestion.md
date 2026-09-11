# Native ingestion: ownership and migration

## Status and scope

As of **2026-09-11, 15 UTC**, the deployed S1 native-indexer pipeline passed two
normal Verify runs after the TXT/root-site Function fixes and guarded datasource
receipt refresh. Both passed seven authorization probes, fresh fixture indexing
(1 processed, 0 failed), IQ and strict native IQ-then-Search without manual rebind
or agent deployment. The full predeployment gate passed 81 Python tests with zero
skips, initializer 12237 and end-to-end 1333 checks on PowerShell 7/5.1 (201 new mode
checks), deployment 456, five Terraform tests and 286 documentation links.
See the [validation record](VALIDATION.md#current-native-follow-up).

Actual SharePoint integration is deferred because no sample is available. The user
accepted the structure for publication; this does not prove SharePoint access or
authorize permissions. A manually staged blob or generated fixture cannot prove
that source path. The attempted-source HTTP 502, confirmed missing Function
`Sites.Selected`, and unresolved site consent/file existence are preserved in
[validation history](VALIDATION.md#sharepoint-administrator-boundary).
No directory/site/content permissions changed. Repeated normal Verify is proven;
a clean full orchestrator run and deletion acceptance are not. Historical custom
Function acceptance and the S2 attempt remain separate.

The original [implementation plan](PLAN.md), [accelerator plan](ACCELERATOR-PLAN.md)
and [diagram assets](diagrams/README.md) describe the historical custom-ingestion
design. They are retained unchanged. A replacement diagram needs a reviewed
contract covering ownership, identities, explicit resources, provenance and
failure gates before any new diagram is authored or rendered.

## Ownership contract

| Owner | Current responsibility |
| --- | --- |
| Ingestion Function | Authorize the caller, generate a fixture or fetch the configured SharePoint file, validate bytes and overwrite a stable raw blob |
| Initializer | Owns six explicit definitions: datasource, index, skillset, indexer, search-index knowledge source and knowledge base; creates only missing definitions after validating existing ones |
| Search service | Executes native Content Understanding, embedding, child projection and indexing using the explicitly configured private indexer |
| Native knowledge source | `spo-native`, kind `searchIndex`, references `spo-native-index`; it does not generate the ingestion resources |
| Knowledge base | `spo-native-knowledge-base` references `spo-native` and uses the primary account's planner |
| Native agent | Requires IQ retrieval and the versioned Search toolbox against `spo-native-index` before answer synthesis |

The [Function](../src/ingest_func/function_app.py) makes **no Content Understanding
or Search calls**. A successful response is HTTP `202`, `status: staged`, with
`source_id`, `content_hash`, `source_url`, `blob_url`, `blob_name` and byte count.
It is not an indexed-document receipt. The blob path is
`native/{source_id}/source.ext`, not a hash-versioned history. Overwrites are stable
per source; historical versions, deletion reconciliation and bulk crawling are
not supplied by this change.

Supported inputs are PDF, PNG, JPEG and TXT. TXT must contain valid UTF-8, may
include a UTF-8 BOM, and uses `text/plain` with an optional UTF-8 charset. Validation
does not convert the file: the original bytes, including any BOM, are staged
unchanged. The Function does no extraction, conversion, chunking or embedding.
[Content Understanding native TXT support](https://learn.microsoft.com/azure/search/cognitive-search-skill-content-understanding)
was checked on 2026-09-11. That documented format support and the deployed staging
fix do not constitute live SharePoint-to-CU acceptance.

## Explicit native Search definitions

The [ingestion contract](../src/shared/native-ingestion.json) and
[index contract](../src/shared/search-index.json) use `contractVersion: 2` and
`owner: accelerator-native-indexer`. The initializer uses Search API
`2026-08-01-preview` to construct and validate these six definitions:

| Definition | Name |
| --- | --- |
| Blob datasource | `spo-native-datasource` |
| Search index | `spo-native-index` |
| Skillset | `spo-native-skillset` |
| Indexer | `spo-native-indexer` |
| `searchIndex` knowledge source | `spo-native` |
| Knowledge base | `spo-native-knowledge-base` |

The datasource scopes staging blobs to `native/`. The indexer uses
`executionEnvironment: private`, file-data access and a `PT5M` schedule. Creating
the enabled indexer starts indexing automatically; scheduling continues independently
of the Function and initializer, even when staging is empty. Five minutes is an
interval, not a freshness SLA. A manually staged blob in that scope can also feed
the indexer; acceptance still needs the required provenance metadata.

Read-back must establish all requested semantics:

- Content Understanding with images and location metadata, semantic chunking in
  tokens, maximum length 500 and overlap 0, using secondary `gpt-5.2`.
- `text-embedding-3-large` on text sections with 3072-dimensional vectors, the
  secondary account and the ingestion user-assigned managed identity (UAMI).
- Child-only projections, a Search-generated child key, `snippet_parent_id`, `snippet`,
  `doc_url`, `snippet_vector`, a semantic configuration and query-time vectorizer.
- Matching private datasource/indexer scope and keyless identity bindings.

Canonical validation accepts any safe embedding output name, such as `text_vector`,
only when its projection consistently references that output. For semantic
chunking, omitted or null overlap is equivalent to zero. These aliases do not relax
the required chunk size, model, vector dimensions or final index-field contract.

Images/location metadata are requested enrichment outputs, not an asset store or
a promise that the KB persists/serves images. No asset-store persistence is requested.

These settings are explicit skillset/index definitions, not requests for an
auto-generated Blob knowledge-source template. Azure Search executes the built-in
skills; no custom Function enrichment or custom-skill fallback is involved.
Strict read-back validation blocks mismatches. The [toolbox](../toolbox.yaml)
requests `vector_semantic_hybrid`; live hybrid toolbox retrieval and the
3072-dimensional index schema were verified. Vectors were not retrievable, so no
direct 3072-element array check is claimed. Images/location are configured outputs,
not verified image-retrieval quality. All six definitions were initialized; the
[validation record](VALIDATION.md#live-s1-correlation-and-skillset) records the actual
7818-byte skillset export, SHA-256 and unchanged final ETag.

## Identity, network and cost review

The target is **S1** with a directly configured private indexer. Microsoft documents
[S1+ support for private indexers with built-in skills](https://learn.microsoft.com/azure/search/search-indexer-howto-access-private)
on services created after April 3, 2024; embedding skills additionally require a
high-capacity region. Live `fwfun2basearch` in Central US was created September
9, 2026 and remains `standard` S1 with public access disabled. Its explicit native
CU/embedding fixture path passed live with secondary South Central US models;
this is evidence for that combination, not all regions/services. Review service
eligibility and cost before a new plan.

The **S2+** restriction applies to the generated private `azureBlob` knowledge-source
path, which is not used here. The earlier S2 quota blocker is historical, not the
current prerequisite for this S1 route. The Search ingestion
UAMI has staging Blob Data Reader, secondary Cognitive Services User and secondary
Cognitive Services OpenAI User roles. The Function retains staging/source duties
and has no CU/Search roles or settings.

[Native ingestion infrastructure](../terraform/native-ingestion.tf) adds three
Search shared private links: secondary staging storage (`blob`), secondary Foundry
CU (`foundry_account`) and secondary OpenAI (`openai_account`). Each requires
explicit target-side approval and live validation. All three and the existing
primary OpenAI planner link are Approved/Succeeded. The Search system-identity
planner path is preserved. Live control-plane verification passed; three authenticated
public data-plane probes returned explicit `NetworkDenied` 403. Terraform success
alone would not prove approval or usable data-plane access.

Review Search S1, scheduled extraction, image verbalization, embeddings, query-time
vectorization and model consumption as live costs, alongside the existing network
and storage footprint. This refactor is not approval to deploy, upgrade a live
tier, grant broader access or approve private links.

## Migration and binding gates

1. Inventory the exact environment from Terraform/azd outputs and preserve dated
   custom-pipeline evidence. Do not bind to resource IDs copied from another sample
   or account. Primary planner and secondary ingestion endpoints are distinct.
2. Review cost, RBAC changes, preview availability and the three new private-link
   targets. Obtain separate approval before live infrastructure or workload changes.
3. Workload order is
   Function publish, fixture staging, Knowledge initialization, native deployment
   and runtime RBAC, followed by Verify. Consult actual script parameters; no new
   public accelerator flags are implied. The initial migration used reviewed manual
   recovery; repeated normal Verify now passes with guarded receipt refresh.
   This does not certify the entire orchestrator DAG or deletion behavior.
4. Run the [initializer](../scripts/Initialize-KnowledgeBase.ps1) from the private
   runner using output-derived inputs. It uses `If-None-Match: *` to create only
   missing definitions after checking all six existing definitions. It refuses
   mismatches, including an old `azureBlob` KS named `spo-native`. No automatic
   in-place migration, delete, rollback, explicit indexer run or indexing wait
   occurs. Explicit `-RebindDataSource` is the reviewed datasource adoption/recovery
   exception; guarded `-RefreshDataSourceBinding` renews only a previously bound,
   configuration-matched receipt with a stale ETag. Neither is automatic migration.
   Creating the enabled indexer starts native indexing. Definitions
   created before a later failure can remain; inventory them before approved recovery.
5. Treat `verification: configuration-only` and `indexing_verified: false` as an
   initialization result, not live acceptance. The Python launcher delegates to
   this same PowerShell initializer; it is not a second writer or fallback.
6. Preserve the old custom resources until an explicit migration/retirement
   decision. Do not repoint another service, reuse unrelated sample IDs, delete a
   historical generated resource or weaken the contract to make a deployment appear successful.

For recovery from the earlier failed S2/generated-source attempt, retain its error
and inventory the exact surviving definitions and links. An old `azureBlob` KS
cannot be silently reused as a `searchIndex` KS. Resolve conflicts only through an
explicitly approved recovery; do not delete historical Function resources or
recreate the Search service merely to bypass a mismatch.

### Datasource receipt and resume

Redacted credentials require an exact ETag/configuration receipt from creation or
an explicit reviewed `-RebindDataSource`. Null credentials are never a general
match. Readback tolerates only `@odata.context` and empty `indexerPermissionOptions`
server defaults; nonempty options remain blocked.

`-RefreshDataSourceBinding` defaults off. When enabled, it requires a valid receipt
with all configuration bindings matching and only the server ETag stale, plus
matching visible definitions. It issues exactly one conditional datasource PUT
using `If-Match` with the current server ETag, validates readback, and saves the new
receipt. Missing/wrong receipts, visible-field drift or mismatching bindings block;
HTTP 412 is not retried. An exact current receipt returns `reused-receipt` without
writing. Explicit `-RebindDataSource` remains necessary for reviewed adoption, not
as a routine Verify step.

Normal Knowledge and Verify enable refresh. Verify always initializes after the
authorization probes immediately before end-to-end verification, even with an
existing checkpoint. Earlier indexer-induced ETag drift required manual rebind in
the recovery driver; that is historical. Normal Verify now passed twice:
`37335ca7-e6fc-4ea8-be6f-a909614ae38c` at indexer `14:59:14.138Z`, then
`fb9531bc-584d-447b-b7c1-ab4023a0fb50` at `15:00:59.441Z` on 2026-09-11.
Both refreshed and passed fresh indexing, IQ and strict dual retrieval. An immediate
initializer then reused ETag `0x8DF1015C17C07F9` with no PUT. Neither run redeployed
agent 3, changed its runtime principal or changed its new KB binding.

## SharePoint administrator handoff

This optional procedure applies when a real sample and separate permission
approval are available; it is not a publication prerequisite or a planned cloud
action. Azure subscription Owner PIM does not grant Graph application-role or site
consent authority. Resolve the Function identity and configured source from the
current Terraform outputs, never identifiers copied from a prior lab. The dated
lab targets and denied-read evidence remain in
[VALIDATION.md](VALIDATION.md#sharepoint-administrator-boundary).

An authorized administrator must use a Graph client permitted to manage site
permissions: `Sites.FullControl.All` belongs on the **consenting client, not the
Function**. The operator also needs authority to assign the Graph application role.
Review the existing role and site grants first. From the repository root, the
user/administrator can then run the existing
[consent helper](../scripts/Grant-SharePointAccess.ps1) under that approved context:

```powershell
& .\scripts\Grant-SharePointAccess.ps1 -TerraformDir .\terraform -Role read
```

This is a permission-changing administrator action requiring separate approval.
The helper derives the identity/site from outputs and inventories all
existing assignments and site grants before any write. It assigns `Sites.Selected`
and then read on only the configured site as needed. Conflicting existing site
grants block for administrator review; there is no broad fallback. The Function
does not need `Sites.Read.All` or `Sites.FullControl.All`. Once authorized, confirm
the configured file and retry the private verifier; do not silently change the
file, its contents, or source path to manufacture a passing result.

## Private SharePoint verification

The [verifier](../scripts/jumpbox/Invoke-EndToEnd.ps1) defaults to `-Mode fixture`.
`-Mode sharepoint` requires **explicit** nonempty `-Question` and `-ExpectedAnswer`
from the intended file and checks that the Function returned the requested mode.
It preserves all fixture-era freshness, blob provenance, indexer, IQ and strict
agent guards. The expected answer below is an acceptance criterion, not a verified
claim about a source document. Replace both placeholders with facts from the
approved sample before running.

After administrator review/consent and approved runner startup, run this from the
existing accelerator's staged source directory **inside the VNet**, containing
`deployment-manifest.json`. That manifest is generated from Terraform outputs;
the environment selects the existing runner verification virtual environment
prepared by normal Verify. No Terraform installation or copied token is needed
on the VM. The example supplies every required initializer/verifier endpoint,
model, identity and Python parameter using the actual script signatures, and shares
one receipt path. It performs live fixture authorization probes, guarded refresh
and then real SharePoint staging/indexing/retrieval; it is not a local test.

```powershell
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath .\deployment-manifest.json -Raw | ConvertFrom-Json
$ingestion = $manifest.native_ingestion
$runnerRoot = Join-Path 'C:\ProgramData\FunWithFoundry' $manifest.environment
$python = Join-Path $runnerRoot 'verification-venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
   throw 'Complete the approved runner verification environment setup first.'
}
$receiptPath = Join-Path (Get-Location).Path '.azure\native-datasource-receipt.json'
$global:LASTEXITCODE = 0
$probeText = & .\scripts\jumpbox\Test-Ingestion.ps1 `
   -FunctionHostname $manifest.function_hostname -ApiClientId $manifest.function_api_client_id -Confirm:$false
if ($LASTEXITCODE -ne 0) { throw 'Authorization probes failed.' }
$probes = ($probeText -join "`n") | ConvertFrom-Json
if ($null -eq $probes -or $probes -is [array] -or $probes.status -cne 'passed') {
   throw 'Authorization probes did not return a passing result.'
}
$knowledgeParameters = @{
   SearchEndpoint = $manifest.search_endpoint
   FoundryOpenAIEndpoint = $manifest.openai_endpoint
   PlannerDeployment = $manifest.planner_deployment
   PlannerModel = $manifest.planner_model
   StorageResourceId = $ingestion.storage_resource_id
   IngestionIdentityResourceId = $ingestion.identity_resource_id
   IngestionFoundryEndpoint = $ingestion.ai_services_endpoint
   IngestionOpenAIEndpoint = $ingestion.openai_endpoint
   IngestionChatDeployment = $ingestion.chat_deployment
   IngestionChatModel = $ingestion.chat_model
   EmbeddingDeployment = $ingestion.embedding_deployment
   EmbeddingModel = $ingestion.embedding_model
   StagingContainer = $ingestion.container_name
   FolderPath = $ingestion.folder_path
   DataSourceReceiptPath = $receiptPath
   RefreshDataSourceBinding = $true
   Confirm = $false
}
$knowledge = & .\scripts\Initialize-KnowledgeBase.ps1 @knowledgeParameters
if ($LASTEXITCODE -ne 0 -or $null -eq $knowledge -or $knowledge -is [array] -or
   $knowledge.status -cne 'succeeded' -or $knowledge.knowledge_source -cne 'spo-native' -or
   $knowledge.index -cne 'spo-native-index' -or $knowledge.knowledge_base -cne 'spo-native-knowledge-base') {
   throw 'Native knowledge configuration did not pass.'
}
$verifyParameters = @{
   FunctionHostname = $manifest.function_hostname
   ApiClientId = $manifest.function_api_client_id
   SearchEndpoint = $manifest.search_endpoint
   ProjectEndpoint = $manifest.project_endpoint
   SearchToolName = $manifest.search_connection
   ModelDeployment = $manifest.agent_model
   PythonExecutable = $python
   StorageResourceId = $ingestion.storage_resource_id
   IngestionIdentityResourceId = $ingestion.identity_resource_id
   StagingContainer = $ingestion.container_name
   DataSourceReceiptPath = $receiptPath
   Mode = 'sharepoint'
   Question = '<question about the approved SharePoint sample>'
   ExpectedAnswer = '<known answer from that sample>'
   Confirm = $false
}
& .\scripts\jumpbox\Invoke-EndToEnd.ps1 @verifyParameters
```

## Provenance and acceptance

Projected child `doc_url` maps from `/document/metadata_storage_path`. The aliases
`/metadata_storage_path` and `/document/doc_url` are accepted only with the exact
untransformed indexer mapping `metadata_storage_path` to `doc_url`. The final value
is the **staged blob URL**, not `originalSource` or the original SharePoint URL.
Retain the blob metadata: original `source_id`,
`content_hash` and encoded original URL metadata live on the blob. The Function
also returns `source_url` (a fixture URN for the synthetic document). Child URLs
alone do not prove a digest, original-source ACL enforcement or SharePoint links.

The [end-to-end verifier](../scripts/jumpbox/Invoke-EndToEnd.ps1) requires a
blob HEAD with matching provenance, length, freshness and stable ETag; a fresh
successful native indexer execution; nonempty child chunks tied to the staged blob;
and IQ/native retrieval evidence tied to those chunks. It checks 3072 dimensions
when vectors are retrievable; that direct array check was not possible in this run.
Staging alone, old indexer history, an old custom
index answer or initializer success cannot pass as the new live proof.

The earlier S1 fixture evidence remains valid: request
`f2e76769-c8ee-4e51-9db4-f7e7b07e9aeb` passed against indexer execution
`2026-09-11T02:28:58.498Z`: 1 processed, 0 failed, 1 child with matching blob
metadata/freshness/ETag/source hash. IQ and strict native IQ-then-Search passed.
Agent 3 / toolbox 2 use `spo-native-knowledge-base` and the unchanged runtime
principal. The runtime normalizes the native Search text
footer URL and matching UrlToken-encoded parent into source JSON before the Responses
host flattens the block; `lc_framework` IDs remain rejected. Retain the strict client.

All golden questions passed (15 October 2026 launch, 30-day retention, unknown
budget), each with both matched tool outputs. Seven live authorization/staging
negative checks passed. Existing `eval.yaml` was reused as local intent; no cloud
evaluators ran. The jumpbox is confirmed `PowerState/deallocated` after the follow-up;
retained services continue billing.

Run the [local gates](TESTING.md) and record actual counts; the follow-up full gate
passed and is saved in `.azure/s1-followup-local-validation.log`. Actual SharePoint
source read/CU proof is deferred; the full orchestrator run, deletion acceptance,
latency/cost measurements and image/location quality remain unproven. No further
cloud actions are planned for publication. Keep live S1 evidence separate from the historical results in
the [validation record](VALIDATION.md).