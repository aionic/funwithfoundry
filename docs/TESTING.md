# Testing and Validation

Use this guide to set up the local toolchain, choose a check and record evidence.
All commands below run from the repository root in PowerShell 7 on Windows unless
explicitly marked as private-runner commands. They do not deploy Azure resources.

## Choose a validation level

| Level | Entry point | What a pass means |
| --- | --- | --- |
| Quick syntax | `Test-Repository.ps1 -Quick` | PowerShell parses and Python compiles; no behavioral, Terraform or docs checks |
| Focused regression | Commands below | The changed component passed its selected cloud-free tests |
| Full local release | `Test-Repository.ps1 -Terraform -Release` | Windows/Python tests, Terraform validation/mocks and documentation pass with no skipped tests |
| Hosted CI | [Repository checks](../.github/workflows/repository.yml) | Windows release, Linux syntax/runtime and secret-scan jobs pass for one commit |
| Azure preflight | Accelerator `Preflight` stage | Selected Azure/tool/capacity checks pass; not tenant consent or deployment proof |
| Live acceptance | Accelerator `Verify` and explicit optional probes | The selected deployment's real private flows and denials have evidence |

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
  with the backend disabled, followed by mocked ingestion-role tests. No state,
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
.\tests\Test-Deployment.ps1
.\tests\Test-ArtifactTransfer.ps1
.\.github\scripts\Test-Documentation.ps1 -PythonPath $env:FWF_DOCS_PYTHON -Required
```

For a quick Markdown-only check after editing a page:

```powershell
& .\.github\node_modules\.bin\markdownlint-cli2.cmd --config .github/.markdownlint-cli2.jsonc README.md docs/deployment.md
```

Changing a filename also needs the full local-link check. Changing a Mermaid
contract needs syntax validation, visual review and explicit design approval before
regenerating final artwork. See [diagram guidance](diagrams/README.md).

## Validate a deployed environment

Follow [deployment.md](deployment.md) before running any live command. The default
`Verify` workflow combines infrastructure checks, real authorized Function fixture
ingestion, Search provenance, IQ, strict native retrieval and public refusal.
These checks can ingest data and consume model capacity; they are not unit tests.

Use [the complete demo](deployment.md#complete-demo) for private client commands.
Capture the Function request/document/content identifiers and match them to Search
and retrieval, rather than treating a CUS jumpbox write as proof of SCUS ingestion.
Require current matched IQ and Search tool calls, usable outputs and answer content.
Use the fictional owner, launch date and retention facts; ask about the absent
budget to check that the agent acknowledges missing evidence.

Additional scenarios need explicit evidence of their own:

- Real SharePoint fetch: site consent, configured source and successful Function invocation.
- Valid but unapproved application identity: a real token from that identity denied
  inside the VNet; missing/invalid/spoofed bearer tests are not equivalent.
- Public isolation: explicit network-policy denial, not a generic authentication 403.
- Cloud-scored evaluation: completed evaluator results; direct golden questions do
  not produce Azure evaluator scores.
- Live failure recovery, throughput and regional failover: planned experiments,
  not inferred from mocks or multi-region resource placement.

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