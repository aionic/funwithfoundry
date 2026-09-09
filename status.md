# Native Foundry Agent Migration Status

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

| Resource | Current value |
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

The current ignored `terraform/terraform.tfvars` contains the correct value:

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

## Worktree Boundaries

Expected native-agent work includes:

- `AGENTS.md`
- `azure.yaml`
- `toolbox.yaml`
- `src/foundry_native_agent/`
- `scripts/Deploy-NativeFoundryAgent.ps1`
- Native-agent changes in `terraform/main.tf`, `terraform/outputs.tf`,
  `terraform/variables.tf`, and `terraform/terraform.tfvars.example`
- Existing staged Foundry module changes must be reviewed before inclusion.
- This `status.md` handoff.

Do not automatically include or revert these unrelated/user-owned changes:

- Existing `.beads/*` history beyond the new handoff task.
- `.gitignore` until its user-owned change is reviewed.
- `scripts/Export-FoundryDiagnostics.ps1`.
- Any later user edits to ignored `terraform/terraform.tfvars`.

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