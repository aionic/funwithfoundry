# Automation

## Purpose and status

Automation exists to catch mistakes cheaply, preserve deployment ordering, limit
privilege and make failure evidence auditable. It does not turn a POC into a production
platform or make an untested cloud path safe. This page describes check coverage,
deployment ordering and trust boundaries. See [TESTING.md](TESTING.md) for local
setup and commands, [VALIDATION.md](VALIDATION.md) for dated acceptance and hosted
CI evidence, and [STATUS.md](STATUS.md) for status and history.

## Local checks

The current [Test-Repository.ps1](../scripts/Test-Repository.ps1) is cloud-free: it
does not discover credentials or invoke Azure CLIs. Use the separate uv environments
and explicit interpreters in [TESTING.md](TESTING.md#prepare-local-environments);
PATH Python is not selected implicitly. Ingestion and hosted-agent requirements
have different Azure Identity pins and must remain isolated. See the
[contributor lock notes](../CONTRIBUTING.md#development-checks) for packaging contracts.
Use the committed documentation dependencies and npm lockfile, not unpinned downloads.

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

The root Terraform lockfile is honored read-only; the child module resolves its
declared provider constraints independently. Mermaid rendering needs Chromium and
its OS libraries. The no-sandbox configuration is for local/isolated CI rendering,
never a service processing customer content. Rendering proves syntax, not design
approval or final-image review.

On Windows the harness also runs [Test-ArtifactTransfer.ps1](../tests/Test-ArtifactTransfer.ps1).
It mocks ARM, Bastion, SFTP and Windows management operations, sandboxes guest file
publication/cleanup, and checks installed SSH/keygen arguments locally without a
connection. It requires the native Windows OpenSSH clients, not Azure credentials.
See [verified bulk artifact transfer](deployment.md#verified-bulk-artifact-transfer)
for the management path and the separate live acceptance gate.

### Recorded local evidence

The dated [validation record](VALIDATION.md) and [status record](STATUS.md) separate
the completed local release gate, hosted Windows/Linux/secret-scan baseline and
live acceptance. Use those records for results and recovery boundaries, not copied
test totals. Local transport guards exercise integrity, exact scope, temporary
access and cleanup failures; they are not live end-to-end scenarios. Artifact
delivery, cleanup, fresh-VM installation and workload acceptance require distinct proof.

For a documentation-only edit, use the installed linter and repository configuration:

```powershell
& .\.github\node_modules\.bin\markdownlint-cli2.cmd --config .github/.markdownlint-cli2.jsonc CONTRIBUTING.md docs/automation.md docs/operations.md
```

Adjust the file list to the changed Markdown files. Scoped lint is not the full
release gate, local-link validation or cloud acceptance. Follow
[TESTING.md](TESTING.md#choose-a-validation-level) for the appropriate validation level.

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

The dated [publication verification](VALIDATION.md#publication) records all three
hosted jobs passing, but `main` was unprotected and the ruleset list was empty.
Green CI is a baseline for that commit, not proof of enforced merge requirements.

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
and manifest fingerprinting/read-back behavior have local coverage. The dated
rebuild and recovery evidence is in [VALIDATION.md](VALIDATION.md). The four-artifact
manifest records azd 1.33.0,
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

No cloud deployment workflow is provided; the repository-check workflow's manual
dispatch runs checks only.
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

Use [VALIDATION.md](VALIDATION.md) and [STATUS.md](STATUS.md) for completed rehearsal
evidence and explicitly untested scenarios. A new release or environment needs its
own applicable checks, live authority/capacity review and workload acceptance;
previous acceptance does not authorize writes or deletion. Teardown requires exact
scope approval under [operations.md](operations.md#ordered-teardown), independently
of any deployment or release approval.

## Diagram validation

Authoritative files and approval records are in [docs/diagrams](diagrams). The
repository pins `@mermaid-js/mermaid-cli@11.12.0`. The renderer's non-writing
verification mode is:

```powershell
node .github/scripts/render-diagrams.mjs --verify
```

See [the diagram guide](diagrams/README.md) for reproduction, immutable source locks,
official icon provenance, renderer manifest and visual-inspection records. Verification
checks source and image hashes, inventories and dimensions without overwriting images.
A changed contract needs fresh human approval; a changed image needs fresh visual
inspection. Neither automated rendering nor Markdown lint replaces those gates.
Diagram approval does not establish that cloud resources or runtime paths work.
