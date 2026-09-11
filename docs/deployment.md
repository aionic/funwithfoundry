# Deployment

This guide describes deployment prerequisites, the existing stage interface and
safe resume boundaries. Run workstation commands from
the repository root in PowerShell 7.3+ on Windows. The existing workflow provisions
Azure resources and executes private data-plane work on its jumpbox; a workstation
login alone does not make the private endpoints reachable.

**Validated baseline, 2026-09-11:** the explicit S1 native-indexer pipeline passed
fixture-backed live acceptance, two subsequent normal Verify runs and the full
local release gate. The existing lab used reviewed manual migration/recovery;
a clean full orchestrator run and deletion acceptance remain unproven. Actual
SharePoint integration is deferred because no sample is available. Structure
acceptance does not prove source acquisition or authorize permissions. Start with
the [native ingestion migration and ownership guide](native-ingestion.md).

Use [architecture.md](architecture.md) to understand what you are deploying and
[TESTING.md](TESTING.md) for local setup. Dated results and recovery history are in
[VALIDATION.md](VALIDATION.md) and [STATUS.md](STATUS.md), not prerequisites for a new
user. The historical custom-pipeline rebuild passed with operator recovery; it does not certify
unattended deployment in another tenant. No fixed completion time is promised.

**A fresh deployment does not start with teardown.** If replacing an existing lab,
review its exact targets, back up state and use the separate
[teardown procedure](operations.md#ordered-teardown) only after explicit approval.

## Short path

1. Review cost, capacity, [security](../SECURITY.md), the [toolchain](compatibility.md)
   and the separate ARM/Entra permissions below.
2. Prepare a fresh checkout, private Terraform input and protected persistent state.
3. Install isolated local environments and pass the [release gate](TESTING.md#run-the-release-gate).
4. Authenticate the workstation and generate/review the verified runner-tool manifest.
5. Obtain live approvals before
   executing `Preflight`, `Infrastructure`, `Workload`, then `Verify`; review plans
   and stop on failure.
6. Record native Blob/fixture evidence. When a SharePoint sample and approved consent
   are available, validate that source path separately; fixture success cannot prove it.
7. Choose whether to leave resources running, pause only the VM, or perform a
   separately approved teardown. Firewalls and other services continue billing when paused.

## Configure the environment

For a new clone, create the private input file once:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (Test-Path .\terraform\terraform.tfvars) { throw 'Existing input file: review rather than overwrite.' }
Copy-Item .\terraform\terraform.tfvars.example .\terraform\terraform.tfvars
```

Edit [the copied template](../terraform/terraform.tfvars.example) using these inputs:

| Input | First-deployment guidance |
| --- | --- |
| `subscription_id` | Required target GUID; must match the CLI context and explicit script argument |
| `prefix` | Use a unique 2-8 character lowercase alphanumeric prefix; default is `fwf` |
| `primary_region`, `secondary_region` | Baseline is `centralus` and `southcentralus`; alternative regions require capability, quota and routing review |
| `jumpbox_size`, `jumpbox_admin_username` | Defaults are `Standard_D4s_v5` and `fwfadmin`; check capacity and organizational policy |
| `search_sku` | Local default `standard` (S1); accepts `standard`, `standard2`, `standard3`; direct private indexer eligibility also depends on service creation date and, for embeddings, a high-capacity region |
| `my_object_id` | Empty uses the Terraform caller; set only to the reviewed operator object ID |
| `native_agent_principal_id` | Leave empty initially; the staged workflow discovers the runtime instance identity after deployment and writes a separate RBAC variable file |
| `tags` | Add owner/environment/cost context consistent with your governance |
| `sharepoint_hostname`, `sharepoint_site_path`, `sharepoint_file_path` | Optional; leave unconfigured for the fixture-only demo |

Never paste a runtime principal from the status history. The initial plan explicitly
uses an empty runtime principal; later staged plans pass the verified generated
variable file. A blueprint principal is not the runtime identity.

Review the local **Search S1 default** and actual overrides before any plan approval.
Direct private indexers with built-in skills support S1+ on services created after
April 3, 2024; embedding skills also require a high-capacity region. The current
Central US Search service was created September 9, 2026. The generated private
Blob KS S2+ path is not used; its earlier quota blocker is historical. Eligibility
does not establish live CU/embedding acceptance. See
[the native prerequisites](native-ingestion.md#identity-network-and-cost-review).
Native ingestion adds a Search UAMI and three secondary dependency shared private
links, while removing the Function's CU/Search roles. Budget for scheduled CU/image
and embedding/model usage as well as tier/network costs. Live tier changes and
private-link approvals require separate authorization.
Bind all services to this environment's outputs, never IDs from another sample.

`EnvironmentName` labels azd and `.azure/<environment>/accelerator` progress;
**it does not create a separate Terraform backend/workspace**. Terraform uses the
selected `TerraformDir` and its state. For independent labs, use separate checkouts,
private inputs, protected state and unique resource naming. Do not assume different
names isolate address space if you connect the environments later.

When changing regions or VM size in tfvars, pass matching `-PrimaryRegion`,
`-SecondaryRegion` and `-JumpboxSize` values to the accelerator for its preflight.
Those script arguments do not rewrite Terraform variables. Model/SKU defaults,
subnet addressing and service settings have additional module-level constraints;
see the [architecture configuration map](architecture.md#configuration-versus-implementation).

## Prepare and run

Authenticate the workstation to the approved tenant/subscription using Azure CLI
and complete the independent tenant-permission checks below. The runner performs
its own managed-identity azd login; never transfer your login cache.

```powershell
$SubscriptionId = '<your-subscription-guid>'
$EnvironmentName = 'funwithfoundry-dev'
az login
az account set --subscription $SubscriptionId
az account show --output table
pwsh -NoProfile -File .\scripts\Get-RunnerToolManifest.ps1 -OutputPath .\.azure\runner-tools.json -PythonVersion 3.13.7
```

The [manifest generator](../scripts/Get-RunnerToolManifest.ps1) requires Windows,
Node.js and the local tools in the compatibility matrix. It downloads and verifies
four artifact categories: azd, uv, a PSF-signed Python installer and eight pinned
Foundry extensions. Review the manifest and adjacent `runner-tool-cache`; keep them
together outside Git. Generation does not install the runner or deploy resources.
Reuse an approved manifest rather than silently refreshing it midway through a run.

After local checks, permission review, manifest review and live approvals, run
one stage at a time. These commands describe the interface, not proof of a clean
full orchestrator run:

```powershell
$ToolManifestPath = (Resolve-Path .\.azure\runner-tools.json).Path
$Deployment = @{
    SubscriptionId = $SubscriptionId
    EnvironmentName = $EnvironmentName
    TerraformDir = (Resolve-Path .\terraform).Path
    ToolManifestPath = $ToolManifestPath
    PrimaryRegion = 'centralus'
    SecondaryRegion = 'southcentralus'
    JumpboxSize = 'Standard_D4s_v5'
}
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Preflight
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Infrastructure
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Workload -Resume
.\scripts\Invoke-Accelerator.ps1 @Deployment -Stage Verify -Resume
```

Stop on failure and inspect state before resuming. These interface examples are not
proof of a successful live run. `-ListStages` and `-WhatIf` support
local inspection without cloud calls; `-WhatIf` is not a Terraform plan or capacity
check. Actual `Preflight` reads Azure. Plans have explicit approval and hash checks.
The entrypoint has no teardown stage and does not run `azd provision`.

Keep the same environment, state directory and manifest throughout. `-Resume` skips
only fingerprint-matched completed steps, not arbitrary failed creates. After an
approved teardown, securely archive old progress evidence and start fresh without
reusing completion markers. Preserve state backups separately from progress records.

## Prerequisites

| Area | Requirement |
| --- | --- |
| Workstation | Windows, PowerShell 7.3+, Git, Terraform satisfying the committed constraint, Azure CLI with Bastion extension, azd, uv, Node.js/npm and native Windows `ssh`, `sftp`, `ssh-keygen` |
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
because an initial bootstrap needs them. Verify tenant authority and Function
authentication in your own environment. Recheck PIM immediately before execution;
a recorded expiration is not continuing authorization.

### Ingestion identity

The [ingestion auth module](../terraform/modules/ingest-function/auth.tf) creates a
single-tenant API application, its service principal, an `api://<api-client-id>`
identifier URI and an application role named `Ingestion.Invoke`. The root module
assigns that role to the **jumpbox managed identity**. The API service principal requires
assignment. The Function's own managed identity is a different identity, used for
Storage and optional Graph access. Native Search ingestion uses a separate UAMI
for staging reads and secondary CU/OpenAI access; the Function no longer owns those
processing steps or its former CU/Search roles.

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

This table records the implemented native sequence. The existing lab passed manual
migration/recovery and repeated normal Verify, not a clean full orchestrator run.
Do not assume a pre-refactor resume checkpoint satisfies this sequence.

| Stage | Required ordering and output | Completion evidence |
| --- | --- | --- |
| Preflight | Run implemented context, tool and capacity checks; separately confirm tenant authority, policy and private-runner readiness | Recorded pass/fail plus explicit unresolved gates; no credentials in output |
| Infrastructure | Initialize preserved state; create network and injected Foundry account prerequisites; ensure account capability host; finish project, connections, roles, project host and private endpoints | Terraform results plus readiness read-back; `Accepted` alone is insufficient |
| Workload | Prepare runner and approve exact dependency links; publish staging Function; stage fixture; initialize six explicit native Search definitions; bind toolbox/hosted code; discover runtime identity and reconcile RBAC | Package digest, `202 staged` receipt, configuration read-back, toolbox/agent version and role evidence |
| Verify | Validate infrastructure/private DNS and authorization; initialize with guarded receipt refresh after probes; verify blob provenance, fresh indexer execution, child chunks, IQ/native retrieval and public refusal | Correlated request/source/blob/chunk evidence and sanitized per-check outcomes; two normal runs passed without agent redeployment |

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
The planner does not invoke the hosted agent. Preserve this primary planner link.
Separately approve Search's three new links to secondary staging (`blob`), CU
(`foundry_account`) and OpenAI (`openai_account`) after exact-target review.

Contract version 2, owner `accelerator-native-indexer`, uses API `2026-08-01-preview`
for six explicit definitions: `spo-native-datasource`, `spo-native-index`,
`spo-native-skillset`, `spo-native-indexer`, `spo-native` (kind `searchIndex`) and
`spo-native-knowledge-base`. The private indexer runs on creation and a `PT5M`
schedule. Azure Search executes CU with semantic 500-token/zero-overlap chunking,
images/location and `gpt-5.2`, followed by 3072-dimensional embeddings and child
projections. The toolbox requests `vector_semantic_hybrid` against that index.
This is not auto-generated KS ingestion or custom Function enrichment. Existing
definition mismatches block; no automatic update, migration, delete or fallback occurs.

Any safe embedding output name, such as `text_vector`, is accepted only with a
consistent projection; omitted/null semantic overlap means zero. These canonical
aliases preserve the explicit contract and do not prove live service compatibility.
The existing lab passed live native ingestion and retrieval with the required
roles; each new deployment must verify its own grants and propagation.

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
hashes and managed-identity azd login. These passed the recorded rebuild, but each
new private VM needs its own tool and identity verification. Its private PowerShell
[Initialize-KnowledgeBase.ps1](../scripts/Initialize-KnowledgeBase.ps1) owns creation
and read-back of all six explicit definitions. The Python helper delegates to it. Keep
both shared contracts with the checkout and derive all required inputs from the
current outputs; do not reuse the old initializer's argument list. Success is
`configuration-only`, `indexing_verified: false`, not an indexing wait. Verify every
installer and extension path before live acceptance.

The verified bundle carries four artifacts: azd, uv, the official Python `3.13.7`
Windows installer and the eight-extension bundle. Installer SHA-256 values and
Microsoft/PSF signatures are checked. Python is installed at an explicit runner
path; verification uses that interpreter with `--no-python-downloads`.
All four artifacts were transferred and hash-verified during the recorded rebuild,
and fresh-VM installation passed. Keep those checks separate in your own run. Workload
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

The implemented management flow is:

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

The local guard assertions cover scope, integrity, ARM envelopes, SSH options,
guest publication/cleanup, credential ACLs, idempotence and failure cleanup. They
are assertions over a narrow privileged transport surface, not live scenarios.
Record the actual count printed by the current run rather than a historical total.
The recorded rebuild verified all four artifacts and cleanup after an approved
restart, followed by tool installation and workload acceptance. On a new image,
repeat servicing, installation, cleanup and workload checks rather than assuming
one successful transfer proves them all.

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
The optional Python IQ launcher has no dedicated lock and invokes the same PowerShell
initializer. Keep the full checkout and both shared JSON contracts; there is no
independent Python index writer or custom-index fallback.

[Deploy-IngestFunction.ps1](../scripts/Deploy-IngestFunction.ps1) copies the complete
hashed Function lock into packaged requirements for the Oryx build. Native source
staging uses `--require-hashes` and `-r requirements.lock` before remote build.
Both preserve pinned versions and hashes. The original direct requirements remain resolver
inputs, not the deployment install contract. Installing packages on the runner does
not install them in the remote Function or hosted runtime.

## Complete demo

The `Verify` flow prepares the locked client environment, runs authorization/staging
probes, initializes knowledge with guarded receipt refresh, and runs
[Invoke-EndToEnd.ps1](../scripts/jumpbox/Invoke-EndToEnd.ps1). Two normal fixture-backed
Verify runs passed without manual rebind or agent redeployment. Confirm the actual
manifest/parameter contract and live approvals before using the stage examples.
Read [resume guidance](#resume-and-release) first: successful fingerprint-matched
steps can be skipped, so a skipped step is not a fresh live test.

For an additional interactive question after successful `Verify`, use an approved
session **on the jumpbox**. Get the exact transferred source path from the
`Workload.Transfer` output in the protected workstation accelerator state; do not
select an arbitrary old fingerprint directory. Substitute that path below. The
staged manifest contains deployment context, not bearer tokens:

```powershell
$RunnerSource = '<exact Workload.Transfer source path on this jumpbox>'
$EnvironmentName = 'funwithfoundry-dev'
Set-Location -LiteralPath $RunnerSource
$Manifest = Get-Content .\deployment-manifest.json -Raw | ConvertFrom-Json
if ($Manifest.environment -ne $EnvironmentName) { throw 'Runner environment mismatch' }
$ClientPython = "C:\ProgramData\FunWithFoundry\$EnvironmentName\verification-venv\Scripts\python.exe"
if (-not (Test-Path $ClientPython)) { throw 'Complete Verify to prepare the locked client environment' }
& $ClientPython .\src\hello_world\ask_agent.py --project-endpoint $Manifest.project_endpoint --search-tool-name $Manifest.search_connection --model $Manifest.agent_model --question 'When is the fictional launch date of Project Cedar?'
if ($LASTEXITCODE -ne 0) { throw 'Private client validation failed' }
```

The staged workspace has the script directory and shared source it needs. Its
identity must still be authorized. Bastion SFTP/Run Command bootstrap does not
certify interactive RDP in every environment; arrange approved operator access
before using this interactive example. The generic `Invoke-JumpboxScript` wrapper
does not forward the mandatory parameters of the probes below.

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
The Function module enables the constrained fixture by default. The fixture is generated in
the **SCUS Function**, then follows the same raw-byte staging path as SharePoint.
Success is HTTP `202`, `status: staged`, with request/source/hash and blob identifiers.
The Function neither extracts nor indexes. Reruns overwrite the stable
`native/{source_id}/source.ext` blob; they do not create immutable hash paths.

Before retrieval acceptance, require HEAD checks against blob provenance/ETag,
a fresh successful native indexer execution and nonempty child chunks. Child
`doc_url` comes from `metadata_storage_path`, so it is the staged blob URL, not the
SharePoint URL or `originalSource`. Projection aliases `/metadata_storage_path` and
`/document/doc_url` require the exact untransformed indexer mapping
`metadata_storage_path` to `doc_url`. Retain the original source ID/hash and encoded
original URL as blob metadata, not promised child fields. See the
[acceptance boundary](native-ingestion.md#provenance-and-acceptance). Manually staging
a blob under `native/` can test the same native indexer without a Function call;
retain required provenance metadata. Neither that test nor the fixture proves
the actual SharePoint fetch, connector permissions or full SharePoint cross-region path.

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

Keep proof separate: `Test-Ingestion` tests staging and selected auth/input negatives;
it does not prove indexing, retrieval or public isolation. Initializer success also
does not prove indexing. Correlate Function request/source/blob metadata, fresh
indexer evidence and generated child references with IQ/native retrieval. Historical
Function-to-Search transit evidence belongs to the old custom pipeline only.

Run [Test-PublicDataPlaneRefused.ps1](../scripts/Test-PublicDataPlaneRefused.ps1)
from outside the private network. Public HTTP 200 is failure; a generic authorization
403 is inconclusive, not proof of network isolation. Include an unapproved caller
test from inside the VNet. Its absence remains `not_tested`, not passed.

### Optional SharePoint

Actual SharePoint integration is deferred because no sample is available and does
not block publication of the fixture-backed baseline. Accepted structure is not
technical proof or consent. The attempted-source and administrator blockers remain
in [VALIDATION.md](VALIDATION.md#current-native-follow-up).

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
and staging, native indexing and retrieval gates succeed. For the complete path,
use the [private verifier example](native-ingestion.md#private-sharepoint-verification)
with `-Mode sharepoint` and explicit source-derived question and expected answer.
Synthetic success never implies SharePoint success; staged-blob citations do not
restore SharePoint ACLs.

## Resume and release

Native initialization checks all six existing definitions before writing missing
ones using `If-None-Match: *`. It refuses mismatches, including a historical
`azureBlob` KS named `spo-native`, and never deletes definitions. The datasource-only
exceptions are reviewed `-RebindDataSource` and opt-in `-RefreshDataSourceBinding`.
Refresh requires a valid receipt with all configuration matching and only a stale
ETag, then performs one PUT with the current `If-Match` ETag and verifies a new
receipt. HTTP 412 is not retried; a matching current receipt stays read-only.
Missing/wrong receipts require reviewed rebind; visible mismatches block. See
[receipt and resume gates](native-ingestion.md#datasource-receipt-and-resume). Partial
creation can remain after blocked read-back; the enabled indexer may already be
running. Preserve the failed S2-attempt evidence, inventory exact surviving resources
and seek approved recovery. Do not delete the old custom pipeline, force a tier
upgrade or weaken validation to bypass a conflict.

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
baseline and [VALIDATION.md](VALIDATION.md) for the recorded rebuilt environment.
Documentation or dependency updates do not redeploy that environment; record a new
live acceptance result only after executing the applicable checks there.
