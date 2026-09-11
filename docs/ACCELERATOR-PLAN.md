# Secure Multi-Region Foundry Accelerator Publication Plan

**Historical custom-ingestion plan, 2026-09-09 to 2026-09-10.** The scope and
results below apply to that revision. See [STATUS.md](STATUS.md) for the current
fixture-backed native S1 baseline and [deployment.md](deployment.md) for current
procedures.

Approved scope: phases 1-6, with minimal automated tests, followed by the live phase-6 rehearsal.
Planning baseline: commit `3e0a504` on `main`, 2026-09-09, before these implementation changes.
Beads is the execution tracker; this document
records scope, sequencing, decisions, acceptance criteria, and evidence requirements.

## Historical Readiness: 2026-09-10

**Core rebuild and live acceptance passed, 2026-09-10 UTC.** The old environment was
removed in the approved order, both Foundry accounts purged, and the lab fully rebuilt.
Both capability hosts, all expected private endpoints, the Function, native agent version 1
and toolbox version 1 are deployed. Final Terraform plan: no changes.

The [validation report](VALIDATION.md) records 38 control-plane checks, seven live ingestion
checks, Function-to-Search provenance, IQ retrieval, native end-to-end acceptance, three
golden questions, same-version reruns and three public network denials. Temporary access
cleanup was verified. It also records recovery steps and explicitly untested scenarios.

Both human-approved 3840 x 2160 Azure-icon PNGs are rendered and inspected. Four verified
bootstrap artifacts, including signed Python 3.13.7, were transferred and installed on the
fresh private runner. Local tests include actual PowerShell 5.1 and 7, isolated Python
3.11/3.13 environments, Terraform auth mocks and documentation checks. Test assertion
counts are not live scenario counts.

Real SharePoint, interactive RDP and cloud-scored evaluation remain optional/not run.
Publication, hosted GitHub checks and repository protection settings require separate
verification; local and deployed acceptance do not imply those checks ran.

## Product Contract

Publish a reproducible secure reference POC, not a production-ready or active-active platform.
Retain Terraform, native Python hosted agents, Responses, Foundry IQ, the versioned Search toolbox,
Content Understanding, Flex Consumption, and two secured vWAN hubs. Do not add APIM, AKS, or
regional replication without a workload requirement.

- Central US: agent runtime, models, Search, agent dependencies, operator entry point.
- South Central US: ingestion Function, staging storage, Content Understanding.
- SharePoint/Graph is public egress; subsequent data-plane calls use private endpoints.
- GlobalStandard inference is not restricted to these regions. Document processing geography.
- The default deterministic synthetic example must traverse the actual ingestion Function.
- SharePoint is a separate, site-scoped optional scenario; no automatic tenant-wide consent.
- A complete application answer requires successful IQ and toolbox results, not just a prompt.
- Deployment, validation, cleanup, and negative checks must report machine-readable failures.
- Resolved dependencies are hash-locked; required previews are explicit and tested runtimes are
   recorded. Adopting newer packages, APIs or models requires verification.

## Implementation Sequence

### Phase 1 - Correctness And Safety

1. Remove Sites.Read.All fallback; stop with actionable consent guidance on site-grant failure.
2. Scope teardown to exact Terraform-resolved subscription/account/resource-group identities.
   Stop on failed deletes, timeout, or purge; retain the explicit destruction confirmation.
3. Repair first-toolbox null indexing and check every external command exit code.
4. Replace environment-specific project/tool identifiers with configuration/discovery.
5. Authorize Function requests with Entra identity, not merely private network reachability.
   Validate request shape/size and restrict SharePoint sources to configured paths.
6. Produce valid JSON, collision-resistant document IDs, bounded retries, nonempty extraction,
   and per-document Search indexing checks; retain content provenance.
7. Make dual retrieval a deterministic runtime workflow with failure propagation and citations.
8. Make deployment/public-network/jumpbox checks fail closed; distinguish unauthorized, network
   denied, inconclusive, and successful responses. Keep logs free of credentials.

Acceptance: focused negative checks reproduce and prevent the identified faults. No role or
network exposure is widened to bypass platform failures. No unrelated diagnostics are modified.

### Phase 2 - Reproducible Deployment

1. Establish one configuration source (Terraform inputs/outputs plus azd environment state).
2. Supply a resumable orchestration entrypoint for preflight, infrastructure, account host,
   complete graph, private-runner setup, Function package, Search/IQ, toolbox, agent, runtime RBAC,
   and verification. Preserve the platform-required account/project capability-host ordering.
3. Separate workstation and private-runner responsibilities. Prefer Azure VM Run Command without
   temporary WinRM listeners. Use checked Run Command for small source transfer and the reviewed
   Bastion private tunnel for the three tool artifacts; preserve scoped temporary SSH cleanup.
   Install tools through verified distribution channels and prove Python discovery for SYSTEM.
4. Use a single text/semantic index and IQ definition; avoid incompatible schema writers.
5. Wait for real readiness with deadlines. Distinguish accepted deployment from healthy code.
6. Compare desired toolbox contents before publishing; report the selected immutable version.
7. Preserve state securely; document local-state limits and an optional Entra remote-backend path.
8. Produce durable stage results without persisting tokens; reruns must not create duplicate roles
   or reset shared state. Unknown cloud outcomes require read-back, not blind create retries.

Acceptance: a clean checkout is sufficient; no personal PIM script, terminal history, hardcoded
resource suffix, copied login cache, or manual source edit is required.

### Phase 3 - Complete Demonstration

1. Add a constrained synthetic fixture mode to the authorized ingestion Function using the same
   staging, analyzeBinary, extraction, indexing, and provenance path as SharePoint.
2. Create an in-VNet test invoking the Function, then IQ and native-agent retrieval.
3. Verify the actual SCUS Function to CUS Search path; do not label a CUS-jumpbox Search write as
   that proof. Tag source identity/document ID and correlate ingestion/retrieval evidence.
4. Provide the optional Sites.Selected consent and real SharePoint invocation procedure.
5. Exercise unknown-answer and failed-tool behavior; keep the three golden questions small.

Acceptance: fixture ingestion through the Function and both native retrieval branches succeed.
SharePoint is marked tested only after a real site-scoped run; missing tenant consent is a blocker
for that scenario, not permission to claim it passed.

### Phase 4 - Minimal Tests And Operations

Keep automated tests small and cloud-free by default. Prefer Python standard-library unittest
and a PowerShell mock smoke script over a large framework or a broad version matrix.

Required regression coverage:

- First deployment with no toolbox, and re-run with a correct toolbox.
- Public HTTP 200 is a failure; generic auth 403 is not network-isolation proof.
- Delegated subnet names: 62 accepted, 63 rejected, including ARM-ID trailing slash.
- Ingest authorization/input validation, stable noncolliding IDs, and valid JSON.
- Search per-document failure and either retrieval-tool failure cannot yield success.
- Artifact transfer scope, hashes, host-key pinning, temporary access and failure cleanup;
   keep its 223 assertions scoped to this privileged surface, not a new generic suite.

Static checks: Terraform fmt/validate, PowerShell parsing, Python syntax/lint, YAML/Markdown/link
checks, secrets scanning, and deterministic diagram syntax/render checks. Add only focused tests
needed for the changed behavior. Minimal telemetry uses request IDs, durations, outcomes, and tool
names; never raw bearer tokens, document contents, or unredacted debug bodies by default.

Use reviewed dependency-update PRs and a dated compatibility table. Local hooks run quick checks;
protected-branch GitHub checks enforce the same commands. PR checks have no Azure credentials.
Cloud deployment/integration is manual/approved and narrowly scoped. The implemented CLI path
uses the private runner's managed identity; a future GitHub deployment workflow must use OIDC.
Untrusted fork code must never execute on that private runner. Pin action versions by SHA,
document required branch/environment protections, and do not schedule expensive automatic applies.

Acceptance: one documented local check command and one required PR workflow pass; guardrail tests
are minimal, fast, and deterministic. Cloud evaluation service failures remain distinct from
functional evaluation results.

### Phase 5 - Documentation And Diagrams

Deliver:

- README: audience, outcome, overview PNG, quick-start links, scope, support, cost, tested versions.
- Deployment guide: prerequisites, identity/consent, ordered steps, expected outputs, resume and
  cleanup. A short default path plus optional SharePoint scenario.
- Architecture guide: components, physical/logical boundaries, DNS, routing, RBAC identity matrix,
  runtime/control-plane separation, provenance/state, threat model, WAF decisions, reliability,
  cost, observability, residency, and known limitations.
- Automation guide: why local git hooks, deployment lifecycle stages, required GitHub checks,
  OIDC, private-runner trust, approvals, maintenance PRs, and release evidence exist.
- Operations/compatibility guide: troubleshooting, teardown ordering, state protection, capacity,
  model/API lifecycle and the 62-character subnet-name workaround.
- Two modern landscape PNGs using official Azure icons: secure regional topology and numbered
  document-to-grounded-answer flow. Keep editable sources and deterministic render commands.

Diagram gate: **complete for the current exact contracts and PNGs**. For any future semantic
change, validate and preview the Mermaid contracts, then obtain fresh explicit human approval
before final Azure-native PNG rendering. Rendering may change
layout but not architecture meaning. Generated artifacts must be inspected for legibility and
semantic fidelity. Never depict a PaaS service inside a subnet merely because it has a PE.

Acceptance: no contradictory claims, personal environment assumptions, or misleading HA/privacy
claims. Clearly label what is tested, optional, platform-blocked, or outside POC scope.

### Phase 6 - Execute Release Rehearsal

Run after the refreshed release gate and remaining Azure prerequisites. Diagram approval and
final-image QA are already complete. User clarified on 2026-09-09: **tear down the existing fwf
lab and fully redeploy**, then retain the rebuilt lab, instead of duplicating it.
**Preserve the existing lab only until the user approves the exact teardown scope.**
Resolve exact current accounts/resource groups from existing state,
back up state securely outside version control, show the destruction scope and use the teardown
confirmation gate. Preserve the repository and unrelated resources.

1. Confirm active Azure identity/subscription, PIM, separate Entra tenant authority, private
   bootstrap, reviewed read-only cloud plan, regional/model quotas and policy.
2. Tear down the exact existing lab with capability-host -> accounts -> purge -> network ordering,
   verify cleanup, then deploy from the documented fresh-checkout workflow in that lab scope.
3. Run the workflow again; verify no unintended infrastructure, role, or toolbox duplication.
4. Invoke authorized synthetic Function ingestion, native IQ+toolbox retrieval, unknown answer,
   failed-tool/invalid input, unauthorized caller, public-denial, and actual cross-region checks.
5. Run real SharePoint only with explicit site-scoped consent; record blocked versus passed.
6. Capture metadata, source commit/package hashes, tool outcomes, timing, and resource verification.
   Run minimal functional checks; report hosted cloud evaluation separately if its service fails.
7. Verify the initial teardown left no in-scope residual resources and the rebuilt environment
   has no temporary remote access. Leave the rebuilt lab deployed; deallocate only its jumpbox
   after acceptance unless the user requests a second teardown.
8. Review sanitized evidence, limitations, docs and images. Commit/release publication only when
   applicable gates pass; never mark partially blocked work complete or silently waive a gate.

## Change And Execution Rules

- Track six phase issues under one Beads epic; update as evidence arrives, not all at the end.
- Preserve the untracked scripts/Export-FoundryDiagnostics.ps1 unless separately approved.
- Existing deployment remains available until exact teardown approval; after the approved
   teardown/rebuild, leave the rebuilt lab deployed. Use mocks before destructive workflow checks.
- No automatic weakening of public access, local authentication, consent, TLS, or CI protection.
- No guessed CLI flags or fabricated service status. Capture request IDs for platform failures.
- Documentation may be drafted while tests run, but verification claims require saved evidence.
- If a live prerequisite blocks progress, complete independent work, record the exact blocker and
  required operator action, and leave the affected phase open.

## Definition Of Done

Phases 1-5 implemented and reviewed; minimal checks passing; approved diagrams rendered and
visually inspected; exact-scope Phase 6 initial teardown, rebuild, rerun, demo and denial checks
completed; rebuilt lab left deployed with temporary access removed; optional SharePoint status
explicit; evidence sanitized; Beads and docs reflect actual results; release
scope reviewed for secrets, unrelated files, and unintended infrastructure changes.
