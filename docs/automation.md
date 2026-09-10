# Automation

## Purpose and status

Automation exists to catch mistakes cheaply, preserve deployment ordering, limit
privilege and make failure evidence auditable. It does not turn a POC into a production
platform or make an untested cloud path safe. This page describes the current
implementation and verified local evidence as of 2026-09-09, not a successful GitHub
or new accelerator Azure run. The full release gate must be rerun after the latest
artifact-transfer integration.

## Local checks

The current [Test-Repository.ps1](../scripts/Test-Repository.ps1) is cloud-free: it
does not discover credentials or invoke Azure CLIs. Supply explicit uv environment
interpreters; PATH Python is not selected implicitly. Ingestion and hosted-agent
requirements have different Azure Identity pins and should remain isolated.

The full local release-check command, after installing the reviewed test/documentation
dependencies into those environments, is:

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1 -PythonPath $NativePython -IngestionPythonPath $IngestionPython -DocumentationPythonPath $DocsPython -Terraform -Release
```

`$NativePython`, `$IngestionPython` and `$DocsPython` must be real paths from separate
uv environments. Native checks use Python 3.13.7 and ingestion uses 3.11.13. See
[CONTRIBUTING.md](../CONTRIBUTING.md#development-checks) for complete setup and
[deployment.md](deployment.md#component-environments) for hash-enforced component
installs. Documentation dependencies are in
[.github/requirements.txt](../.github/requirements.txt) and the committed npm lockfile.
Install the latter with `npm ci --prefix .github --no-audit --no-fund`; do not replace
the pinned tools with an unpinned download.

The harness parses PowerShell, checks Python syntax, runs the ingestion/retrieval/schema
tests and PowerShell mock guards. `-Terraform` adds formatting, validation in a
temporary backend-disabled copy and mocked ingestion-auth tests. `-Release` requires
documentation tools and rejects skipped tests. `-Quick` is syntax-only; it is useful
feedback but not a release gate. Do not describe a skipped optional check as passed.

The focused regression surface covers first/matching toolbox deployment,
public 200 versus auth/network denial, the 62/63-character subnet boundary, ingestion
auth/input/JSON/identity checks, per-document indexing failure and either retrieval
branch failing. There is no broad supported-Python matrix implied by these tests.
Terraform provider/package downloads need network access; that is distinct from an
Azure deployment or data-plane call.

On Windows the harness also runs [Test-ArtifactTransfer.ps1](../tests/Test-ArtifactTransfer.ps1).
It mocks ARM, Bastion, SFTP and Windows management operations, sandboxes guest file
publication/cleanup, and checks installed SSH/keygen arguments locally without a
connection. It requires the native Windows OpenSSH clients, not Azure credentials.
See [verified bulk artifact transfer](deployment.md#verified-bulk-artifact-transfer)
for the newly added management path and the separate live acceptance gate.

### Recorded local evidence

The verified implementation results include 160 operational guards, 18 native
deployment scenarios, 214 deployment assertions, and 45 Python tests with zero skips:
24 ingestion on actual 3.11.13, 17 native on actual 3.13.7, and four schema checks.
Terraform recursive formatting, root/module validation and three mocked auth tests
passed. The final pre-redeployment documentation check passed for 10 YAML
files, 17 Markdown files, 119 local links and two Mermaid contracts.

The transport suite passed **514 local guard assertions**, not 514 end-to-end
scenarios. Its scope is the narrow privileged transfer lifecycle: integrity, exact
scope, temporary access and cleanup failures. That coverage is warranted by this
new surface; it does not introduce a broad generic test or runtime matrix. Live
Bastion SFTP delivery verified all four artifacts. Cleanup required an approved
jumpbox restart and durable managed Run Command verification. Fresh-VM tool
installation and new workload acceptance subsequently passed; see [VALIDATION.md](VALIDATION.md).

For a documentation-only edit, use the installed linter and repository configuration:

```powershell
& .\.github\node_modules\.bin\markdownlint-cli2.cmd --config .github/.markdownlint-cli2.jsonc README.md docs/automation.md docs/compatibility.md docs/deployment.md docs/operations.md CONTRIBUTING.md docs/ACCELERATOR-PLAN.md .azure/deployment-plan.md
```

Scoped lint is not the full release gate. The read-only subscription preflight
returned 51 PASS, 0 WARN and 0 FAIL. Live Entra authority and the create-only
infrastructure plans were separately checked. Function authentication and hosted
runtime acceptance passed. The private deployment plan records PIM
and separates current proof from its September 8 historical deployment appendix.

### Why hooks are advisory

[.pre-commit-config.yaml](../.pre-commit-config.yaml) supplies fast local feedback.
Git hooks are optional, bypassable and not automatically installed by cloning. A
developer can skip them, run a different environment or push through another tool.
Never rely on hooks for secret containment, release authorization or branch protection.
They should run quick local checks, not Azure login, tenant consent, applies or deletes.

## GitHub enforcement

[repository.yml](../.github/workflows/repository.yml) defines
`Cloud-free checks (windows-2022)`, `Cloud-free checks (ubuntu-24.04)` and
`Secret scan` for PRs, main pushes and manual checks. Require all three successful
statuses in branch protection/rulesets, require review of workflow/IaC/security changes,
and restrict bypass permission. These **repository settings need administrator
configuration and verification**; the workflow file cannot enforce them by itself.

The checks run on public hosted runners with read-only repository permissions and no
Azure login. That is appropriate for mock/static checks, not private integration.
Windows runs the complete release gate including transport, Terraform and docs.
Linux runs quick syntax and the Python runtime suites with the same distinct
3.11.13 ingestion and 3.13.7 native interpreters, not the full Windows gate.
Actions are pinned to commit SHAs in source; verify SHA provenance and review pin
updates. Keep checkout credentials disabled and validate secret-scan configuration,
including any service/license prerequisite, before calling the scan enforced.

Fork PRs must stay credential-free on public runners. Never execute their code on a
self-hosted/private runner, use a privileged `pull_request_target` checkout of the
fork, or trust PR artifacts/caches for later deployment without rebuilding/reviewing.
Untrusted content remains untrusted even when a maintainer starts a workflow manually.

## Deployment lifecycle

The [Invoke-Accelerator.ps1](../scripts/Invoke-Accelerator.ps1) implements
`Preflight`, `Infrastructure`, `Workload`, `Verify`. They are deployment lifecycle
stages, not interchangeable
Git hooks or independent jobs that can race each other.

The current source requires explicit subscription scope and a reviewed tool manifest
for private workload setup. Its resume state and native-runtime variable file are
under the ignored azd accelerator directory; plans there remain sensitive. Source
and manifest fingerprinting/read-back behavior have local coverage. Fresh
infrastructure execution is underway. The four-artifact manifest records azd 1.33.0,
uv 0.8.13, the signed Python 3.13.7 installer and eight extensions, with verified
hashes. The explicit interpreter path avoids runner Python downloads. Successful
artifact delivery does not by itself prove installer or workload readiness.

| Stage | Why ordering matters | Required stop condition |
| --- | --- | --- |
| Preflight | Run context/tool/capacity checks; separately confirm tenant authority, policy and runner readiness | Any missing/unknown prerequisite; ARM preflight cannot prove Entra rights |
| Infrastructure | Account injection must precede account host, and account host must precede full project-host graph | Failed or unresolved readiness; no blind retry of unknown create outcomes |
| Workload | Private runner and connections must exist before package/index/IQ/toolbox/agent setup; runtime identity must be discovered before its final RBAC | Missing bootstrap, package health, immutable toolbox selection or role evidence |
| Verify | Validate the actual deployed graph and new Function/native runtime, not historical smoke evidence | Any failed/inconclusive required check; optional SharePoint remains explicitly blocked/not tested |

Serialize changes to each Terraform state and azd environment. Preserve machine-readable
stage results and package/version hashes, but not secrets. A resumable workflow must
read back unknown outcomes and compare desired definitions; it must not blindly create
another toolbox, principal or resource. See [deployment.md](deployment.md) for current
commands and [operations.md](operations.md) for rollback and cleanup.

### OIDC and private runner trust

No automatic cloud deployment is claimed by the current repository-check workflow.
Any future deployment workflow must be manual/approved and use short-lived GitHub
OIDC federation, not a stored client secret or copied operator login cache. Bind the
federated issuer, repository/environment subject and audience precisely; scope
`id-token: write` to the deployment job only. OIDC authenticates the job; Azure RBAC
still authorizes each operation.

Use the narrow resource-group/resource scopes needed for the stage. Separate read/plan
identity from apply/write identity. Grant role-assignment, purge or subscription-level
bootstrap authority only when necessary, with separate approval/time limits. Entra
application management and app-role grants remain a separate tenant bootstrap concern;
an ARM role is not tenant consent.

Use protected environments with required reviewers, restricted deployment branches,
no self-approval where available, and concurrency controls. Review the plan and exact
resource scope before apply and the destructive manifest before teardown. Pin all
third-party actions by reviewed SHA and never automatically deploy a dependency-update
PR. Do not let automation loosen TLS, public access, local authentication or consent
to turn a red check green.

A public GitHub-hosted runner does not gain private DNS/routes from OIDC. Private
SCM, Search and Foundry calls require trusted execution in the approved network.
The current lab's ARM Run Command path uses the jumpbox identity and is privileged;
protect who can submit scripts. A dedicated private CI runner is not provisioned or
certified by these docs. If one is introduced, isolate it from PR jobs, use ephemeral
instances where possible, restrict egress, patch tools and scrub workspaces/tokens.
Self-hosted isolation and environment approval are both needed, not alternatives.

## Maintenance and releases

[dependabot.yml](../.github/dependabot.yml) proposes weekly reviewed actions, pip and
npm updates. A schedule is not an approval to merge, apply, deploy or expand permission.
Terraform provider/model/API updates need explicit compatibility review and refreshed
locks/evidence as appropriate. Do not claim a package range is an exact resolved pin.

Release evidence should record the source commit, resolved packages and tool versions,
model/API/toolbox/agent versions, package hashes, sanitized check outcomes and request
IDs. Functional evaluation and cloud evaluation-service availability are separate
results. Keep raw state, tokens and document contents out of release artifacts.

The exact Mermaid contracts and final-image QA are approved and complete. Phase 6
still requires the refreshed release gate, live Entra/runner/plan/capacity checks
and exact teardown approval. Preserve the existing lab until that approval, then
tear down, fully redeploy, verify idempotence and run actual Function/private/negative
checks. Leave the rebuilt lab deployed. No new accelerator Azure write, teardown or
redeployment is claimed.

## Diagram validation

Authoritative files are in [docs/diagrams](diagrams). The repository and this pass
use `@mermaid-js/mermaid-cli@11.12.0`. The user approved the exact contracts through
askQuestions in this session. Both final Azure-icon PNGs were reproduced at
3840 x 2160, inventoried and visually inspected, with the approved source hashes
unchanged. The existing renderer's non-writing verification mode is:

```powershell
node .github/scripts/render-diagrams.mjs --verify
```

See [the diagram guide](diagrams/README.md) for reproduction, immutable source locks,
official icon provenance, renderer manifest and visual-inspection records. Verification
checks source and image hashes, inventories and dimensions without overwriting images.
A changed contract needs fresh human approval; a changed image needs fresh visual
inspection. Neither automated rendering nor Markdown lint replaces those gates.
Diagram approval does not establish that cloud resources or runtime paths work.

### Historical preview evidence

Before final approval, both complete contracts rendered with Mermaid CLI `11.12.0`
and source-selected ELK layout, exit zero. The temporary previews were inspected
then removed. Their sizes below describe those earlier previews, not the current
3840 x 2160 deliverables. The source hashes remain the approved hashes.

| Contract | SHA-256 of exact review source | Ephemeral preview evidence |
| --- | --- | --- |
| Runtime | `055ECA0ACA8B27552905B41F29231B8AF64CD61226094779CF9238629774AA6E` | 111474 bytes, 3184 x 545 |
| Topology | `DF09D439F0D4AC75799D3067DD9B3AED5F1B2EA780DAB5BA10862F8B6298DECF` | 135486 bytes, 3184 x 378 |

The earlier seven-file documentation pass used installed `markdownlint-cli2` 0.18.1
and repository settings with zero errors, parsed local links/headings with
`markdown-it`, and passed a scoped whitespace check. That historical pass did not run
the full repository or any cloud workflow. Use the current recorded evidence above
and a fresh release-gate run for release decisions.
