# Rebuild Validation

## Native publication checks

The documentation cleanup and native S1 publication snapshot passed the complete
local release gate on 2026-09-11: 81 Python tests with zero skips, PowerShell 7/5.1
checks, root/module Terraform validation and five mocked Terraform tests. The
documentation gate checked 10 YAML files, 21 Markdown files and 329 local links,
with two temporary Mermaid renders. This workstation run used Terraform 1.16.2;
CI remains pinned to 1.15.8. Neither this run nor structure acceptance certifies
actual SharePoint ingestion, source deletion or a clean full deployment rehearsal.

## Current native follow-up

**2026-09-11, 15 UTC follow-up:** the TXT/root-site Function fixes and guarded
datasource refresh are deployed and verified in the existing S1 lab. Two normal
`Invoke-RunnerWorkload Verify` runs passed without manual `-RebindDataSource` or
agent deployment. This closes the observed normal Verify receipt-drift failure,
not the full orchestrator DAG or deletion proof. Actual SharePoint acquisition
encountered the administrator blockers recorded below; no actual SharePoint CU proof
is claimed. The user subsequently deferred actual integration because no sample
is available and accepted the structure for publication. That decision neither
resolves the technical blockers nor authorizes grants. Beads `funwithfoundry-i2e` has verified fix evidence,
`funwithfoundry-un8` is deferred until a sample and appropriate consent are available.
The structural correction `funwithfoundry-1zn` is complete within the accepted
fixture-backed scope. Fresh deployment and deletion follow-up is tracked separately
as `funwithfoundry-cgl`.

| Follow-up gate | Evidence |
| --- | --- |
| Function package | Deployment `077916bd-dee7-4c46-be1f-7b9965eb9de6`; SHA-256 `e5e895a83396d468ab404abd78c4f95f737c9f9ee42c5841cee797dd7f0e78d8` |
| TXT and root-site handling | PDF/PNG/JPEG plus valid UTF-8 TXT with optional BOM, `text/plain` and optional UTF-8 charset; root Graph site URL fixed; raw bytes preserved, no Function extraction/conversion/chunking/embedding/Search/CU |
| First normal Verify | Request `37335ca7-e6fc-4ea8-be6f-a909614ae38c`; indexer `2026-09-11T14:59:14.138Z`; seven authorization probes, receipt refreshed, 1 processed/0 failed, IQ and strict dual retrieval passed |
| Second normal Verify | Request `fb9531bc-584d-447b-b7c1-ab4023a0fb50`; indexer `2026-09-11T15:00:59.441Z`; same seven probes, refresh, 1 processed/0 failed, IQ and strict dual retrieval passed |
| Immediate receipt reuse | Initializer reported `reused-receipt` at the same ETag `0x8DF1015C17C07F9`; no PUT |
| Runtime continuity | Agent 3 active, new KB, unchanged principal `aae32b47-acce-485e-9097-342c428fcd5b`; neither Verify redeployed the agent |
| Public isolation | Three authenticated public checks again passed explicit `NetworkDenied` 403 |
| SharePoint attempt | HTTP 502 after TXT fix, superseding earlier pre-Graph 415; configured file unchanged |
| Consent inventory | Function Graph app-role assignments empty, count 0 with no more pages: missing `Sites.Selected` confirmed |
| Delegated Graph limits | Root site resolved; exact item metadata GET and site-permissions GET both 403 `accessDenied`; site-specific consent and file existence unknown |
| Scope and shutdown | User approved fresh two-hour Owner PIM for existing lab only; no directory/site/content permissions changed; VM confirmed `PowerState/deallocated` |

The default-off initializer switch `-RefreshDataSourceBinding` allows one
`If-Match` PUT using the current server ETag only when a valid receipt binds the
same configuration and only its ETag is stale. Readback validates the resulting
definition/ETag before saving the receipt. Wrong/missing receipts or visible-field
mismatches block; no HTTP 412 retry is allowed. Explicit `-RebindDataSource` remains
the reviewed adoption path, not normal resume. Knowledge and Verify enable guarded
refresh; Verify invokes initialization after authorization probes immediately
before end-to-end verification, including when a prior checkpoint exists.

The private verifier now accepts `-Mode fixture|sharepoint` (default `fixture`).
SharePoint mode requires explicit `-Question` and `-ExpectedAnswer`; the returned
staging mode must match. All existing fresh-indexer, blob provenance, IQ and strict
agent checks remain. See [private SharePoint verification](native-ingestion.md#private-sharepoint-verification)
for the complete parameter mapping. Documented CU TXT format support was checked
against [Microsoft Learn](https://learn.microsoft.com/azure/search/cognitive-search-skill-content-understanding)
on 2026-09-11; it is not evidence of successful SharePoint fetching or processing.

### SharePoint administrator boundary

Site-permissions failure correlation: request
`41442a50-567e-4f09-b8b1-7019a29111d9`, `2026-09-11T14:56:25Z`.
Function object ID is `65e3040f-ded9-4a0b-8c72-70d25909363e`; client ID is
`554fb4b7-63de-4dd4-ac10-ab75e7d75c5f`. The root site is
`https://mngenvmcap669594.sharepoint.com`, resolved ID
`mngenvmcap669594.sharepoint.com,c343a8c6-62f8-4f7a-bb00-b0bce5ce6a66,f2fa0d62-46c3-4c1d-a800-c7f5b9f039a7`.
The configured source remains `funwithfoundry-architecture-note.txt`.

An authorized administrator needs a Graph client permitted to manage site
permissions (`Sites.FullControl.All` on the **consenting client, not the Function**)
and authority to assign the Graph application role. After reviewing existing
grants, use the [existing inventory-first helper](native-ingestion.md#sharepoint-administrator-handoff)
for `Sites.Selected` plus read on this one site, without a broader Function role
or tenant-wide fallback. Azure subscription Owner PIM does not supply those
directory/client permissions. No permission changes were attempted in this follow-up.

### Follow-up local gate

The full predeployment gate passed, saved at
`.azure/s1-followup-local-validation.log`:

| Check | Follow-up result |
| --- | --- |
| Python | 81 passed: 40 ingestion, 29 retrieval, 12 schema; zero skips |
| Initializer | 12237 checks on both PowerShell 7 and Windows PowerShell 5.1 |
| Deployment | 456 checks |
| End-to-end | 1333 checks on both PowerShell versions, including 201 new mode checks |
| Operational guards | 6453 checks |
| Terraform | Five mocked tests passed |
| Documentation | 286 local links passed |

The follow-up acceptance record is retained privately at
`.azure/exports/s1-followup-20260911/acceptance.json`; it and the full-gate log are
Git-ignored evidence, not checkout prerequisites. The earlier S1 artifact and
skillset export below remain valid historical evidence. No cloud evaluators,
clean full orchestrator run or deletion acceptance are claimed. Retained services
continue billing; no further cloud actions are planned for publication.

## Historical initial S1 evidence boundary

The following preserves the earlier S1 pass, including its then-open TXT and
receipt blockers. The current follow-up above supersedes those blocker diagnoses
and local-gate counts without replacing the original correlation or skillset proof.

As of **2026-09-11 UTC**, the deployed explicit S1 native-indexer path passed live
fixture end-to-end acceptance. Migration used reviewed manual recovery, not a clean
orchestrator DAG run. Actual SharePoint ingestion, repeated unattended resume and
deletion proof remain open under Beads `funwithfoundry-1zn`. **The final S1 local
release gate passed after the receipt/runtime fixes**, independently of the live
acceptance below.

| Native gate | Current evidence boundary |
| --- | --- |
| Function staging | Deployed, live `202 staged`, stable `native/{source_id}/source.ext` raw blob; no CU/Search calls, roles or settings |
| Six native definitions | Initialized contract version 2, owner `accelerator-native-indexer`; explicit datasource/index/skillset/indexer/`searchIndex` KS/KB; actual skillset exported and final ETag unchanged |
| S1, UAMI and private dependencies | `fwfun2basearch`, Central US, created 2026-09-09, remains `standard` S1 with public access disabled; same UAMI; three new links (`blob`, `foundry_account`, `openai_account`) plus primary planner Approved/Succeeded |
| Fresh indexing and retrieval | Passed: 1 processed, 0 failed, 1 child; matching blob metadata, freshness, ETag and source hash; IQ and strict native IQ-then-Search passed |
| Runtime and golden cases | Agent 3, toolbox 2, new KB, unchanged instance principal; launch 15 October 2026, retention 30 days and unknown budget all passed with both matched tool outputs |
| Authorization and public denial | Seven live authorization/staging negative checks passed; three authenticated public data-plane probes passed with explicit `NetworkDenied` 403 |
| Control plane and shutdown | Live report passed after replacing Azure CLI's conflicting `--scope --all` with `--scope --include-inherited` without `--all`; jumpbox confirmed `PowerState/deallocated` |
| Parent orchestration / resume | Reviewed manual recovery; datasource ETag drift after indexer execution required explicit rebind immediately before Verify; repeated unattended resume not certified |
| Actual SharePoint cross-region ingestion | Attempt returned 415 for configured `.txt`, rejected before Graph by PDF/PNG/JPEG allowlist; consent and source fetch not proven, not diagnosed as missing; no content or permission changes |
| Diagrams | Original custom-ingestion assets retained unchanged; new native contract review required before authoring/rendering |

See [native ingestion](native-ingestion.md) for ownership, staged-blob citation
semantics and migration blockers, and [TESTING.md](TESTING.md) for current focused
checks. The final release gate passed **69 Python tests with zero skips** (28 ingestion,
29 retrieval, 12 schema), 6453 operational checks, 383 deployment checks, 8292 initializer
and 1132 ingestion checks on both PowerShell 7 and 5.1, Terraform validation and five
mocked Terraform tests. Documentation passed 10 YAML files, 21 Markdown files,
286 local links and two temporary Mermaid renders. The full log is Git-ignored at
`.azure/s1-final-local-validation.log`. These cloud-free checks do not replace live
acceptance or cloud evaluator scores. Documentation validation may
render existing diagrams to temporary files without changing historical assets.

### Live S1 correlation and skillset

- End-to-end request: `f2e76769-c8ee-4e51-9db4-f7e7b07e9aeb`.
- Successful indexer execution: `2026-09-11T02:28:58.498Z`, 1 processed, 0 failed,
  1 projected child with matching staged-blob provenance.
- Active agent/toolbox: `funwithfoundry-rag-agent:3` / `foundry-rag:2`;
  instance principal unchanged: `aae32b47-acce-485e-9097-342c428fcd5b`.
- Actual exported skillset (Git-ignored local artifact):
  `.azure/exports/s1-native-20260911-004736/spo-native-skillset.json`, 7818 bytes.
- Export SHA-256: `DDE5F1174849074EF03FC65892C91E7EDED88D3311FA96B1CBB8C2C183C94DC8`.
- Skillset ETag: `"0x8DF0F9D856A4112"`, unchanged on final readback.

The six definition names are `spo-native-datasource`, `spo-native-index`,
`spo-native-skillset`, `spo-native-indexer`, `spo-native` and
`spo-native-knowledge-base`. Azure Search executes the explicit native CU skill
with semantic 500-token/zero-overlap chunks, secondary South Central US `gpt-5.2`, images/location metadata,
3072-dimensional embeddings and child projections. The Function remains staging-only
(`202`); a manually staged blob can also feed the private scheduled indexer. Original
source URL metadata is retained on the blob, while child citations use the staged URL.
Vectors were not retrievable: the 3072-dimensional schema and hybrid toolbox were
verified, **not a direct 3072-element vector-array check**. This does not establish
image/location quality or latency/cost measurements.

### Recovery and unproven scenarios

The initializer's binding receipt requires exact datasource ETag and configuration
to handle redacted credentials. Explicit `-RebindDataSource` renews that binding;
missing/null credentials never become generally acceptable. Readback allows only
the `@odata.context` annotation and empty `indexerPermissionOptions` server defaults;
nonempty permission options remain blocked. Live indexer execution changed the
server datasource ETag and invalidated the receipt. The passing run required an
explicit rebind immediately before Verify in the ignored recovery driver. Repeated
unattended resume needs follow-up; this pass does not certify it or deletion behavior.

The runtime fix normalizes the native Search text footer URL and matching
UrlToken-encoded parent into source JSON before the Responses host flattens the
block. `lc_framework` IDs remain rejected and strict client validation is retained.

Actual SharePoint input was configured as `funwithfoundry-architecture-note.txt`.
HTTP 415 occurred before Graph because only PDF, PNG and JPEG are allowed. Neither
SharePoint consent nor source fetch was proven; do not infer a missing grant from
this rejection. No SharePoint content or permissions changed. The existing
`eval.yaml` was reused as local evaluation intent; no cloud evaluators ran.

Direct private indexers with built-in skills support S1+ on services created after
April 3, 2024; embeddings additionally require a high-capacity region. The current
Central US service was created September 9, 2026. This eligibility context is now
backed by the specific live fixture pass above, not a universal compatibility claim.
See [native prerequisites](native-ingestion.md#identity-network-and-cost-review).

## Historical S2 attempt and recovery

The earlier generated private `azureBlob` knowledge-source approach hit an S2 quota
blocker. That path is not used by the current explicit `searchIndex` design; retain
the failure as historical evidence, not a current S1 prerequisite. Inventory any
surviving definitions and keep the historical Function proof. A legacy `azureBlob`
KS named `spo-native` must not be silently overwritten or deleted. Approved recovery
must resolve exact conflicts; no automatic migration, deletion or fallback is implied.

## Native cloud-free validation proof

**Historical, superseded generated-source revision:** this full release gate passed
before the explicit S1/version-2 implementation. It is not the current full-gate
result. The root Terraform test filter had been fixed for Windows `Join-Path`.
The recorded command was:

```powershell
& D:\Git\funwithfoundry\scripts\Test-Repository.ps1 -Terraform -Release -PythonPath D:\Git\funwithfoundry\.azure\envs\native-locked\Scripts\python.exe -IngestionPythonPath D:\Git\funwithfoundry\.azure\envs\ingest311\Scripts\python.exe -DocumentationPythonPath D:\Git\funwithfoundry\.azure\envs\dependabot-docs\Scripts\python.exe
```

| Check | Historical result |
| --- | --- |
| Python ingestion | 28 passed on Python 3.11.13 |
| Python retrieval / knowledge schema | 24 / 11 passed on Python 3.13.7 |
| Python total | 63 passed, zero skips |
| Operational guards | 5761 checks passed |
| Deployment / native deployment | 332 / 28 checks passed |
| Native ingestion / private links | 431 / 349 checks passed |
| Knowledge-source contract | 98 mutations, 14 invalid cases, 7 valid aliases, 10 unsafe aliases and 7 invalid URL mappings passed |
| Artifact transport | 514 checks passed |
| Root Terraform harness | 2 native tests and 3 auth tests executed and passed |
| Documentation | 10 YAML files, 21 Markdown files, 272 local links and 2 Mermaid checks passed |

Two module tests also passed earlier in a separate subagent run; they are not
claimed as part of this harness execution. Scoped roles were statically reviewed,
not verified through live role propagation. That run was cloud-free integration
proof with no Azure writes or live runs. Its generated-template/tier checks were
never live acceptance, and its totals must not be reused for the S1 revision.
For subsequent live S1 fixture passes, completed local gates, the resolved normal
Verify receipt failure and remaining SharePoint/DAG/deletion limits, see the
current follow-up above. Historical
cloud proof below is unchanged.

## Historical v1 execution

The following custom-ingestion execution completed on 2026-09-10 UTC, following the
September 9 approval. The original acceptance results and correlation values are
preserved. This is private reference POC evidence, not production certification or
native-ingestion acceptance. Subsequent section headings refer to that execution.

## Live Results

| Check | Result | Evidence |
| --- | --- | --- |
| Existing environment teardown | Passed | Both old Foundry accounts purged; all three lab groups absent; Terraform state empty before rebuilding |
| Fresh preflight | Passed | 51 checks, no warnings or failures |
| Fresh infrastructure and scoped runtime roles | Passed | Account/project capability hosts ready; final Terraform plan reports no changes |
| Control-plane verification | Passed | 38 checks; all expected private endpoints approved and routing intents present |
| New jumpbox bootstrap | Passed | Verified azd 1.33.0, uv 0.8.13, PSF-signed Python 3.13.7 and eight pinned extensions |
| Artifact transfer and cleanup | Passed | Four files, 133431295 bytes, verified hashes; zero temporary users, tasks, firewall rules, keys or active transfer lock |
| Function remote build | Passed | Deployment e7467b84-de2b-4aa8-8c69-9011aaabf489 completed; ingest HTTP trigger discovered |
| Function authorization and fixture rerun | Passed | Seven checks: missing/spoofed/invalid identity rejected, source override rejected, fixture and rerun indexed with stable identity |
| Function-to-Search provenance | Passed | Function-indexed document ID, source ID and content hash matched on private Search readback |
| Foundry IQ retrieval | Passed | Expected fixture fact returned; no retrieval activity errors |
| Native end-to-end workflow | Passed | Authorized Function ingestion, provenance, IQ and matched native IQ/Search tool outputs passed together |
| Golden questions | Passed | Launch date, 30-day retention and unknown budget; both required tool outputs validated for each answer |
| Native workflow rerun | Passed | Two readbacks retained agent version 1, toolbox version 1 and the same instance principal; no redeploy |
| Public data-plane refusal | Passed | Foundry, Content Understanding and Search each returned an explicit network-denial 403 |
| Local publication secret scan | Passed | Gitleaks 8.24.2, verified release checksum, 160 publishable files, zero leaks; ignored credentials/state excluded |

The accepted agent is `funwithfoundry-rag-agent:1`, using toolbox `foundry-rag:1`.
Its instance principal, not its blueprint, received only the existing project
Foundry User and Search Index Data Reader assignments. Resolve current endpoints
from Terraform outputs; suffixes change on rebuild.

## Correlation

- Function package SHA-256: `fc51cc84d2c9f9f89ddf1b3ef720a8dd0d4e603664d01d709baeaee37aa90db8`.
- Fixture document/source ID: `49c28093cd800efbac9eb23a4725cec146063ad0ae45ef41a7fd24ee2fb3baa8`.
- Fixture content SHA-256: `cdd043077071dbacc56dbd98e59587df66de084811dc2b231698ba435e57088f`.
- Initial end-to-end request: `bbc85d31-ea04-413b-89ff-fe75904e9c57`.
- Reusable Verify end-to-end request: `15bddb25-47aa-4e82-8926-e9b74f5067ce`.

Operational state, full logs and saved Terraform plans remain outside version
control. They can contain secrets and are not publication artifacts. Local and
live validation are distinct from the hosted publication checks below.

## Publication

Published to GitHub `main` in commit `00ffc1d`, with CI compatibility fixes through
`ef23830`. [Run 34493693637](https://github.com/aionic/funwithfoundry/actions/runs/34493693637)
passed all three jobs: Windows release checks, Linux runtime checks and secret scan.
The fixes resolve runner paths after startup, install Function Python 3.11.13 using
the pinned uv, and create test SSH keys with native key generation so ownership
matches production on hosted Windows. Production ACL enforcement is unchanged.

Authenticated read-only verification returned `Branch not protected` for `main`;
the repository ruleset list was empty. Passing checks are not enforced as merge
requirements. Beads `funwithfoundry-48p` tracks authorization and configuration of
that policy. No repository protection settings or Azure resources were changed
during publication.

## Recovery Boundaries

This was a fresh rebuild with explicit, scoped recovery, not one uninterrupted
entrypoint run. ARM connection resets required readback and new plans for remaining
resources. A concurrent Foundry connection deletion hit an ETag conflict; account
dependency deletes are now serialized. Expired PIM was renewed with approval.

The separate API identifier-URI resource owns that field; the application now
ignores it to avoid removing the URI on rerun. Linux pip 23.0.1 reproduced a
stripped PyJWT crypto-extra hash failure; retaining the extra with unchanged
versions/hashes fixed the reproduction and the remote Function build.

PowerShell 5.1 required explicit JSON array enumeration and separate handling of
informational CLI stderr. Native read-only discovery now has bounded transient
retries; mutations are not automatically retried. The corrected readback and Verify
functions were executed against the accepted deployment. Changed source fingerprints
still require review and checkpoint reconciliation; never erase an unknown attempt
or copy credential caches to force resume.

Transfer cleanup on this Windows image required a reviewed jumpbox restart to
release a loaded temporary profile. File-tail diagnostics also timed out; bounded
direct file reads recovered the saved metadata. Do not infer that a successful
guest deployment command proves a successful current API read.

## Not Run

- Real SharePoint ingestion and site-specific consent: optional, not exercised.
- A separate valid-but-unapproved application's bearer token: not exercised;
  missing, invalid and spoofed identity requests were tested live.
- Deliberately failing a retrieval backend in the live deployment: covered by local
  deterministic graph tests, not by changing the running services.
- Interactive Bastion RDP: not exercised; private SFTP and Run Command were used.
- Cloud-scored evaluation: not run for this rebuild. The three directly executed
  golden questions are not Azure evaluator scores. The optional evaluation seed is
  aligned with Project Cedar and excluded from deployed agent packaging.
- Branch-protection configuration: not changed; the verified absence of enforced
  required checks is tracked separately from the successful hosted workflow.

The rebuilt services remain deployed and continue billing. Only the jumpbox is
deallocated after acceptance; this is not a zero-cost pause.