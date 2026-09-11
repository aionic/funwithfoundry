# Testing and Validation

Use this guide to set up the local toolchain, choose a check and record evidence.
All commands below run from the repository root in PowerShell 7 on Windows unless
explicitly marked as private-runner commands. They do not deploy Azure resources.

**2026-09-11, 15 UTC follow-up:** the full predeployment gate passed after TXT
staging, root Graph site URL handling, guarded receipt refresh and explicit
SharePoint verification mode were added. Two normal live Verify runs passed
fixture/indexer/IQ/strict dual retrieval without manual rebind or agent deployment.
Actual SharePoint integration is deferred because no sample is available; the
accepted structure is not proof or grant approval, and the attempted-source
administrator blockers remain in the validation history. A clean full
orchestrator run and deletion acceptance remain unproven. Earlier S1 and custom Function
results remain historical evidence. See [native ingestion](native-ingestion.md)
for the contract and [current validation](VALIDATION.md#current-native-follow-up)
for live correlations and scope limits.

| Full predeployment check | 2026-09-11 follow-up result |
| --- | --- |
| Python | 81 passed: 40 ingestion, 29 retrieval, 12 schema; zero skips |
| Initializer | 12237 checks on both PowerShell 7 and Windows PowerShell 5.1 |
| Deployment | 456 checks |
| End-to-end | 1333 checks on both PowerShell versions, including 201 new mode checks |
| Operational guards | 6453 checks |
| Terraform | Five mocked tests passed |
| Documentation | 286 local links passed |

The saved full-gate log is `.azure/s1-followup-local-validation.log`. These dated
results are the recorded baseline; report subsequent executions separately.

## Choose a validation level

| Level | Entry point | What a pass means |
| --- | --- | --- |
| Quick syntax | `Test-Repository.ps1 -Quick` | PowerShell parses and Python compiles; no behavioral, Terraform or docs checks |
| Focused regression | Commands below | The changed component passed its selected cloud-free tests |
| Full local release | `Test-Repository.ps1 -Terraform -Release` | Windows/Python tests, Terraform validation/mocks and documentation pass with no skipped tests |
| Hosted CI | [Repository checks](../.github/workflows/repository.yml) | Windows release, Linux syntax/runtime and secret-scan jobs pass for one commit |
| Azure preflight | Accelerator `Preflight` stage | Selected Azure/tool/capacity checks pass; not tenant consent or deployment proof |
| Live acceptance | Private end-to-end verifier and explicit optional probes; separate approval for new runs | Only actually executed, correlated native staging/indexing/retrieval and denial checks have evidence |

Local tests mock services. A cloud-free pass cannot certify network reachability,
quotas, identity propagation, remote build behavior, answer quality or live consent.
Keep previous evidence in [VALIDATION.md](VALIDATION.md), not in new pass counts.

## Prepare local environments

Install Git, PowerShell 7.3+, uv, Node.js/npm, Terraform and native Windows OpenSSH
clients before the full gate. Azure CLI, azd and Bastion are needed for deployment,
not for these cloud-free tests. Use the [version matrix](compatibility.md).
Dependency/provider/browser downloads require approved network access.

Create separate environments outside packaged source directories. Run the following
in one PowerShell session so the explicit interpreter paths remain available:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$EnvironmentRoot = Join-Path $env:LOCALAPPDATA 'funwithfoundry-envs'
uv venv --python 3.13.7 "$EnvironmentRoot\native"
uv venv --python 3.11.13 "$EnvironmentRoot\ingestion"
uv venv --python 3.13.7 "$EnvironmentRoot\client"
uv venv --python 3.13.7 "$EnvironmentRoot\docs"
$env:FWF_PYTHON = "$EnvironmentRoot\native\Scripts\python.exe"
$env:FWF_INGEST_PYTHON = "$EnvironmentRoot\ingestion\Scripts\python.exe"
$env:FWF_HELLO_PYTHON = "$EnvironmentRoot\client\Scripts\python.exe"
$env:FWF_DOCS_PYTHON = "$EnvironmentRoot\docs\Scripts\python.exe"
uv pip sync --python $env:FWF_PYTHON --require-hashes -r src/foundry_native_agent/requirements.lock
uv pip sync --python $env:FWF_INGEST_PYTHON --require-hashes -r src/ingest_func/requirements.lock
uv pip sync --python $env:FWF_HELLO_PYTHON --require-hashes -r src/hello_world/requirements.lock
uv pip install --python $env:FWF_DOCS_PYTHON -r .github/requirements.txt
uv pip check --python $env:FWF_PYTHON
uv pip check --python $env:FWF_INGEST_PYTHON
uv pip check --python $env:FWF_HELLO_PYTHON
uv pip check --python $env:FWF_DOCS_PYTHON
npm ci --prefix .github --no-audit --no-fund
```

Reuse existing reviewed environments instead of recreating them over unrelated
work. Select a different environment root for independent dependency experiments.
`uv pip sync` makes an environment match its lock and can remove other packages,
which is why these environments must be dedicated.

The native/client runtime uses Python 3.13.7 for these checks; Function tests use
3.11.13. The Function and native dependencies have different Azure Identity pins.
Do not combine them or replace hash enforcement with an unconstrained install.
The three component locks pin transitive dependencies and hashes; direct requirements
are resolver inputs. Documentation tooling is separate from deployed packages.

## Run the release gate

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1 -Terraform -Release
```

Alternatively pass explicit `-PythonPath`, `-IngestionPythonPath` and
`-DocumentationPythonPath`. An activated environment can supply the primary
interpreter, but does not remove the separate Function-runtime requirement.
The harness never implicitly selects a PATH Python or installs missing tools.

The full Windows gate includes:

- PowerShell parsing and Python syntax across tracked and new nonignored files.
- Standard-library unittest suites for ingestion/authentication, deterministic
  retrieval and the shared Search schema. Empty discovery and skips fail release.
- Operational, native-deployment, staged-deployment and artifact-transfer guards.
  Native deployment is exercised under PowerShell 7 and Windows PowerShell 5.1.
  Transfer tests generate ephemeral local SSH keys; no Azure or SFTP connection occurs.
- Terraform formatting plus root/module init and validation in a disposable copy
  with the backend disabled, followed by the applicable Terraform mock tests.
  Require nonempty test discovery and record results from the current run. No state,
  private tfvars, Azure login, apply or refresh is used.
- YAML, Markdown, local file targets and temporary Mermaid renders. External URL
  availability and heading fragments are not checked by the existing link checker.

`-Release` requires docs and disallows `-Quick` or `-Documentation Skip`.
`-Terraform` is still separate; use both flags for the complete gate. Outside release,
docs default to `Auto`, which warns when tools are missing instead of claiming a pass.

## Focused checks

```powershell
& $env:FWF_INGEST_PYTHON .github/scripts/run-python-checks.py ingestion --release
& $env:FWF_PYTHON .github/scripts/run-python-checks.py retrieval --release
& $env:FWF_PYTHON .github/scripts/run-python-checks.py knowledge_schema --release
.\tests\Test-OperationalGuards.ps1
.\tests\Test-NativeDeployment.ps1
.\tests\Test-NativeKnowledgeSource.ps1
.\tests\Test-NativeIngestion.ps1
.\tests\Test-NativePrivateLinks.ps1
.\tests\Test-Deployment.ps1
.\tests\Test-ArtifactTransfer.ps1
.\.github\scripts\Test-Documentation.ps1 -PythonPath $env:FWF_DOCS_PYTHON -Required
```

For a quick Markdown-only check after editing a page:

```powershell
& .\.github\node_modules\.bin\markdownlint-cli2.cmd --config .github/.markdownlint-cli2.jsonc README.md docs/deployment.md
```

For the five focused native follow-up documents:

```powershell
& .\.github\node_modules\.bin\markdownlint-cli2.cmd --config .github/.markdownlint-cli2.jsonc docs/STATUS.md docs/VALIDATION.md docs/native-ingestion.md terraform/modules/ingest-function/README.md docs/TESTING.md
```

Changing a filename also needs the full local-link check. Changing a Mermaid
contract needs syntax validation, visual review and explicit design approval before
regenerating final artwork. See [diagram guidance](diagrams/README.md).

For documentation-only changes, run scoped Markdown lint and parse local
links with Node or the documentation tooling; do not render or edit the original
diagrams. They are historical custom-ingestion assets. A new native diagram contract
requires review before authoring/rendering. No Python setup is needed for a Node-only
link check; configure an isolated Python environment first if using Python tooling.

### Native contract coverage

The follow-up full harness passed with the counts above, including initializer
and end-to-end checks on Windows PowerShell 5.1 and PowerShell 7. Record subsequent
pass/fail/skips separately from both this follow-up and the
[historical release proof](VALIDATION.md#native-cloud-free-validation-proof).

- Function/auth tests cover `202 staged`, stable raw-blob overwrite and metadata,
  source bounds and denied callers, with no Function CU/Search calls. TXT coverage
  includes valid UTF-8, optional BOM and `text/plain` with optional UTF-8 charset,
  raw-byte preservation and invalid-input refusal alongside PDF/PNG/JPEG.
- Knowledge-source tests cover all six explicit native definitions, missing-only
  creation, mismatch refusal, legacy `azureBlob` KS conflicts and strict
  schema/identity/definition read-back for contract version 2, owner
  `accelerator-native-indexer`.
- Receipt tests cover default-off `-RefreshDataSourceBinding`, a valid receipt with
  only stale ETag, one current-ETag `If-Match` PUT and verified readback/receipt,
  exact-receipt reuse without PUT, wrong/missing receipts and visible-field drift
  blocking, and no HTTP 412 retry. Explicit `-RebindDataSource` remains adoption.
- Native-ingestion tests cover staged blob HEAD/provenance, fresh indexer execution,
  child chunks, IQ/native reference matching and failure gates using mocks. Mode
  checks cover default fixture, explicit SharePoint question/expected answer and
  matching returned mode without weakening those existing guards.
- Retrieval/deployment tests cover native index/KB binding and the hybrid toolbox.
  Normal Knowledge/Verify enable guarded refresh; Verify initializes after auth
  probes immediately before E2E even when an existing checkpoint is present.

The requested contract includes semantic 500-token/zero-overlap chunks,
images/location extraction using `gpt-5.2`, and 3072-dimensional embeddings. The
canonical checks accept any safe embedding output name (for example `text_vector`)
only with a consistent projection, and omitted/null semantic overlap means zero.
Projected `doc_url` may use `/metadata_storage_path` or `/document/doc_url` only
with the exact untransformed indexer mapping `metadata_storage_path` to `doc_url`.
The final URL still cites the staged blob; retain its original-source/hash metadata.
Root `search_sku` defaults to `standard` (S1) and also accepts `standard2` and
`standard3`. Direct private built-in-skill indexers require a service created after
April 3, 2024; embeddings additionally need a high-capacity region. The current
Central US service was created September 9, 2026, but local tests cannot establish
live eligibility or execution. The generated private Blob KS S2 route is not used.
The initializer creates explicit definitions, refuses existing mismatches and
reports `indexing_verified: false` after configuration success. Creating the enabled
indexer starts indexing; no initialization result waits for or certifies its success.

## Validate a deployed environment

Follow [deployment.md](deployment.md) and obtain explicit approval for any new
live stage. The follow-up full gate and two normal fixture Verify runs passed;
actual SharePoint integration is deferred until a sample and approved consent are
available. This deferral does not block publication or change the evidence boundary.
Required native verification combines infrastructure
checks, authorized Function staging, blob provenance, fresh native indexing,
child chunks, IQ, strict native retrieval and public refusal.
These checks can ingest data and consume model capacity; they are not unit tests.

Use [the complete demo](deployment.md#complete-demo) for private client commands.
Capture Function request/source/hash and blob identifiers. Require blob HEAD metadata,
length, freshness and stable ETag, a fresh successful native indexer run and a
complete bounded set of child chunks associated with that staged blob. Generated
`doc_url` is the blob URL, not the original SharePoint URL; Search URL matching alone
does not prove a content digest. Old indexer history and old custom-index answers
cannot substitute for the new proof.
Require current matched IQ and Search tool calls, usable outputs and answer content.
Use the fictional owner, launch date and retention facts; ask about the absent
budget to check that the agent acknowledges missing evidence.

For the real configured file, use `-Mode sharepoint` with explicit `-Question`
and `-ExpectedAnswer`; fixture defaults cannot substitute for source-specific
acceptance. The [complete private-runner example](native-ingestion.md#private-sharepoint-verification)
derives all endpoint/ID/model inputs from the output-derived deployment manifest
and selects the existing verification Python environment. It runs authorization
probes, guarded initialization and then SharePoint E2E using one receipt path.
The request must return the same mode and pass all provenance/freshness/IQ/agent
checks. The documented expected answer is not proof the file was fetched.

The earlier TXT HTTP 415 is historical. The post-fix retry now returns HTTP 502;
complete Function Graph app-role inventory is empty, confirming missing
`Sites.Selected`. Root-site resolution succeeded, but delegated exact-item and
site-permissions GETs both returned 403 `accessDenied`. Site-specific consent and
file existence remain unknown. When a sample and separate approval are available,
follow the [administrator handoff](native-ingestion.md#sharepoint-administrator-handoff):
review existing grants, use a client authorized to manage site permissions, assign
`Sites.Selected` plus read on one site, and do not grant broad permissions to the
Function. No directory/site/content permissions were changed in the follow-up.

Additional scenarios need explicit evidence of their own:

- Real SharePoint cross-region ingestion: site consent, configured source, actual
  Function Graph fetch/staging, fresh native indexing and both retrieval paths.
  Manual Blob staging or fixture success does not validate a SharePoint connector
  or its permissions. Keep native-indexer Blob proof and actual SharePoint proof separate.
- Valid but unapproved application identity: a real token from that identity denied
  inside the VNet; missing/invalid/spoofed bearer tests are not equivalent.
- Public isolation: explicit network-policy denial, not a generic authentication 403.
- Cloud-scored evaluation: completed evaluator results; direct golden questions do
  not produce Azure evaluator scores.
- Native provider compatibility: execution of explicit semantic chunking, images/location,
  model/dimension settings, keyless UAMI bindings and private dependency links.
  Configuration success alone proves neither link approval nor indexed vectors.
- Live failure recovery, throughput and regional failover: planned experiments,
  not inferred from mocks or multi-region resource placement.
- Clean full orchestrator DAG and deletion proof: still unproven; two normal Verify
  passes resolve the observed receipt failure but do not certify these wider paths.

Never manufacture failures by removing production permissions or weakening TLS,
public-access controls or tenant consent. Use isolated tests and approved scopes.

## Evidence and maintenance

For each change record the source revision, resolved dependency versions, commands,
pass/fail/skips and unavailable checks. For live runs also record package/toolbox/agent
versions and sanitized correlation IDs. Keep tokens, state, raw documents and
credential-bearing logs out of Git and CI artifacts.

The [validation record](VALIDATION.md) is a dated baseline; [status](STATUS.md) holds
the migration history. Do not rewrite historical evidence as if new packages were
deployed. The current [CI workflow](../.github/workflows/repository.yml) makes no Azure
calls: Linux checks Python/syntax, Windows runs the full release gate, and Gitleaks
runs separately. Passing jobs do not configure branch protection or security alerts.

Review minor dependency updates too. Keep component locks coherent, retain required
extras and hashes, and hold SDK/runtime changes for compatible API and private
integration evidence. Major actions, automatic PR merges and cloud deployments are
not part of routine documentation-tool maintenance.