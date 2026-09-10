# Rebuild Validation

Execution completed on 2026-09-10 UTC, following the September 9 approval.
This is a private reference POC acceptance record, not production certification.
No historical deployment result is counted as a current pass.

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