# Compatibility

## Scope and evidence

**Validated baseline, 2026-09-11:** the explicit S1 native-indexer pipeline passed
the full local release gate, live fixture-backed acceptance and two normal Verify
runs. This validates the existing lab combination, not a clean full orchestrator
run or deletion acceptance. Actual SharePoint integration is deferred because no
sample is available; the accepted structure does not prove access or grant consent. See
[native ingestion](native-ingestion.md) for ownership, eligibility and recovery.

The component locks and runtime declarations below describe the reference baseline.
The 2026-09-11 publication check also passed with workstation Terraform 1.16.2;
the existing CI pin remains 1.15.8. No dependency pins changed during doc cleanup.
[VALIDATION.md](VALIDATION.md) records its 2026-09-10 local, hosted CI and live rebuild
acceptance for the historical custom-ingestion implementation separately.
Dependency pins, API dates and service lifecycle are different
kinds of evidence; success on that baseline does not certify every allowed version
or a new environment. Use [TESTING.md](TESTING.md) to validate a change.

The previous v5 hosted-agent smoke is historical. No blanket Python 3.12+ requirement
or cross-version support matrix is inferred from a developer workstation. The
documentation-tool updates below do not change or redeploy the accepted runtime locks.

## Runtime and package matrix

| Component | Actual source setting | Validation boundary |
| --- | --- | --- |
| Terraform CLI | `>= 1.9.0` in [providers.tf](../terraform/providers.tf) | No exact CLI release pinned by that constraint |
| Terraform providers | Lockfile: azurerm `4.81.0`, azapi `2.12.0`, azuread `3.9.0`, random `3.9.0`, time `0.14.1` | Recorded rebuild passed; respect lockfile checksums and validate new plans |
| Ingestion Function | Python `3.11`, FC1 Flex Consumption in [main.tf](../terraform/modules/ingest-function/main.tf); local checks on `3.11.13`; remote Oryx build on `3.11.8` | Recorded authorized fixture and cross-region acceptance passed; not arbitrary document/tenant coverage |
| Hosted agent | `python_3_13`, remote build, Responses protocol `2.0.0` in [azure.yaml](../azure.yaml); local native checks on `3.13.7` | Recorded deterministic hosted graph passed; revalidate runtime/model changes |
| Ingestion lock | `azure-functions==1.24.0`, `azure-identity==1.25.1`, `azure-storage-blob==12.27.1`, `azure-core==1.36.0`, `requests==2.32.5`, `pyjwt[crypto]==2.10.1`, `cryptography==46.0.3`, plus hashed transitives | Remote build and selected authorization probes passed; optional scenarios remain listed in validation |
| Native lock: SDK/hosting | `langchain-azure-ai==1.2.9`, `azure-ai-projects==2.4.0`, `azure-identity==1.25.3`, `httpx==0.28.1`, stable `pydantic==2.13.5` | Recorded hosted execution passed; not proof for later SDK versions |
| Native lock: orchestration | `langgraph==1.2.11`, `langchain-core==1.6.2`, `langchain-openai==1.6.1`, `langchain-mcp-adapters==0.3.2`, `mcp==1.30.0`, `openai==2.54.0` | Not a broad cross-version support matrix |
| Responses client lock | `azure-identity==1.25.3`, `httpx==0.28.1`, plus hashed transitives; CI selects Python `3.13.7` | No independent deployed runtime pin |
| IQ setup helper | Python standard-library launcher delegates to the canonical PowerShell initializer and shared contracts | Requires PowerShell 5.1/7 on Windows or 7 elsewhere and private-runner IMDS; no independent SDK writer or interactive-login fallback |
| Windows jumpbox | Windows Server image uses `version = "latest"` in [main.tf](../terraform/modules/jumpbox-bastion/main.tf) | Recorded image bootstrap passed; future images are not immutable |
| Runner tools | Reviewed manifest: azd `1.33.0`, uv `0.8.13`, Python `3.13.7`, eight pinned extensions; official artifact verification | Private bootstrap passed in the recorded rebuild; new VMs require read-back |
| Diagram tooling | `@mermaid-js/mermaid-cli` `11.12.0` in [.github/package.json](../.github/package.json) | Original custom-ingestion contracts/PNGs are historical and unchanged; native semantics require new approval before authoring/rendering |
| Markdown tooling | `markdownlint-cli2` `0.18.1` in [.github/package.json](../.github/package.json) | Verify Node engine and resolved dependency compatibility in CI |
| Python documentation tools | `yamllint==1.38.0`, `markdown-it-py==4.2.0` in [.github/requirements.txt](../.github/requirements.txt) | Local documentation checks use a separate environment; not deployed runtime dependencies |

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
documentation gate. Actual hosted results are linked in [VALIDATION.md](VALIDATION.md);
declared versions alone are not evidence. Windows obtains 3.11.13 through uv because
the pinned setup-python action has no matching Windows build.

Python `3.13.7` is included as the fourth staged artifact, using the official
Windows installer with published SHA-256 and Python Software Foundation signature
verification. All four artifacts, fresh-VM installation and hosted execution passed
in the recorded rebuild. Keep these as distinct gates for another environment;
do not infer installer or runtime success from artifact delivery alone.

## Models, APIs and data contract

| Surface | Source value | Interpretation |
| --- | --- | --- |
| IQ planner model | `gpt-5.2`, version `2025-12-11`, capacity `50` | Module default, not current quota/availability proof |
| Hosted answer model | `gpt-4o`, version `2024-11-20`, capacity `50` | Current agent-model default; selected deployment is configuration |
| Native ingestion models | Secondary `gpt-5.2` and `text-embedding-3-large`, explicit 3072 dimensions | Live fixture pipeline passed; dimensions verified by schema/query pipeline, not retrievable vector arrays |
| Model SKU | `GlobalStandard` | Processing not pinned to either resource region |
| Foundry account/project/connection ARM resources | `2025-06-01` | ARM schema dates, not runtime protocol versions |
| Project capability-host ARM resource | `2025-04-01-preview` | Preview API surface; do not infer all Foundry services are preview |
| Cosmos project-connection metadata | `2025-05-01-preview` | Connection metadata field, not a blanket Cosmos service lifecycle claim |
| Search tier | Root `search_sku = standard` (S1); accepts `standard`, `standard2`, `standard3` | Live Central US S1 fixture path passed; other services still require creation-date eligibility and a high-capacity region for embeddings |
| Search shared private link ARM resource | `2025-05-01`; existing primary `openai_account` plus secondary `blob`, `foundry_account`, `openai_account` | Preserve primary planner MI/link; separately approve new UAMI/dependency access |
| Native definitions and read-back | `2026-08-01-preview`, contract version 2, owner `accelerator-native-indexer`, `searchIndex` KS, private indexer execution, `PT5M` | Six explicit definitions; create only missing ones, refuse existing mismatches; enabled indexer runs on creation |
| Agent IQ retrieve | `2026-05-01-preview` in the current agent source | Distinct from setup/read-back API; live retrieval against `spo-native-knowledge-base` passed |
| Native Content Understanding | Explicit built-in CU skill, images/location metadata, semantic tokens 500/0, secondary `gpt-5.2` | Azure Search executes the fixture-validated pipeline; images/location quality remains unproven |
| Toolbox | One versioned read-only Search tool, `query_type: vector_semantic_hybrid`, `top_k: 5`, `spo-native-index` | Live strict dual retrieval passed on toolbox 2; no automatic version upgrade or relevance benchmark implied |

Model defaults are in [variables.tf](../terraform/modules/foundry-agent-private/variables.tf).
Native ingestion settings are in
[native-ingestion.json](../src/shared/native-ingestion.json) and
[Initialize-KnowledgeBase.ps1](../scripts/Initialize-KnowledgeBase.ps1); the retrieve
constant is in [main.py](../src/foundry_native_agent/main.py).
[search-index.json](../src/shared/search-index.json) supplies index/projection
creation and validation settings. It requires child snippets/parent identity,
staged-blob `doc_url` and vectors. The Function preserves original identity/hash
metadata on the blob, not as guaranteed generated child fields.

Canonical validation accepts any safe embedding output name (for example
`text_vector`) only with a consistent projection. Omitted/null semantic overlap
means zero. Projected `doc_url` aliases `/metadata_storage_path` and
`/document/doc_url` require the exact untransformed indexer mapping
`metadata_storage_path` to `doc_url`. The final URL remains the staged blob, not
`originalSource`; retain original-source/hash blob metadata.

The initializer constructs `spo-native-datasource`, `spo-native-index`,
`spo-native-skillset`, `spo-native-indexer`, the `searchIndex` KS `spo-native` and
`spo-native-knowledge-base`. CU chunking, embeddings and child projections are
explicit definitions, not an auto-generated KS template. It validates existing
definitions before creating missing ones and refuses mismatches. It performs no
automatic migration/delete; datasource-only reviewed rebind and guarded stale-ETag
refresh use conditional writes under [receipt gates](native-ingestion.md#datasource-receipt-and-resume).
Configuration success leaves
`indexing_verified: false`; an enabled indexer can run without the initializer
waiting for it. Neither mocks nor historical Function proof establishes live compatibility.

Microsoft documents S1+ for direct private indexers with built-in skills on services
created after April 3, 2024, with a high-capacity-region requirement for embeddings.
The current Central US service was created September 9, 2026. The generated private
`azureBlob` KS S2+ path is not used; its failed S2 quota attempt remains historical.
See [eligibility guidance](native-ingestion.md#identity-network-and-cost-review).
The same ingestion UAMI, three secondary shared private links, preserved primary
planner link and existing security boundaries remain in place.

The Function is staging-only (`202 staged`); manual Blob staging is also possible.
Both can test native Blob indexing, but only an actual SharePoint-file run can
establish SharePoint access and the intended cross-region source path. Original URL
metadata stays on the blob; child citations identify the staged blob, not SharePoint.

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

First-party references accessed 2026-09-09:

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

### Dependabot review, 2026-09-10

The authenticated GitHub alerts API reported that Dependabot security alerts are
disabled for this repository. An open version-update PR is not itself a security
alert. No claim of zero known vulnerabilities follows from an unavailable alert
list, and this review does not change repository security settings.

| Update PR | Disposition | Reason |
| --- | --- | --- |
| [6](https://github.com/aionic/funwithfoundry/pull/6): markdown-it-py 4.0.0 to 4.2.0 | Applied in source | Minor documentation parser update; exercised by local-link checks |
| [7](https://github.com/aionic/funwithfoundry/pull/7): yamllint 1.37.1 to 1.38.0 | Applied in source | Minor documentation linter update; exercised against repository YAML |
| [8](https://github.com/aionic/funwithfoundry/pull/8): MCP adapter minimum 0.2 to 0.3.2 | Applied in source | Lock already resolves 0.3.2; no version or hash change, retrieval tests pass |
| [9](https://github.com/aionic/funwithfoundry/pull/9): azure-ai-projects 2.4.0 to 2.6.0 | Deferred | Changes the live-validated SDK/preview-hosting combination; needs a coherent lock and API/private integration validation, not just a minor-version label |
| PRs 1-5: setup-python, gitleaks-action, setup-node, checkout, setup-uv | Deferred | Major Actions upgrades require separate runner/runtime and workflow compatibility review |

The two documentation wheels were obtained over verified HTTPS and compared with
PyPI SHA-256 metadata after uv downloads hit a local TLS handshake failure. They
were installed with uv in a dedicated environment using local wheels and cached
dependencies; TLS verification and runtime locks were not weakened. Equivalent
source changes are included in this publication; PRs were not individually merged.
Check the publication commit's hosted results before treating updates as validated
on GitHub runners.

Deferred work is retained in the published Beads backlog: `funwithfoundry-rme`
covers the runtime SDK and major Actions upgrades, `funwithfoundry-g5f` covers
authorization and verification of Dependabot security alerts, and
`funwithfoundry-48p` covers required-check protection on `main`. None of these
deferred changes or repository settings is enabled by publishing the current work.
