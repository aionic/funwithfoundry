# Deployment

## Release gate

Current implementation status: **Core rebuild and live acceptance passed**, 2026-09-10 UTC.
Phases 1-6 and minimal tests are approved in [ACCELERATOR-PLAN.md](ACCELERATOR-PLAN.md).
The user approved both Mermaid contracts; their hashes are unchanged and both
3840 x 2160 PNGs were reproduced, inventoried and visually inspected.

The [validation report](VALIDATION.md) records current live results and recovery
steps. It is not a claim of unattended or production-ready deployment. For another
environment, rerun local checks and verify its own tenant authority, capacity,
policy, tool bootstrap and reviewed plans. Preflight alone is not deployment proof.

**Preserve the existing lab until the user approves its exact teardown targets.**
The approved Phase 6 sequence then tears down and fully redeploys that lab, not a
duplicate environment, and leaves the rebuilt lab deployed. Preserve the repository,
unrelated resources and secure state backups. That exact-scope teardown and rebuild
completed for the recorded rehearsal; never apply its approval to another environment.

## Short path

1. Read [SECURITY.md](../SECURITY.md) and [compatibility.md](compatibility.md); obtain
   the ARM and tenant permissions below, with sufficient PIM duration for teardown.
2. Configure [terraform/terraform.tfvars.example](../terraform/terraform.tfvars.example)
   as a private local input file. Never overwrite existing lab inputs or state.
3. Rerun the [local release gate](automation.md#local-checks). The diagram contracts
   and final-image QA are complete; changes to their semantics require new approval.
4. After all gates, inventory and back up the existing state, approve exact resource
   IDs, and follow [operations.md](operations.md#ordered-teardown). Confirm removal.
5. After resolving private bootstrap and live identity/plan gates, run `Preflight`,
   `Infrastructure`, `Workload`, then `Verify` using the commands below.
6. Run the default Function fixture demo and the negative cases below. Repeat the
   deployment workflow and check for unintended resource, role or toolbox duplication.
7. Keep the rebuilt lab deployed after acceptance; deallocate only the jumpbox unless
   a second teardown is explicitly requested. Review the continuing cost first.

The [Invoke-Accelerator.ps1](../scripts/Invoke-Accelerator.ps1) public interface is
implemented. These commands match its parameter declarations; they are instructions
for approved execution, not evidence of a successful cloud run:

```powershell
$ToolManifestPath = (Resolve-Path .\.azure\runner-tools.json).Path
pwsh -NoProfile -File .\scripts\Invoke-Accelerator.ps1 -SubscriptionId $SubscriptionId -Stage Preflight
pwsh -NoProfile -File .\scripts\Invoke-Accelerator.ps1 -SubscriptionId $SubscriptionId -Stage Infrastructure
pwsh -NoProfile -File .\scripts\Invoke-Accelerator.ps1 -SubscriptionId $SubscriptionId -Stage Workload -Resume -ToolManifestPath $ToolManifestPath
pwsh -NoProfile -File .\scripts\Invoke-Accelerator.ps1 -SubscriptionId $SubscriptionId -Stage Verify -Resume -ToolManifestPath $ToolManifestPath
```

`-Stage` accepts `Preflight`, `Infrastructure`, `Workload`, `Verify` and defaults to
`Preflight`. `-EnvironmentName` defaults to `funwithfoundry-dev`; use the same reviewed
name for every stage. `-TerraformDir` selects the existing state directory. `-Resume`
uses fingerprint-matched progress, not blind retries. `-Confirm` and `-WhatIf` are
ShouldProcess common parameters. `Preflight` queries Azure; it is not a local test.

After an approved teardown, securely archive the old accelerator stage evidence
before starting this sequence. Run the new lab's `Preflight` and `Infrastructure`
without `-Resume`; missing or changed account identity invalidates the old completion
records. Use resume only for the same deployment identity and reviewed fingerprint.

`$SubscriptionId` must be the reviewed existing lab subscription, not a new scope.
`$ToolManifestPath` points to the reviewed local manifest with azd `1.33.0`, uv
`0.8.13`, official SHA verification, Python `3.13.7`, and eight pinned extensions.
The tool bundles are staged in its adjacent cache for transfer, not proven installed
on the private runner. To prepare a new manifest, use
[Get-RunnerToolManifest.ps1](../scripts/Get-RunnerToolManifest.ps1) with `-OutputPath`
and `-PythonVersion`. It downloads and verifies local artifacts; it does not deploy
or validate Python readiness. Review newly resolved artifacts before replacing an
approved manifest. Do not invent hashes or silently refresh versions during release.
The source exposes `-ListStages` and `-WhatIf` for local inspection. It does not
perform teardown: the separately confirmed cleanup comes first. Planner deployment
and model must resolve from current outputs or explicit reviewed parameters.

## Prerequisites

| Area | Requirement |
| --- | --- |
| Workstation | PowerShell 7, Git, Terraform satisfying the committed constraint, Azure CLI, Azure Developer CLI with the required Foundry extension commands, and uv |
| Python | Separate component environments matching declared runtimes; see the matrix, not a blanket Python minimum |
| Azure | Correct tenant/subscription, registered resource providers, regional policy and model/VM/network quotas validated before spend |
| ARM | Scoped resource creation, network and private-link approval, role assignment and purge permissions; PIM where required |
| Entra | Application/service-principal management and application-role assignment authority, independently of ARM PIM |
| Private execution | Trusted jumpbox or approved private runner with DNS and routes to both spokes; no public hosted-runner data-plane assumption |
| State | Encrypted, access-controlled persistent state and backup outside Git; exclusive deployment ownership |
| Optional SharePoint | Explicit site owner approval, consenting tenant identity and one configured source path |

Use the organization's PIM process, not a personal elevation script. An ARM Owner
activation does **not** authorize Entra application registration, Graph app-role
assignment or SharePoint consent. Do not give steady-state CI tenant-wide rights just
because an initial bootstrap needs them. Live tenant authority and the new Function's
Entra authentication are still unverified. Recheck PIM immediately before execution;
a recorded expiration is not continuing authorization.

### Ingestion identity

The [ingestion auth module](../terraform/modules/ingest-function/auth.tf) creates a
single-tenant API application, its service principal, an `api://<api-client-id>`
identifier URI and an application role named `Ingestion.Invoke`. The root module
assigns that role to the **jumpbox managed identity**. The API service principal requires
assignment. The Function's own managed identity is a different identity, used for
downstream Storage, Content Understanding, Search and optional Graph access.

The Terraform AzureAD identity must be able to create/manage the application and
service principal, read the configured caller service principals, and assign the
API application role. For automation, tenant administrators must review the Graph
permissions for these operations: application management (for example,
`Application.ReadWrite.All`), service-principal reads, and
`AppRoleAssignment.ReadWrite.All` with `Application.Read.All`. Prefer a separate,
time-limited bootstrap identity and narrower owned-application permissions wherever
the provider operations permit them. Do not assume those consents exist.

The API requests v2 access tokens. Managed identity requests use the API resource
URI; client-credential scope is that URI plus `/.default`. The token `aud` is the
API client ID, **not** the Function identity client ID. The application validates
signature, issuer, tenant, expiry, audience, application identity, role and allowed
caller mapping. Private network access or spoofed `X-MS-CLIENT-*` headers is not
authorization. See [authorization.py](../src/ingest_func/authorization.py).

### State and configuration

Terraform inputs/outputs own resource identities; azd environment state supplies
deployment context. Use [Get-LabEnvironment.ps1](../scripts/Get-LabEnvironment.ps1)
for derived names and endpoint discovery. Never paste a prior random suffix into
source, copy a colleague's login cache, or regenerate state to work around drift.

The current root uses local state. An ephemeral checkout may use local state **only**
on an encrypted, ACL-restricted disk with an approved backup outside the checkout
before the runner disappears. Local state is single-operator state, not a team
backend. State, backups, plans and azd environment files can contain secrets; ignore
rules and Terraform's `sensitive` label do not encrypt or untrack them. Do not upload
raw state as a CI artifact. Never destroy the sole state copy during teardown.

For a team, an optional separately bootstrapped Azure Blob backend can use Entra
authentication (`use_azuread_auth = true`) and native blob-lease state locking. Scope
`Storage Blob Data Contributor` to the backend container where possible, separate
it from the lab's destruction scope, restrict network access, enable recovery controls
and retain audit history. Add/review backend configuration and migrate state only
in an approved change; this repository does not claim that remote backend is deployed.
A private backend also needs a private route from the process running Terraform init.
Never disable locking or use access keys to make CI work.

## Ordered stages

| Stage | Required ordering and output | Completion evidence |
| --- | --- | --- |
| Preflight | Run implemented context, tool and capacity checks; separately confirm tenant authority, policy and private-runner readiness | Recorded pass/fail plus explicit unresolved gates; no credentials in output |
| Infrastructure | Initialize preserved state; create network and injected Foundry account prerequisites; ensure account capability host; finish project, connections, roles, project host and private endpoints | Terraform results plus readiness read-back; `Accepted` alone is insufficient |
| Workload | Prepare private runner; approve exact shared private link; publish Function package; create canonical Search index/IQ; compare and publish toolbox; deploy hosted code; discover runtime identity and reconcile RBAC | Package digest, active trigger, index schema, toolbox version, hosted version/principal and role evidence |
| Verify | Validate infrastructure/private DNS, authorized Function fixture, both retrieval branches, failure cases and public refusal | Correlated request/document IDs and sanitized per-check outcomes |

The account capability host is platform-renamed and handled by
[Ensure-AgentCapabilityHost.ps1](../scripts/Ensure-AgentCapabilityHost.ps1).
Terraform owns the project capability host. The limited initial target is
`module.foundry_primary.azapi_resource.foundry`; targeted apply is an ordering
exception, not a substitute for a final full plan/apply. Do not run project host
creation before the account host is ready. Keep delegated agent subnet names at
62 characters or fewer, including validation of the last segment of a subnet ARM ID.

Search IQ's planner uses an approved `openai_account` shared private link and the
Search identity's `Cognitive Services OpenAI User` role on the Foundry account.
Its configured model URI must use `https://<account>.openai.azure.com`.
The planner does not invoke the hosted agent. The canonical index is text/semantic;
the versioned toolbox uses `query_type: simple`, not a vector query.

### Private runner bootstrap

VM Run Command is an ARM channel to execute trusted code inside the VNet; it is not
a VPN for the workstation. The Windows image is not evidence that Git, PowerShell 7,
Azure CLI, azd plus its Foundry extension, uv or the needed Python runtimes are installed.
[Invoke-JumpboxScript.ps1](../scripts/Invoke-JumpboxScript.ps1) injects resolved context
and checks a completion marker; it is not a general tool installer or parameter-forwarding
API. Avoid temporary WinRM listeners and public ingress workarounds.

Before live acceptance, verify bootstrap: install reviewed versions from official
Microsoft/Git/uv distribution channels, validate signatures/checksums, verify the
actual process PATH and version output, transfer the reviewed source/package, and
authenticate using the intended identity. Run Command can start in Windows PowerShell
and a different user profile; an interactive user's tool installation or azd login
is not proof that SYSTEM can use it. Do not copy token caches between identities.

The firewall permits some build feeds, but not every GitHub, Node, uv or extension
download host is guaranteed reachable. Resolve blocked installers by a reviewed
artifact transfer or explicit egress review, not wildcard firewall expansion.
An Oryx remote build uses its own platform runtime and requirements; installing
packages on the jumpbox does not install them in the Function or hosted agent.

The staged implementation includes reviewed-manifest bootstrap, source-transfer
hashes and managed-identity azd login. This is not proof of successful bootstrap on
the actual private VM. Its private PowerShell
[Initialize-KnowledgeBase.ps1](../scripts/Initialize-KnowledgeBase.ps1) reads the same
canonical schema as the Python helper; use the staged initializer, not two divergent
index definitions. Verify every installer and extension path before live acceptance.

The verified bundle carries four artifacts: azd, uv, the official Python `3.13.7`
Windows installer and the eight-extension bundle. Installer SHA-256 values and
Microsoft/PSF signatures are checked. Python is installed at an explicit runner
path; verification uses that interpreter with `--no-python-downloads`.
All four artifacts were transferred and hash-verified during the pre-rebuild
rehearsal. Fresh-VM installation remains a separate acceptance check. Workload
packages still need reachable PyPI or a prepared wheelhouse; do not widen firewall
rules to make installation pass.

### Verified bulk artifact transfer

[Send-RunnerArtifacts.ps1](../scripts/Send-RunnerArtifacts.ps1) now automates the
previous manual staging step. `Workload.Transfer` still sends the small source ZIP
through checked ARM Run Command chunks. The new `Workload.Artifacts` step follows
it and precedes `Workload.Tools`; tool installation logic is unchanged. The transfer
script is included in the accelerator fingerprint. Artifact hashes are rechecked
even on resume; an already-verified runner creates no SSH account, key or tunnel.

The workstation uses PowerShell 7.3+, installed `az` with the Bastion extension,
Terraform and native Windows `sftp` and `ssh-keygen`. It selects exactly the
manifest's azd MSI, uv ZIP, Python installer and Foundry extension bundle from the adjacent
`runner-tool-cache`. No recursive checkout upload, SAS or copied login cache is used.
Files are size/SHA-256 checked and held read-locked for transfer. The transport reads
only named nonsecret Terraform outputs, not the state file or password output.

The existing jumpbox module supplies Bastion Standard with native tunneling enabled.
No Terraform, NSG, public-access or permanent infrastructure change is required.
Before setup, ARM read-back must match the output-derived VM/Bastion IDs and the
exact `AzureBastionSubnet`; its live private IPv4 CIDR scopes the Windows firewall.

The implemented management flow, requiring approved live validation, is:

1. Authenticated ARM Run Command creates an expiring local administrator, an isolated
   SSH config and keys, a SYSTEM listener task, and a one-hour cleanup task. Existing
   SSH services, config, host keys and authorized keys remain untouched. The isolated
   config explicitly uses its own absolute authorized-keys path, including for this
   administrator; it does not use the shared administrators key file.
2. Windows Firewall allows only the Bastion subnet on the temporary listener port
   and explicitly blocks other IPv4 sources on that port. The listener is IPv4-only.
   Active firewall profiles and local-rule enforcement must be available. No NSG or
   Azure Firewall exception is created.
3. ARM returns the temporary **public** host key in a checked completion envelope.
   The workstation pins it in a temporary `known_hosts`, uses only its ACL-restricted
   ephemeral private key, and starts an owned native Bastion tunnel to the VM. It
   never changes the user's SSH configuration or disables SSH/TLS verification.
4. One pinned SFTP batch performs a canary upload/download and streams the four
   allowlisted artifacts into the owned incoming directory. The isolated server
   config uses an explicit Windows SFTP subsystem path. ARM checks every size and SHA-256 before
   moving files to `C:\ProgramData\FunWithFoundry\<environment>\tool-artifacts`, then
   verifies the final paths again. Conflicting existing files are not overwritten.
5. `finally` stops the owned tunnel, revokes the temporary guest access, removes the
   owned tasks/rules/account/profile and temporary keys/incoming files, and deletes
   the workstation key directory. Successfully verified artifacts are retained.

If OpenSSH Server is absent, the approved lifecycle attempts the Windows capability
installation through existing Microsoft servicing access and removes that capability
afterward. A temporary port-22 block prevents the installer's default rule from
opening an ingress path; only a newly generated default rule is removed. Existing
installations/rules are preserved. Nonstandard or partial installations, an existing
port-22 listener, missing Microsoft OpenSSH client binaries, blocked servicing,
restart requirements, or restrictive guest policy stop the transfer with a blocker.
The workstation never dynamically installs an Azure CLI extension or global package.

Serialize transfers. The protected guest `.artifact-transfer\active` lock prevents
overlapping attempts and retries over unresolved cleanup. Failure to confirm cleanup
is a failed stage, even if copying succeeded. The expiry task is a fallback, not
proof: after loss of ARM access, inspect the exact transfer ID's protected `state.json`
and `cleanup.ps1` through approved Run Command, run that owned cleanup if necessary,
and verify the result before retrying. Do not delete the lock/state to bypass it.
Capability rollback or listener shutdown failures retain protective blocking and
recovery state for operator reconciliation.

On the tested Windows image, a disabled transfer user's profile remained loaded
after its processes exited. Cleanup succeeded after an explicitly approved jumpbox
restart. Do not force-unload the profile. If action Run Command loses its connection,
use a uniquely named managed Run Command and its durable instance view to verify
the exact transfer and run its ownership-checked cleanup. A successful file copy
alone never makes an unresolved cleanup state acceptable.

Local-only inspection and focused tests:

```powershell
.\scripts\Send-RunnerArtifacts.ps1 -SubscriptionId $SubscriptionId -ToolManifestPath $ToolManifestPath -WhatIf
.\tests\Test-ArtifactTransfer.ps1
```

The 514 local guard assertions cover scope, integrity, ARM envelopes, SSH options,
guest publication/cleanup, credential ACLs, idempotence and failure cleanup. They
are assertions over a narrow privileged transport surface, not 514 live scenarios.
The pre-rebuild SFTP rehearsal verified all four artifacts (133,431,295 bytes) and
completed cleanup after an approved restart. Fresh-image servicing, installation
and the complete rebuilt workload still require separate acceptance.

### Component environments

Use uv with per-component environments outside package source directories:

```powershell
$EnvironmentRoot = Join-Path $env:LOCALAPPDATA 'funwithfoundry-envs'
uv venv --python 3.11.13 "$EnvironmentRoot\ingest"
$IngestionPython = "$EnvironmentRoot\ingest\Scripts\python.exe"
uv pip install --python $IngestionPython --require-hashes -r .\src\ingest_func\requirements.lock
uv venv --python 3.13.7 "$EnvironmentRoot\agent"
$NativePython = "$EnvironmentRoot\agent\Scripts\python.exe"
uv pip install --python $NativePython --require-hashes -r .\src\foundry_native_agent\requirements.lock
uv venv --python 3.13.7 "$EnvironmentRoot\client"
$ClientPython = "$EnvironmentRoot\client\Scripts\python.exe"
uv pip install --python $ClientPython --require-hashes -r .\src\hello_world\requirements.lock
```

These workstation examples require the exact interpreters or access to their
approved distribution hosts; they do not solve the private-runner egress blocker.
The chosen client version matches CI, not an independent runtime support promise.
Use a separate documentation environment as shown in [CONTRIBUTING.md](../CONTRIBUTING.md).
The optional Python IQ helper has no dedicated lock; the staged PowerShell initializer
is the default. Keep the full checkout for either initializer's shared index schema.

[Deploy-IngestFunction.ps1](../scripts/Deploy-IngestFunction.ps1) replaces packaged
requirements with `--require-hashes` and `-r requirements.lock`. Native source staging
does the same before remote build. The original direct requirements remain resolver
inputs, not the deployment install contract. Installing packages on the runner does
not install them in the remote Function or hosted runtime.

## Complete demo

Run only after approved deployment, from the private runner. Resolve the Function
hostname and **ingestion API** client ID from Terraform outputs on the workstation;
pass those nonsecret values to the private script. With its assigned identity, the
script obtains a token from IMDS itself. Do not send bearer tokens through Run Command
arguments, terminal transcripts or chat.

```powershell
.\scripts\jumpbox\Test-Ingestion.ps1 -FunctionHostname $FunctionHostname -ApiClientId $ApiClientId
```

This invocation assumes those two variables were populated from the current outputs
and a reviewed checkout is present on the runner. Do not call the parameterized
script through a wrapper that cannot forward its mandatory parameters.

The default request is `{"mode":"fixture","fixtureId":"accelerator-v1"}`.
Enable the constrained fixture setting for the demo. The fixture is generated in
the **SCUS Function**, then follows the same staging, `analyzeBinary`, extraction,
provenance and Search indexing path as SharePoint. A successful response must say
`indexed` and include a request ID, document ID and content hash. The rerun must
retain stable source/content identity. HTTP 200 without per-document success is failure.

Next invoke IQ and the native Responses client from inside the VNet using current
project, knowledge-base and agent configuration. Follow
[src/hello_world/README.md](../src/hello_world/README.md) for the actual client interface.
Use a separate uv client environment and pass its interpreter as `$ClientPython`;
the client has no independent supported-Python pin. The following private invocation
exercises IQ through the required native workflow, not a legacy prompt-only smoke:

```powershell
& $ClientPython .\src\hello_world\ask_agent.py --project-endpoint $env:FOUNDRY_PROJECT_ENDPOINT --search-tool-name $env:SEARCH_TOOL_NAME --question "When is Project Cedar's fictional launch date?"
```

Populate endpoint and exact tool-name variables from current deployment configuration.
The [fixture source](../src/ingest_func/synthetic_fixture.py) defines these three
golden checks; they are test expectations, not observed live answers:

| Question | Expected fixture fact |
| --- | --- |
| When is Project Cedar's fictional launch date? | 15 October 2026 |
| Who is Project Cedar's fictional project owner? | Morgan Example |
| What is the retention period for Project Cedar documents? | 30 days |

Repeat the client invocation for each question and require evidence of both current
tool invocations, source metadata matching the ingested document and a grounded
answer. Ask "What is Project Cedar's approved budget?" as the absent-information
case: uncertainty is expected, not a fabricated value. Inject a failed tool in the
local tests and verify it cannot produce a successful grounded answer. Do not mutate
production roles or indexes merely to manufacture a failure test.

Keep proof separate: `Test-Ingestion` tests ingestion and selected auth/input negatives;
its output explicitly does not prove retrieval or public network isolation. A
CUS-jumpbox Search write is not proof of SCUS Function-to-CUS Search transit. Correlate
the Function's request/document IDs with retrieval and, where available, network logs.

Run [Test-PublicDataPlaneRefused.ps1](../scripts/Test-PublicDataPlaneRefused.ps1)
from outside the private network. Public HTTP 200 is failure; a generic authorization
403 is inconclusive, not proof of network isolation. Include an unapproved caller
test from inside the VNet. Its absence remains `not_tested`, not passed.

### Optional SharePoint

Configure exactly one hostname, site path and file path in private Terraform inputs.
Obtain explicit approval to read that document. The consenting administrative client
needs authority to manage site permissions, including Graph `Sites.FullControl.All`
where required; that authority belongs to the **consenting client**, not the Function.

After review, [Grant-SharePointAccess.ps1](../scripts/Grant-SharePointAccess.ps1)
with `-Role read` grants the Function identity `Sites.Selected` and read access to
the single configured site. `Sites.Selected` alone grants access to no sites.
If site consent fails, stop with a blocker; never fall back to `Sites.Read.All`,
tenant-wide read or broader Function permissions.

Rerun the private ingestion probe with `-IncludeSharePoint`, which submits
`{"mode":"sharepoint"}` without caller-supplied URLs or paths. Match resulting
provenance to retrieval. Mark this scenario passed only after the real Graph fetch
and Function pipeline succeed. Synthetic success never implies SharePoint success.

## Resume and release

Resume at the first failed stage only after reading actual cloud state and prior
stage results. A timeout is an unknown outcome, not evidence that a create did nothing.
Compare desired toolbox contents before creating/publishing; record the selected
immutable version and endpoint binding. Reconcile runtime roles after discovering
the deployed principal. Do not overwrite shared state or blindly retry creation.

Release evidence must include source commit, package hashes, tool/runtime/API versions,
stage outcomes, sanitized request IDs, negative-case results and known blockers.
Report cloud evaluation-service failures separately from functional checks.
The legacy v5 smoke is historical only. See
[recorded local evidence](automation.md#recorded-local-evidence) for the current
baseline. The private local deployment plan retains September 8 deployment evidence
in a separate historical appendix. No new accelerator cloud run is claimed here.
