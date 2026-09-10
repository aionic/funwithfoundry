# Operations

## Evidence vocabulary

Use `historical`, `source-verified`, `locally-validated`, `live-verified`, `blocked`
and `not_tested` precisely. Source inspection describes intended behavior; it is not
runtime proof. Dated evidence and remaining gates are in
[VALIDATION.md](VALIDATION.md) and [STATUS.md](STATUS.md), with
architectural context in [architecture.md](architecture.md#evidence-status).

The recorded rebuild passed private bootstrap, Function ingestion and native
runtime acceptance. Dated results, recovery steps and hosted CI evidence live in
[STATUS.md](STATUS.md) and [VALIDATION.md](VALIDATION.md). Those results describe
that deployment, not readiness of another checkout or environment.

Recheck time-bound ARM PIM and tenant authority before each long execution window;
subscription preflight alone proves neither. Keep historical deployment results
in the [status record](STATUS.md), separate from a new release's evidence. Use
[TESTING.md](TESTING.md) for local validation and live-acceptance boundaries.

## Troubleshooting

| Symptom | Discriminating check | Safe response |
| --- | --- | --- |
| ARM works but private API times out | Resolve public service FQDN inside the private runner; check PE approval and TCP 443 | Repair DNS, routes or runner placement, not public access |
| HTTP 401/403 from ingestion | Check API audience, tenant, token expiry, application role and allowed caller identity without logging the token | Correct the intended assignment; network reachability is not authorization |
| Public check sees HTTP 200 | Inspect exact endpoint and authenticated path | Fail release; do not relabel it a successful probe |
| Public check sees generic auth 403 | Separate authorization denial from explicit network-policy rejection | Record inconclusive until network refusal is proven |
| Same-region call works, cross-region call fails | Inspect both routing intents and the private-to-private network rule before application rules | Preserve private addressing; do not broaden public access |
| IQ planner 403 | Check Search MI role, approved `openai_account` shared private link and `.openai.azure.com` model URI | Correct the model endpoint or scoped permission; IQ calls a model, not the hosted agent |
| IQ returns bare 400 | Check API-specific request schema, especially unsupported `alwaysQuery` | Capture sanitized status/request ID; inspect a controlled diagnostic response, never tokens |
| Agent startup or toolbox failure | Check actual deployed principal, required tool name, current toolbox version, endpoint and schema | Compare expected simple text query and fail closed on either retrieval branch |
| Function package accepted but no usable trigger | Check active deployment/build result, trigger sync and authorized fixture invocation | `Accepted` or successful ARM Run Command alone is not healthy code |
| Installer/azd command missing on jumpbox | Check process identity, PATH, exact versions and approved egress | Complete reviewed bootstrap; no copied login cache or blanket firewall opening |
| Python 3.13.7 bootstrap fails | Check the fourth artifact's hash/signature, installer status and explicit interpreter path | Use the verified offline installer; do not enable arbitrary release-host egress |
| Artifact transfer succeeds but cleanup is unknown | Inspect exact transfer ID, owned tasks/listener and protected recovery state through approved ARM access | Treat the stage as failed; retain the lock and reconcile owned cleanup before retrying |
| Account host fails with a long subnet name | Extract last nonempty subnet ARM-ID segment, including a trailing slash | Enforce the repo's 62-character workaround; 63 must fail locally |
| Terraform apply/delete returns authorization error | Check active subscription and PIM expiry, separately from tenant app authority | Renew approved permissions before resuming; do not reinterpret as a transient service error |
| Foundry connection deletion returns ETag conflict | Read back remaining connections after the failed plan | Serialize account dependency deletion and review a new plan for remaining resources |
| Account deletion returns nonterminal-state conflict | Read the account provisioning state | If already Deleting, wait for absence before exact-name purge; do not replay the delete blindly |
| Evaluation service fails | Separate evaluator service status from ingestion/retrieval outcomes | Record request ID and blocked evaluation; do not invent scores or waive gates |

The broad spoke-to-spoke ports and wildcard egress policy are POC allowances, not a
zero-trust design. A historical firewall application-rule proxy path re-originated
private requests publicly; the network rule addresses that case. This does not mean
Azure Firewall universally breaks private endpoints. See the exact rule source in
[vwan-secured/main.tf](../terraform/modules/vwan-secured/main.tf).

## Rollback

1. Stop deployment progression and preserve sanitized stage evidence, state and package hashes.
2. Read back deployment, role and toolbox state. Do not retry unknown creates blindly.
3. Select the last reviewed agent package/version and compatible toolbox version;
   compare schema and endpoint binding before an approved republish/redeploy.
4. Run a full Terraform plan against the retained state before accepting infrastructure
   changes. Restoring an old state file is not a rollback of real Azure resources.
5. Revalidate authorized ingestion, dual retrieval and denial checks before resuming.

No automatic rollback or restore time is certified. Source/index schema migrations
can be destructive; preserve source provenance and choose a reviewed rebuild or
versioned-index migration rather than silently modifying live data. Staging and
Search deletion do not necessarily delete agent state or diagnostic copies.

## Ordered teardown

**Destructive and approval-gated. Preserve the existing lab until the user approves
the exact teardown targets.** Deployment, release or prior rehearsal approval alone
does not authorize deletion. A subsequent rebuild requires its own approved scope;
it is not an automatic consequence of teardown. Keep the repository and unrelated
resources. Never delete by a broad name prefix or purge all soft-deleted accounts
in a subscription.

1. Resolve the exact subscription, all managed resource-group IDs, account IDs/locations
   and project capability-host ID from the existing Terraform state/outputs. Check
   the active subscription matches. Back up state and inputs on encrypted restricted
   storage outside Git. Inventory any unexpected resources and stop on scope mismatch.
2. Show those exact IDs to the operator and obtain explicit destruction approval.
   The script's `DESTROY` prompt supplements this review; it is not a substitute
   for inspecting the full scope and AzureAD objects managed by Terraform.
3. Delete the project capability host first. The account capability host is a
   platform-renamed singleton, not a separately addressable Terraform destroy target.
4. Delete the exact approved Foundry accounts. Wait with a deadline for deletion to settle.
   Historical cleanup took roughly 15-20 minutes to release injected networking;
   timing is not a service guarantee.
5. Match each soft-deleted account by its exact deleted-resource ID, subscription,
   location, group and name, then purge it. Verify absence after purge. `azapi`
   resources are not covered by azurerm's cognitive-account purge behavior.
6. Only after successful purges remove the remaining network/resources with Terraform.
   Verify the exact groups have no remaining lab resources and inspect soft-deleted
   dependencies according to retention policy. Never bypass a service association link.
7. Keep state and evidence through reconciliation. Stop on failed deletion, timeout,
   purge or unexpected residuals; do not continue to VNet destruction on a failed gate.

The reviewed command shape is:

```powershell
pwsh -NoProfile -File .\scripts\Stop-Lab.ps1 -Mode Teardown
```

[Stop-Lab.ps1](../scripts/Stop-Lab.ps1) implements the ordered workflow and scoped
checks. See [VALIDATION.md](VALIDATION.md#recovery-boundaries) for dated recovery
evidence; a previous teardown does not prove an uninterrupted run in another environment.
The public parameters are `-Mode` (`Pause` or `Teardown`), `-TerraformDir` and
`-TimeoutMinutes` (default 30). It has no subscription-selection parameter; verify
the active subscription against the retained state before the confirmation prompt.
Never add `-auto-approve`, force-unlock or state removal as a convenience workaround.
If an account is already deleted or absent from state, reconcile its exact identities
before restarting rather than treating a timeout as authorization for broader cleanup.

SharePoint site grants made outside Terraform need explicit cleanup/reconciliation
with the site administrator. Likewise verify the API application, service principal
and role assignments are removed by the AzureAD provider; ARM resource-group deletion
alone is not tenant-object cleanup. Retention/soft-delete policies may retain data
or names even after resource-group removal.

After teardown, archive the old accelerator stage evidence securely. If a rebuild
is separately approved, start its `Preflight` and `Infrastructure` without `-Resume`;
a missing or changed account identity cannot safely reuse the previous lab's
completion records. Follow [deployment.md](deployment.md#short-path) for subsequent
stages and verification.

## Cost modes

| Mode | Effect | Continuing charges and limitations |
| --- | --- | --- |
| Active demo | VM and all services available | Two firewalls, vWAN hubs, Bastion, Search, Cosmos, storage, model tokens, Function/build usage and data transfer |
| Pause | `Stop-Lab -Mode Pause` requests jumpbox deallocation only | Firewalls, hubs, Bastion and Search still bill; VM disks/storage and other service charges remain |
| Teardown | Approved ordered removal and purge | Irreversible data/service loss; inspect residuals and retained backups before claiming spend has stopped |

VM deallocation is not firewall shutdown or a zero-cost pause. No supported firewalls-only
pause/resume workflow is promised here. Obtain a dated Azure pricing estimate and
budget alerts for actual SKUs/region/usage; do not reuse an old monthly dollar figure.
Choose the post-acceptance cost mode with the operator. A previous teardown or
rebuild approval does not authorize another deletion.

## Observability and capacity

Capture request ID, source/document ID where appropriate, package/version digest,
stage, tool name, elapsed time and outcome. Avoid raw document bodies, bearer tokens,
full upstream error responses and unredacted Terraform/Graph output. Restrict access
and retention for diagnostic exports. Application telemetry does not automatically
enable every Azure Firewall, Search or Foundry diagnostic category.

Before rehearsal, check regional model/SKU availability, subscription token quota,
VM capacity, public IP quota, Search limits, delegated subnet capacity, PIM duration
and policy. These are live gates, not facts established by Terraform validation.
The agent subnet uses a dedicated /24 in source; never manually clear its service
association link or reuse a partially torn-down injection configuration.

There is no tested SLO, RTO, RPO, cross-region failover, load envelope or automatic
recovery. Ingestion is synchronous with bounded calls/polling, not a durable queue;
partial staging/indexing results need explicit rerun and reconciliation. Keep
dependency/API/model updates reviewed as described in [automation.md](automation.md).

## Appendix: Transport recovery

The reviewed manifest contains azd 1.33.0, uv 0.8.13 and the signed Python 3.13.7
installer, plus eight extensions in one bundle. Those four verified artifacts use
the implemented Bastion private-tunnel flow described in
[deployment.md](deployment.md#verified-bulk-artifact-transfer). Local guard counts
are not live scenario counts. See [VALIDATION.md](VALIDATION.md) for dated transfer,
cleanup and fresh-VM installation results. Successful delivery does not by itself
prove installation or workload readiness on another image.

On an interrupted transfer, use the exact transfer ID's protected recovery state
and owned cleanup script through approved Run Command. Do not delete the active
lock, change shared SSH configuration, leave temporary access open or disable host-key
verification to retry. An expiry task is a fallback, not proof of cleanup. Retain
verified artifacts, remove only the transfer-owned access, and record the result.
A loaded temporary-user profile can require an explicitly approved jumpbox restart
before cleanup finishes. Never force-unload it. If action Run Command disconnects,
use a uniquely named managed Run Command and inspect its durable instance view;
an identical update can be a no-op returning an earlier result.
