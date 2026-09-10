# Compatibility

## Scope and evidence

Source snapshot: **2026-09-09**. The component locks and runtime declarations below
describe the current implementation. Local tests passed on actual Python 3.11.13
and 3.13.7; this does not establish hosted or live-cloud compatibility. Rerun the
full release gate after the latest artifact-transfer integration. Dependency pins,
API dates and service lifecycle are different kinds of evidence.

The previous v5 hosted-agent smoke is historical; it does not certify the rewritten
runtime. Phase 6 must establish the new baseline. No blanket Python 3.12+ requirement
or cross-version support matrix is inferred from a developer workstation.

## Runtime and package matrix

| Component | Actual source setting | What remains unverified |
| --- | --- | --- |
| Terraform CLI | `>= 1.9.0` in [providers.tf](../terraform/providers.tf) | No exact CLI release pinned by that constraint |
| Terraform providers | Lockfile: azurerm `4.81.0`, azapi `2.12.0`, azuread `3.9.0`, random `3.9.0`, time `0.14.1` | Fresh full deployment with the current graph; respect lockfile checksums |
| Ingestion Function | Python `3.11`, FC1 Flex Consumption in [main.tf](../terraform/modules/ingest-function/main.tf); 24 local tests passed on `3.11.13`; remote Oryx build on `3.11.8` and trigger discovery passed | Authorized fixture invocation and cross-region acceptance |
| Hosted agent | `python_3_13`, remote build, Responses protocol `2.0.0` in [azure.yaml](../azure.yaml); 17 local native tests passed on actual `3.13.7` | Current deterministic graph on the hosted runtime |
| Ingestion lock | `azure-functions==1.24.0`, `azure-identity==1.25.1`, `azure-storage-blob==12.27.1`, `azure-core==1.36.0`, `requests==2.32.5`, `pyjwt==2.10.1`, `cryptography==46.0.3`, plus hashed transitives | Live remote build and authorization |
| Native lock: SDK/hosting | `langchain-azure-ai==1.2.9`, `azure-ai-projects==2.4.0`, `azure-identity==1.25.3`, `httpx==0.28.1`, stable `pydantic==2.13.5` | Fresh hosted execution |
| Native lock: orchestration | `langgraph==1.2.11`, `langchain-core==1.6.2`, `langchain-openai==1.6.1`, `langchain-mcp-adapters==0.3.2`, `mcp==1.30.0`, `openai==2.54.0` | Not a broad cross-version support matrix |
| Responses client lock | `azure-identity==1.25.3`, `httpx==0.28.1`, plus hashed transitives; CI selects Python `3.13.7` | No independent deployed runtime pin |
| IQ setup helper | Imports `azure.identity` and `requests`; reads shared index JSON | No dedicated runtime/dependency lock in the helper; retain the full source layout |
| Windows jumpbox | Windows Server image uses `version = "latest"` in [main.tf](../terraform/modules/jumpbox-bastion/main.tf) | Image and installed tools are not immutable or a verified bootstrap |
| Runner tools | Reviewed manifest: azd `1.33.0`, uv `0.8.13`, Python `3.13.7`, eight pinned extensions; azd/uv verified against official SHA manifests | Tool bundles staged for transfer; actual private bootstrap remains unproven |
| Diagram tooling | `@mermaid-js/mermaid-cli` `11.12.0` in [.github/package.json](../.github/package.json) | Contracts approved; two 3840 x 2160 PNGs reproduced, inventoried and visually inspected; not cloud evidence |
| Markdown tooling | `markdownlint-cli2` `0.18.1` in [.github/package.json](../.github/package.json) | Verify Node engine and resolved dependency compatibility in CI |

Provider evidence: [terraform/.terraform.lock.hcl](../terraform/.terraform.lock.hcl).
Dependency evidence: [ingestion requirements](../src/ingest_func/requirements.txt),
[hosted requirements](../src/foundry_native_agent/requirements.txt),
[client requirements](../src/hello_world/requirements.txt). Reproducible resolutions
are the three new hash-locked files:
[ingestion lock](../src/ingest_func/requirements.lock),
[native lock](../src/foundry_native_agent/requirements.lock), and
[client lock](../src/hello_world/requirements.lock).
Use separate uv environments: merging these components would hide the intentionally
different Azure Identity pins. Never install project dependencies into global Python.

The native resolution deliberately keeps stable Pydantic while admitting required
Azure preview packages. Its lock includes `azure-ai-agentserver-core==2.2.0b1`,
`azure-ai-agentserver-invocations==1.2.0b1`,
`azure-ai-agentserver-responses==2.1.0b2`,
`azure-ai-contentunderstanding==1.2.0b3`,
`azure-core-tracing-opentelemetry==1.0.0b13`, and
`azure-monitor-opentelemetry-exporter==1.0.0b56`. Preserve the explicit preview
constraints and stable Pydantic selection when regenerating; do not globally allow
unrelated prereleases. The universal lock's Python markers are resolver coverage,
not proof that every marked runtime was tested.

Install locks with `uv pip install --require-hashes -r <component-lock>` and an
explicit `--python` path, as shown in [deployment.md](deployment.md#component-environments).
For a clean environment, CI uses `uv pip sync --require-hashes`. Function packaging
copies the complete lock into the ZIP-root requirements file; its hashes enable
pip hash-checking mode. Native staging uses this wrapper:

```text
--require-hashes
-r requirements.lock
```

Keep `pyjwt[crypto]` explicit in each lock. Linux pip `23.0.1` on Python `3.11.8`
reproduced the remote hash-mode failure when only `pyjwt` was pinned: MSAL's crypto
extra was treated as another unpinned requirement. Retaining the extra, with the
same version and hashes, passed the reproduction and the Function remote build.
Modern pip and uv had accepted the stripped-extra lock, so they alone did not
detect this compatibility issue. Regeneration must preserve required extras.

The [CI workflow](../.github/workflows/repository.yml) selects Python `3.11.13` for
ingestion and `3.13.7` for native/client environments, uv `0.8.13`, Terraform
`1.15.8` and Node `22.16.0`. Windows runs the full release gate; Linux runs quick
syntax and the Python runtime suites, not the Windows transport or full Terraform/
documentation gate. These declarations are not evidence of a successful GitHub run.
The observed local Python total is **45 passed, zero skips**: 24 ingestion, 17 native
and 4 schema checks.

Python `3.13.7` is included as the fourth staged artifact, using the official
Windows installer with published SHA-256 and Python Software Foundation signature
verification. All four artifacts passed live SFTP transfer and hash verification
before teardown. Fresh-VM installation and hosted execution remain distinct gates;
do not infer either from successful artifact delivery or local tests.

## Models, APIs and data contract

| Surface | Source value | Interpretation |
| --- | --- | --- |
| IQ planner model | `gpt-5.2`, version `2025-12-11`, capacity `50` | Module default, not current quota/availability proof |
| Hosted answer model | `gpt-4o`, version `2024-11-20`, capacity `50` | Current agent-model default; selected deployment is configuration |
| Embedding deployment | `text-embedding-3-large`, version `1`, capacity `50` | Provisioned default, but current text-only index does not use vectors |
| Model SKU | `GlobalStandard` | Processing not pinned to either resource region |
| Foundry account/project/connection ARM resources | `2025-06-01` | ARM schema dates, not runtime protocol versions |
| Project capability-host ARM resource | `2025-04-01-preview` | Preview API surface; do not infer all Foundry services are preview |
| Cosmos project-connection metadata | `2025-05-01-preview` | Connection metadata field, not a blanket Cosmos service lifecycle claim |
| Search shared private link ARM resource | `2025-05-01`, group `openai_account` | Must be approved and paired with Search MI model access |
| Search index/data API | `2024-07-01` | Used by canonical setup and ingestion indexing |
| Search knowledge sources/bases and IQ retrieve | `2026-05-01-preview` | Preview API; request shape is version-specific |
| Content Understanding data API | `2025-11-01`, `prebuilt-document` analyzer default | Live capacity, availability and document support still need validation |
| Toolbox | One versioned read-only Search tool, `query_type: simple`, `top_k: 5` | No vector query, unrestricted tools or automatic version-upgrade assumption |

Model defaults are in [variables.tf](../terraform/modules/foundry-agent-private/variables.tf).
API constants are in [New-FoundryIqKnowledgeBase.py](../scripts/New-FoundryIqKnowledgeBase.py),
[function_app.py](../src/ingest_func/function_app.py) and
[main.py](../src/foundry_native_agent/main.py). The canonical
[search-index.json](../src/shared/search-index.json) contains `id`, `title`, `content`,
`source_url`, `source_id`, `content_hash` and a semantic configuration, not vector fields.
Retain one schema writer/definition and its packaged copy contract during deployment.

## Lifecycle and known limits

An API containing `preview` is an API-version fact, not proof that its entire service
is preview. Conversely, a stable API date or package version does not make every
feature GA. Microsoft Learn's network-isolation guidance, accessed 2026-09-09, labels
hosted agents and Foundry IQ as preview features. Confirm each feature's current
support/SLA and regional availability before a release; do not generalize that label
to Functions, Cosmos DB or all of Search/Foundry.

The repo's 62-character delegated-agent-subnet limit is a local guard for an observed
capability-host issue, not a published universal Azure subnet naming limit. Negative
coverage must accept 62 and reject 63, including trailing-slash ARM IDs.

Historical model/tool failures explain keeping separate planner and agent models;
they are not a current universal claim that a model cannot call Search. Test any
model, API, toolbox or runtime change against both retrieval branches and failure
behavior. Do not silently substitute a model/region/SKU or enable public access to
pass a test. Outbound injection cannot simply be changed in place; a failed setup
requires exact-state reconciliation, not blind subnet reuse.

First-party references checked for this documentation pass:

- [Foundry network isolation](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link)
- [Model deployment types and processing locations](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types)

## Update procedure

Open a reviewed dependency/configuration PR, record old/new resolved versions and
release notes, run cloud-free checks, and request an approved private integration
test only when warranted. Do not automatically apply dependency updates, deploy from
an untrusted fork, or regenerate the provider lockfile during a routine release.
Capture tool versions, resolved packages, source/package hashes, API/model versions
and sanitized results in release evidence. Mark unavailable versions or quota as
blocked rather than claiming compatibility.
