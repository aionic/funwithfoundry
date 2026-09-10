# Ingestion Integration Contract

The dedicated `azuread_application_identifier_uri` resource owns the API URI.
The application ignores that field to avoid removing it on subsequent plans.
Validate both resources together when changing the API audience.

## Required Parent Wiring

The parent must pass these **mandatory** arguments to `module.ingest_function`:

```hcl
tenant_id = data.azurerm_client_config.current.tenant_id
authorized_caller_principal_ids = {
  jumpbox = module.jumpbox.jumpbox_principal_id
}
```

If forwarding a parent variable, declare it as a nonempty `map(string)`. Keys are
stable caller names (for example, `jumpbox`) that must be known at plan time;
values may be unknown until a managed identity is created during apply. Values are
**service-principal object IDs** of approved calling applications or managed
identities in that tenant, not user IDs, Azure role-assignment IDs, application
registration object IDs, or client IDs. Prefer the private runner's dedicated
managed identity. Do not authorize every identity in the VNet. The inherited
AzureAD provider must use the specified tenant; a precondition rejects mismatch.

Both caller lookups and app-role assignments use this input map for `for_each`;
assignments reference `data.azuread_service_principal.caller[each.key]`. This keeps
instance addresses known on a fresh plan even when principal IDs are unknown.
Do not convert the principal values to a set or use the derived
`local.authorized_callers` map as `for_each`: its client-ID keys resolve only
after the caller lookups. That derived client-ID-to-principal-ID map is used only
in resource body settings and outputs, which may remain unknown until apply.

The module resolves each caller's client ID, creates a single-tenant Entra API
application and service principal, and assigns its `Ingestion.Invoke` application
role to precisely these callers. The Terraform operator needs Entra authority to
create the API application/service principal, read nominated caller principals,
and grant application roles. Azure subscription RBAC alone is insufficient.
No API client secret, delegated scope, or SharePoint tenant-wide consent is created.

Easy Auth uses the verified AzureRM `auth_settings_v2` schema, enabled with
`require_authentication`, `Return401`, HTTPS, tenant-specific issuer, API audience,
`allowed_applications` (client IDs), and `allowed_identities` (principal IDs).
There are no anonymous exclusions or token-store/login secrets. The Function's
`ANONYMOUS` binding means **no Function key**, not anonymous application access:
the handler independently verifies the bearer signature and claims. It never
uses `X-MS-CLIENT-*` headers as authentication. This also fails closed if code is
published before Easy Auth is configured.

## Caller Token Contract

Re-export these module outputs in the parent as needed:

| Output | Meaning |
| --- | --- |
| `ingestion_api_client_id` | Dedicated API client ID; exact v2 JWT `aud` |
| `ingestion_api_resource` | `api://<API-client-id>`; managed identity resource |
| `ingestion_api_scope` | `api://<API-client-id>/.default`; client-credentials scope |
| `ingestion_api_principal_id` | Resource service-principal object ID |
| `ingestion_invoke_role_id` | UUID of the `Ingestion.Invoke` application role |
| `ingestion_authorized_callers` | Caller client ID -> caller principal ID mapping |

Client credentials: request a token from
`https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token` with
`grant_type=client_credentials` and the API scope above. Use an existing approved
caller credential (prefer a certificate/federated identity); do not put secrets
in scripts, command lines, logs, or Terraform inputs. Managed identities request
the API resource through their managed identity endpoint. A fresh token must
contain the assigned role; allow for Entra/managed identity role propagation.

Send `Authorization: Bearer <access-token>`. Validation requires RS256, an Entra
signing key from that tenant's fixed JWKS URL, issuer
`https://login.microsoftonline.com/<tenant-id>/v2.0`, the dedicated GUID audience,
`tid`, `ver=2.0`, `idtyp=app`, `sub`, `exp`, `nbf`, `iat`, no `scp`,
`roles` containing `Ingestion.Invoke`, and the configured `azp` -> `oid` pair.
The API application requests v2 access tokens and the optional `idtyp` claim.
Signing keys refresh hourly and on unknown key IDs, with a five-second fetch
timeout; signing keys are not cached indefinitely. The runtime needs HTTPS
egress to `login.microsoftonline.com` for JWKS, in addition to managed identity
and service traffic. A personal `az login` token is not an approved app-only token.

## Request And Data Contract

POST `/api/ingest`, `Content-Type: application/json`, at most 4096 request bytes:

```json
{"mode":"fixture","fixtureId":"accelerator-v1"}
```

or, after separate site-scoped SharePoint consent:

```json
{"mode":"sharepoint"}
```

All extra keys, query parameters, duplicate JSON keys, unknown fixture IDs,
source overrides, supplied bytes, and URLs are rejected. Only the built-in fixed
synthetic PDF is accepted in fixture mode. Both modes execute staging upload,
CU `analyzeBinary`, nonempty extraction, and the private cross-region Search push.
The fixture states: fictional Project Cedar, owner Morgan Example, launch
15 October 2026, document retention 30 days. It makes no live customer claims.

`enable_synthetic_fixture` defaults to true in this module; it never bypasses
authentication. The runtime defaults to disabled when its setting is absent.
`max_document_bytes` defaults to 5 MiB and cannot exceed 10 MiB. The supported
source types are PDF, PNG, and JPEG, checked by extension, MIME, and signature.
SharePoint accepts only the configured hostname/site/default-drive file; Graph
access must use `Sites.Selected` plus a read grant to that site. This module does
not grant Graph permissions. Downloads are streamed with a byte limit; Graph
download redirects must stay on the configured SharePoint hostname and are
followed without forwarding the Graph bearer. No arbitrary external redirect
or CU operation host is followed. Hosts requiring other download domains need
explicit review, not a permissive suffix wildcard.

**Parent Search schema prerequisite:** add these string fields to the single
canonical index writer outside this slice before invoking ingestion:

| Field | Value |
| --- | --- |
| `id` | SHA256 of canonical source kind/hostname/site path/file path; Search key |
| `title` | Configured file name or built-in fixture title |
| `content` | Nonempty CU markdown, bounded to 2 MiB UTF-8 |
| `source_url` | Graph item's canonical web URL, or fixture URN |
| `source_id` | Same canonical source identity hash as `id` |
| `content_hash` | SHA256 of original input bytes |

Retain existing searchable title/content and semantic configuration. Provenance
fields must be retrievable; `source_id` and `content_hash` should be filterable.
Do not silently omit provenance for an old index. The existing external index
writer does not yet declare all three provenance fields, so live ingestion is
blocked until the parent aligns it. Changed source bytes update the same Search
document; different sites/paths or historically colliding filenames do not collide.
Staging uses immutable `<source_id>/<content_hash>.<extension>` names and metadata.
Only exact `ContainerAlreadyExists` and `BlobAlreadyExists` conflicts are accepted.
Staging generations are retained; lifecycle/retention policy remains an operator task.

REST and staging operations have at most three attempts, only retrying transient
statuses (429, 500, 502, 503, 504), with `Retry-After` seconds/date honored up to
10 seconds. Terminal 4xx fail immediately. SDK retries are disabled to prevent
multiplicative retry counts. Ambiguous POST transport failures are not retried.
CU polling is limited to 40 polls and a 180-second polling budget (an in-flight
HTTP attempt can exceed this budget). This remains a synchronous small-file POC;
slow work can exceed the platform HTTP response limit and is not a durable queue.
Search HTTP success/207 alone is insufficient: every returned item must match
the expected key and report boolean success with status 200 or 201.

Responses use valid JSON and a generated `request_id`, also in `X-Request-ID`.
Success returns IDs/hashes/counts, not document contents. Failures return a stable
code and stage; logs contain only correlation, stage, outcome, duration, and
exception type. Easy Auth can reject before the handler and has its own response
format; handler correlation is not promised for a platform-level rejection.

## Local Verification

From the repository root, configure the existing isolated venv before Python use:

```powershell
uv pip install --python .\.venv\Scripts\python.exe -r .\src\ingest_func\requirements.txt
& .\.venv\Scripts\python.exe -B -m unittest discover -s tests -p test_ingestion.py -v
terraform -chdir=terraform/modules/ingest-function init -backend=false
terraform -chdir=terraform/modules/ingest-function validate
terraform -chdir=terraform/modules/ingest-function test
terraform -chdir=terraform validate -no-color
```

The unit tests mock the Function HTTP binding and all service transports, and
exercise real JWT signing/verification and ingestion helpers. No cloud calls.
Native Terraform tests mock **every** provider and run plans only, checking named
caller instance keys, resolved client/principal pairs, the v2 application role and
`idtyp` claim request, empty-map rejection, and provider-tenant mismatch. The caller
IDs in these mocks are known fixtures; fresh-plan unknown-value compatibility is
a configuration review, not a live deployment test. Never substitute
an ordinary `terraform plan`/`apply` against the existing lab for these tests.
Standalone module initialization creates an ignored local dependency lockfile;
the existing parent Terraform lockfile remains the deployment dependency lock.
Schema validation was performed with AzureRM 4.81.0 and AzureAD 3.9.0; those are
the module minimums. Python syntax targets 3.11; local tests use native 3.13.
Direct dependencies are pinned; the local Function SDK import check requires its
Werkzeug/MarkupSafe transitive dependencies to be available as well.

Local evidence (2026-09-09): 24 unittest cases passed on the existing Python
3.13.7 venv, all four Python files passed 3.11 syntax parsing, module validation
and all three mocked Terraform plans passed, and the runner passed seven checks
against six mocked HTTP calls. PowerShell parsing and `-WhatIf` also passed.
Full Function SDK import remains unverified locally: official wheel downloads
for its missing Werkzeug/MarkupSafe dependencies failed TLS handshakes, including
with the system trust store. Certificate validation was never disabled. Tests
explicitly mock the HTTP binding; they do not claim a running Functions worker.
All dependency installation used uv in the existing venv, never global Python.

## Private Runner Check

After root wiring, index alignment, deployment, and explicit approval, run the new
`scripts/jumpbox/Test-Ingestion.ps1` **inside the VNet**. Supply `FunctionHostname`
and `ApiClientId` from outputs. By default it obtains an IMDS token from the VM;
pass `ManagedIdentityClientId` to select an approved user-assigned identity.
Alternatively pass an already-acquired token as a `SecureString` in `AccessToken`.
Use `-WhatIf` for a no-network preview. The live check writes the fixed fixture
twice through the Function and verifies stable identity, plus unauthorized and
input-rejection probes. `-IncludeSharePoint` requires separate site consent.
`DeniedAccessToken` optionally tests a real unapproved caller's token for 403.
The script emits sanitized machine-readable checks and exits nonzero on failure.
It never labels generic 403 as proof of public-network isolation and does not
claim IQ/native-agent retrieval, which must be composed by the parent workflow.

No cloud deployment, consent grant, live Function ingestion, or retrieval test
is performed by the local verification commands above.
