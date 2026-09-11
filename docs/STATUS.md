# Solution Accelerator Status

**Current baseline, 2026-09-11:** the existing S1 lab passed native fixture-backed
indexing, IQ and strict IQ-then-hybrid-Search retrieval. Agent 3/toolbox 2 remain
active with the unchanged runtime principal. TXT/root-site staging fixes and guarded
datasource receipt refresh are deployed; two normal Verify runs passed without
manual rebind or agent redeployment. The full local release gate passed 81 Python
tests with zero skips, PowerShell 7/5.1 checks, five mocked Terraform tests and
documentation checks. Three public endpoints returned `NetworkDenied` 403.

**SharePoint is deferred, not validated.** No sample is available, so the user
accepted the structure for publication without further integration work. This is
not source-acquisition proof or permission approval. The attempted-source and
administrator blockers remain in the validation record. A clean full orchestrator
run, deletion acceptance, production SLA and ACL trimming remain unproven.

The jumpbox is confirmed `PowerState/deallocated`. Retained services continue
billing. No further cloud actions are planned for this publication.

## Page index

| Topic | Reference |
| --- | --- |
| Current native ownership, formats and receipt gates | [Native ingestion](native-ingestion.md) |
| Live correlations, package hash and consent blocker history | [Current validation](VALIDATION.md#current-native-follow-up) |
| Deployment and operating procedures | [Deployment](deployment.md) and [operations](operations.md) |
| Local release checks and runtimes | [Testing](TESTING.md) and [compatibility](compatibility.md) |
| Optional future SharePoint setup | [Administrator handoff](native-ingestion.md#sharepoint-administrator-handoff) |

The dated sections below preserve earlier acceptance and recovery history; they
do not override the current baseline.

## Historical initial S1 acceptance

The following records the earlier S1 pass and its then-open blockers, superseded
where noted by the current baseline above. Its correlation and artifact evidence
are preserved.

**Recorded status, 2026-09-11 UTC:** the deployed explicit S1 native Search pipeline
passed live fixture end-to-end acceptance, IQ retrieval and strict native IQ-then-Search
verification. This was reviewed manual migration/recovery, not a clean orchestrator
DAG pass. **Actual SharePoint ingestion, repeated unattended resume and deletion
proof remain open** under Beads `funwithfoundry-1zn`.

The deployed Function returns `202 staged` after overwriting
`native/{source_id}/source.ext`; it has no CU/Search calls, roles or settings. The native `spo-native`
KS is kind `searchIndex`, not `azureBlob`. Contract version 2, owner
`accelerator-native-indexer`, defines six explicit resources: `spo-native-datasource`,
`spo-native-index`, `spo-native-skillset`, `spo-native-indexer`, `spo-native` and
`spo-native-knowledge-base`. All six are initialized. Azure Search executes native CU semantic 500-token/
zero-overlap chunking with `gpt-5.2`, images/location metadata, 3072-dimensional
embeddings in South Central US and child projections. The actual exported skillset
and its unchanged final ETag are recorded in [VALIDATION.md](VALIDATION.md).
Vectors were not retrievable: schema dimensions and hybrid toolbox behavior were
verified, not a direct 3072-element array readback.

Live Search `fwfun2basearch` remains `standard` (S1) with public access disabled.
Direct private built-in-skill indexers support S1+ on services created after April 3,
2024; embeddings also require a high-capacity region. The current Central US service
was created September 9, 2026. The generated private Blob KS S2 path is not used;
its quota blocker is historical, not a blocker for this live S1 path. The same UAMI,
primary planner link and security boundaries remain. All three new shared links
(`blob`, `foundry_account`, `openai_account`) and the primary planner link are
Approved/Succeeded. Control-plane verification and three authenticated public
data-plane probes with explicit `NetworkDenied` 403 responses passed.

Live request `f2e76769-c8ee-4e51-9db4-f7e7b07e9aeb` matched blob provenance,
freshness, ETag and source hash to a fresh indexer run with 1 processed, 0 failed
and 1 child. Agent version 3 and toolbox version 2 use the new KB and unchanged
instance principal `aae32b47-acce-485e-9097-342c428fcd5b`. All three golden cases
(15 October 2026 launch, 30-day retention, unknown budget) passed with both matched
tool outputs; seven live authorization/staging negative checks also passed.

The actual SharePoint attempt returned HTTP 415 because the configured
`funwithfoundry-architecture-note.txt` is outside the Function's PDF/PNG/JPEG allowlist.
Rejection occurred **before Graph**: consent and source fetch are not proven, not
diagnosed as missing. No SharePoint content or permissions were changed.

Indexer execution changed the server datasource ETag and invalidated its binding
receipt. The live pass required explicit `-RebindDataSource` immediately before
Verify in the ignored recovery driver. Exact ETag/configuration checks and strict
missing/null-credential handling remain; unattended resume is not certified.

The final S1 full local release gate passed after the receipt/runtime fixes:
69 Python tests with zero skips, initializer 8292 and ingestion 1132 checks on
PowerShell 7 and 5.1, operational 6453 checks, Terraform validation and five mocked
Terraform tests, and documentation checks. Existing `eval.yaml` was reused as local intent;
no cloud evaluators ran. The jumpbox is confirmed `PowerState/deallocated`; retained
services continued billing.

See [native ingestion](native-ingestion.md) for the migration/ownership guide.
Original implementation plans and diagrams remain historical custom-ingestion
artifacts. A reviewed new diagram contract is required before authoring/rendering
replacement artwork. Work tracking remains in Beads.

## Historical S2 attempt

The earlier generated private Blob knowledge-source approach encountered an S2
quota blocker. Preserve that failed-attempt evidence and any partial-resource
inventory; it is not the active eligibility gate for the explicit S1 indexer path.
An old `azureBlob` KS named `spo-native` conflicts with the new `searchIndex` KS.
Resolve exact surviving definitions only through approved recovery, without
automatic deletion or loss of historical Function proof. See
[migration and recovery](native-ingestion.md#migration-and-binding-gates).

## Historical v1 rebuild acceptance

**Recorded status:** custom-ingestion rebuild and core live acceptance passed,
2026-09-10 UTC. **Historical tracking:** Beads epic `funwithfoundry-106`, live
rehearsal `funwithfoundry-dfu`.

The bullets below retain the original v1 results; they do not validate the subsequent
native-ingestion refactor. See [VALIDATION.md](VALIDATION.md) for historical results, correlation IDs,
recovery boundaries and explicitly untested optional scenarios. Publication and
GitHub-hosted checks passed separately from the accepted live deployment.

- Historical custom-ingestion implementation, approved architecture PNGs, and the full local release gate passed.
- The old lab was fully torn down: both Foundry accounts purged, all three lab
  resource groups verified absent, and Terraform state reconciled to empty.
- Live private SFTP transferred and verified the four pinned bootstrap artifacts.
  Temporary-account cleanup required an approved jumpbox restart and was verified
  through a durable managed Run Command. Fresh-VM tool installation subsequently passed.
- Fresh preflight passed 51 checks. The first Terraform apply created eight
  resources, including the primary network and `fwfun2bafoundry` account.
- Both capability hosts and the remaining infrastructure are now deployed. A
  recovery apply completed 51 outstanding creations after a DNS request reset;
  the subsequent full Terraform plan reported no changes.
- The staged Infrastructure check completed, including Search shared-link approval.
  Workload source transfer, all four artifact hashes, cleanup, and offline tool
  installation are verified on the new jumpbox. Search/IQ initialization passed.
- The Function remote build and `ingest` trigger discovery passed after retaining
  the pinned PyJWT crypto extra for pip 23 compatibility. Seven live ingestion and
  authorization checks, Search provenance and IQ retrieval passed.
- Native agent version 1 and toolbox version 1 passed end-to-end dual retrieval,
  all three golden questions and two same-version workflow readbacks. The verified
  instance principal is `aae32b47-acce-485e-9097-342c428fcd5b`.
- Final infrastructure verification passed 38 checks; public network denial passed
  for all three endpoints. Final Terraform plan: no changes. Temporary transfer
  users, tasks, keys, firewall rules and locks: none.
- The jumpbox is confirmed deallocated. The rebuilt services remain deployed and
  continue billing. All six implementation/rehearsal phases are closed; publication
  and hosted checks are complete under `funwithfoundry-eei`.
- Published to GitHub `main` in commit `00ffc1d`, with CI compatibility fixes through
  `ef23830`. The exact staged publication snapshot passed the local secret scan.
  [GitHub Actions run 34493693637](https://github.com/aionic/funwithfoundry/actions/runs/34493693637)
  passed Windows release checks, Linux runtime checks and the hosted secret scan.
- Read-only GitHub verification found no protection on `main` and no repository
  rulesets. Checks pass but are not enforced as merge requirements. Administrative
  follow-up `funwithfoundry-48p` requires policy authorization; no settings changed.

The deployed identifiers and results below describe the previous environment,
which has been removed. Do not reuse its agent principal or treat its acceptance
results as evidence for the new deterministic runtime.

## Historical Native Foundry Agent Migration

**Status:** Complete on 2026-09-09
**Branch:** `main`
**Starting HEAD:** `1115cad Harden keyless access and refresh architecture docs`
**Beads:** `funwithfoundry-3pt` (`closed`, P0, assigned to `aionic`)

## Objective

Replace the hidden classic Assistants API validation with a New Foundry native Python hosted
agent. The native agent must validate the same private retrieval path through both:

1. Foundry IQ knowledge-base retrieval.
2. A native Foundry Toolbox backed by the private Azure AI Search index.

The final response must be grounded, preserve exact technical values, include sources, and prove
that both retrieval tools ran.

## Azure Environment

| Resource | Historical value (2026-09-09) |
|---|---|
| Subscription | `05322c41-8e40-4575-9bc7-4509758926fb` |
| Tenant | `a90072fb-63bb-4099-bf52-e3b41616cec4` |
| Foundry account | `fwf1wj5gfoundry` |
| Foundry project | `fwf1wj5gproj` |
| Project endpoint | `https://fwf1wj5gfoundry.services.ai.azure.com/api/projects/fwf1wj5gproj` |
| Search service | `fwf1wj5gsearch` |
| Search connection | `fwf1wj5gsearch` |
| Search index | `spo-docs` |
| Foundry IQ knowledge base | `spo-knowledge-base` |
| Native toolbox | `foundry-rag`, version 2 (`query_type: simple`) |
| Native hosted agent | `funwithfoundry-rag-agent` |
| Active deployed version | Version 5 |
| Runtime identity | `1b057bfd-04f1-464b-ab37-c79b8e771a8b` |
| Private deployment runner | `vm-fwf-cus-jump` |

## Completed

- Added `azure.yaml` for an adopted Foundry project and native direct-code agent deployment.
- Added `toolbox.yaml` defining AAD-only Search grounding over `spo-docs`.
- Added `src/foundry_native_agent/main.py` and its Python requirements.
- Added `scripts/Deploy-NativeFoundryAgent.ps1` as the portable deployment wrapper.
- Deployed and published toolbox `foundry-rag:2` with the expected Search connection, `spo-docs`
  index, and `query_type: simple` for the text-only index.
- Deployed native agent versions 1 through 5.
- Version 5 is active with `python main.py`, Responses protocol `2.0.0`, Python 3.13, `1` CPU,
  and `2Gi` memory.
- Added the explicit `FOUNDRY_PROJECT_ENDPOINT` container environment mapping.
- Granted the native runtime identity `Foundry User` on the project.
- Granted the native runtime identity `Search Index Data Reader` on Search.
- Added both native runtime assignments to Terraform and imported the existing assignments.
- Granted the jumpbox/Tommy identity `Foundry Project Manager` on the project.
- Added the primary Foundry location and project resource ID to Terraform outputs.
- Full Terraform validation and plan returned no changes on 2026-09-09.
- Pylance found no syntax errors in the current native agent source.
- The exact acceptance prompt completed and called both `retrieve_foundry_iq` and
  `fwf1wj5gsearch`; both returned the same indexed architecture note.
- The final answer preserved `BLUE-HERON-42`, explained `172.16.0.0/24`, and included sources.
- `scripts/Verify-Deployment.ps1` returned 24 PASS, 0 WARN, 0 FAIL.
- Public Foundry, Content Understanding, and Search data-plane probes all returned HTTP 403.
- The live classic assistant `funwithfoundry-kb-agent` was deleted and verified absent.

At that historical acceptance, the ignored `terraform/terraform.tfvars` contained
the following value; it is not an input for a new deployment:

```hcl
native_agent_principal_id = "1b057bfd-04f1-464b-ab37-c79b8e771a8b"
```

## Deployed Version History

| Version | State | Important result |
|---|---|---|
| 1 | Active/older | Initial direct-code deployment; invocation timed out before session readiness. |
| 2 | Active/older | Increased to `1` CPU and `2Gi`; session still failed readiness. |
| 3 | Active/older | Added `FOUNDRY_PROJECT_ENDPOINT`; logs exposed the missing `langgraph.json`. |
| 4 | Active/older | Switched to the supported direct `main.py` Responses host. |
| 5 | Active/current | Enforced full-question calls to both IQ and toolbox Search; acceptance passed. |

Version 5 metadata confirms these container values:

- `AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-4o`
- `FOUNDRY_IQ_KNOWLEDGE_BASE=spo-knowledge-base`
- `FOUNDRY_PROJECT_ENDPOINT=<private project endpoint>`
- `SEARCH_ENDPOINT=https://fwf1wj5gsearch.search.windows.net`
- `TOOLBOX_NAME=foundry-rag`

The runtime principal did not change across versions 1-5, so the Terraform-managed RBAC remains
correct.

## Verified Failure And Root Cause

The exact validation prompt was invoked against version 3:

> What is the maintenance window code, and why is the agent subnet 172.16.0.0/24?

The request created a conversation and assigned hosted session
`d51a2fdbd3b9bd6c4d3bb05d19bd96c1baafbcdf2590babc573b6bc3ade343b`, but returned:

```text
HTTP 424 Failed Dependency
code: session_not_ready
trace ID: 16adfb5744cfe0b6e8ee317c23b1af9f
```

`azd ai agent monitor` then exposed the container exception:

```text
run.py: error: langgraph.json was not found in /app
```

This proves the failure occurs before model or tool execution. It is not a Search RBAC, Foundry IQ,
toolbox, subnet, or model-capacity failure.

## Resolved Hosted-Agent Failures

The deployed source now follows the official Foundry Toolbox hosting pattern:

- `azure.yaml` uses `codeConfiguration.entryPoint: main.py`.
- `main.py` asynchronously loads `AzureAIProjectToolbox` tools.
- `main.py` builds the LangGraph agent with the local Foundry IQ tool plus toolbox tools.
- `main.py` launches `ResponsesHostServer` directly.
- The direct host no longer depends on `langgraph.json` or the configuration-driven
  `langchain_azure_ai.agents.hosting.run` entrypoint.

Pylance syntax validation and live version-5 invocation passed after this change.

The native Search toolbox initially defaulted to `vector_semantic_hybrid`, which failed because
`spo-docs` has no vector field. Toolbox version 2 explicitly uses `query_type: simple` and returns
the indexed document successfully.

## Evaluation Status

The normal azd evaluation command is affected by an intermittent nested credential failure:

```text
AzureDeveloperCLICredential: exit status 1
```

Observed behavior:

- Synthetic dataset generation was submitted twice through the same private REST API and returned
  service-side HTTP 500 `internalFailure` both times.
- Rubric evaluator generation was accepted as job `evaluatorgen-smoke-core-v1-77f89330` and was
  still in progress at the last check.
- A checked-in three-case fallback dataset and `eval.yaml` use built-in `task_adherence` and
  `tool_call_accuracy` evaluators.
- Eval group `eval_10d6e409a453484ebbae08d0b57f93c7` was created.
- Runs `evalrun_701321bbad634023b3b85bde37d74658` and
  `evalrun_2521268df68e45aeb485ecd2d94daa4f` both failed before processing any item because
  the evaluation service could not establish SSL while initiating its ACA session. Both returned
  `total=0`, so this is an evaluation-plane platform failure rather than an agent score.
- The checked-in fallback evaluation ran all three golden cases directly against version 5.
  Every case completed, called both `retrieve_foundry_iq` and `fwf1wj5gsearch`, and matched its
  expected grounded facts: `FUNCTIONAL_EVAL=3/3`.

The local workstation cannot deploy directly because the project and agent data-plane endpoints
are private. Deployment must run inside the VNet or through an equivalent private runner.

## Release Completion

- The copied jumpbox deployment workspace was removed.
- Jumpbox `FWF*` task and temp-file counts are zero.
- Temporary WinRM HTTPS listener, certificate, and firewall rule were verified absent.
- The local Bastion tunnel was verified closed.
- The jumpbox was deallocated.

## Completed Release Work

- Updated `README.md`, `docs/architecture.md`, and `docs/PLAN.md`.
- Updated both Mermaid diagrams for separate IQ and toolbox Search paths.
- Replaced the classic Assistants API verification script with native Responses invocation.
- Updated the Python sample client to invoke the native hosted agent.
- Retained legacy debug scripts as historical troubleshooting tools; they are no longer the
  documented validation path.
- Re-ran Pylance syntax, PowerShell parsing, Terraform format/validate/plan, deployment checks,
  public refusal checks, and the native dual-tool verification.

## Temporary Cleanup State

The 11 completed `FWF*` scheduled tasks and all associated `C:\Windows\Temp\fwf-*` files were
deleted before pausing. The cleanup check returned `remainingTasks=0 remainingFiles=0`, including
removal of an earlier deployment log that may have contained short-lived token command output.
The local Azure CLI Python process owning the temporary Bastion tunnel listener on
`127.0.0.1:55986` was also stopped, and the port was verified closed.

The temporary WinRM HTTPS listener, firewall rule, and certificate created for Bastion-based file
transfer were removed and verified absent. Only the default WinRM HTTP listener remains.

## Acceptance Gate

The migration behavior, infrastructure, cleanup, and documentation gates are complete. The
Foundry cloud-evaluation ACA TLS failure is retained above as a platform limitation; direct
three-case functional evaluation passed 3/3.
