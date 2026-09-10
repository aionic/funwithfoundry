# Security Policy

## Reporting

Use GitHub private vulnerability reporting, if enabled, rather than a public issue.
Include a minimal reproduction, affected component/version and sanitized failure
metadata. Never include bearer tokens, credentials, Terraform state/plans, private
tenant/subscription IDs, private hostnames or document contents. Do not claim a
private reporting channel is enabled without checking the repository settings.

The POC tracks the default branch only; security fixes are not promised for earlier
revisions. [docs/compatibility.md](docs/compatibility.md) records declared versions,
not a certification. No penetration test or new live security validation is claimed
by this Phase 5 documentation pass.

## Identity boundaries

Foundry, AI Search, Storage and Cosmos are configured without local/shared-key
data-plane authentication. Use Entra tokens and scoped workload identities, not
connection strings or API-key fallbacks. Network access and authentication do not
replace authorization.

The [ingestion API module](terraform/modules/ingest-function/auth.tf) creates a
single-tenant API registration/service principal with `Ingestion.Invoke` and assigns
that application role to the configured jumpbox managed identity. The Function
validates token claims and the allowed caller mapping; an arbitrary VNet caller or
`X-MS-CLIENT-*` header must not authorize ingestion. The Function's downstream identity
is separate from its API audience and caller identity. Inputs restrict modes, request
size and configured source paths. The synthetic fixture is a constrained demo mode,
not an unauthenticated upload endpoint.

ARM PIM does not grant tenant application-management, app-role-assignment or SharePoint
consent authority. Use a reviewed bootstrap identity for those operations; do not
grant persistent tenant-wide permissions to a deployment runner. Site-scoped optional
SharePoint requires both Function `Sites.Selected` and a `read` grant to one approved
site. Never fall back to `Sites.Read.All`. A consenting administrator's stronger
Graph permissions must not be assigned to the Function.

## Network and data limits

- Foundry PaaS is outside the VNet; private endpoints are inside PE subnets and agent
  outbound compute is injected into its dedicated subnet. Public access must stay disabled.
- Graph/SharePoint, identity, build feeds and selected telemetry are public egress.
  There is no claim that every platform path is private or protected by AMPLS.
- The current broad firewall wildcards and spoke-to-spoke ports are POC allowances,
  **not zero-trust or comprehensive exfiltration prevention**. Production use needs
  an explicit egress/identity review; no TLS-inspection coverage is claimed.
- GlobalStandard processing is not pinned to the two resource regions. Obtain data
  classification and residency approval before using real documents.
- The shared Search index does not implement per-user SharePoint ACL trimming. A
  site-scoped ingestion grant is not end-user document authorization. Use only a
  uniformly authorized POC corpus until document-level authorization is designed.
- Retrieved text is untrusted data. Deterministic allowlisted retrieval and tool-free
  synthesis reduce action risk but do not prove immunity to prompt injection, leakage
  or unsupported answers. Preserve source IDs and test unknown/failure behavior.

## State and secrets

Local Terraform state includes the generated jumpbox administrator password even
when the output is marked sensitive. Encrypt and restrict state, plans, backups,
azd state and diagnostics; do not print passwords during routine setup. Ignore rules
do not encrypt files or remove already-tracked content. Secret-scan the proposed
release, and rotate/revoke exposed credentials before repository-history remediation.

Use short-lived tokens in memory. Never transfer login caches or bearer tokens via
Run Command, logs, pull requests or chat. Use uv environments outside deployment
package source directories. For teams, review the optional Entra Blob backend with
native state locking in [docs/deployment.md](docs/deployment.md#state-and-configuration).

## Automation and destructive actions

PR checks must have no Azure credentials. Never execute untrusted fork code on the
private runner or with privileged `pull_request_target` workflows. Pin actions to
reviewed commit SHAs, restrict OIDC issuer/subject/audience, separate plan/apply
permissions, require environment approvals and protect the runner as a privileged
execution surface. Repository configuration does not itself enable GitHub branch or
environment protection settings. See [docs/automation.md](docs/automation.md).

Require exact-resource review and human confirmation before teardown, purge, consent
or deployment. Follow [docs/operations.md](docs/operations.md#ordered-teardown), keep
the repository and state backup, and stop on unknown outcomes. Public HTTP 200 must
fail isolation checks; generic auth 403 must not be presented as network-denial proof.
