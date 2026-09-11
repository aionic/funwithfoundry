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
synthetic PDF is accepted in fixture mode. The staging-only runtime contract is
to upload the document to private Blob storage and return HTTP 202. A 202 response
means staging was accepted, not that indexing or retrieval has completed.
The fixture states: fictional Project Cedar, owner Morgan Example, launch
15 October 2026, document retention 30 days. It makes no live customer claims.

`enable_synthetic_fixture` defaults to true in this module; it never bypasses
authentication. The runtime defaults to disabled when its setting is absent.
`max_document_bytes` defaults to 5 MiB and cannot exceed 10 MiB. The supported
source types are PDF, PNG, JPEG and TXT. Extension/MIME must match; PDF/PNG/JPEG
require matching signatures. TXT requires valid UTF-8 with an optional UTF-8 BOM
and `text/plain`, optionally with a UTF-8 charset. The original bytes, including
any BOM, are preserved; the Function does not extract, convert, chunk or embed.
[Native CU TXT format support][cu-formats] was checked on 2026-09-11; documented
format support does not prove a successful live SharePoint-to-CU path.
SharePoint accepts only the configured hostname/site/default-drive file; Graph
access must use `Sites.Selected` plus a read grant to that site. This module does
not grant Graph permissions. Downloads are streamed with a byte limit; Graph
download redirects must stay on the configured SharePoint hostname and are
followed without forwarding the Graph bearer. No arbitrary external redirect
is followed. Hosts requiring other download domains need
explicit review, not a permissive suffix wildcard.

**Parent native-ingestion prerequisite:** use the root `native_ingestion` output
to initialize the six explicit version-2 definitions over `spo-staging`, restricted
to `native/`: datasource, index, skillset, private indexer, `searchIndex` knowledge
source and knowledge base. The Function stages documents under that prefix;
Search executes native CU extraction/chunking, embeddings and child projections.
The knowledge source references the explicit index; it does not generate the
ingestion resources. The Function neither calls CU/Search nor writes index documents.

The Function retains its staging `Storage Blob Data Contributor` grant, host
storage roles, app-role assignments, and Easy Auth. The module no longer accepts
`content_understanding_account_id`, `content_understanding_endpoint`, `search_id`,
`search_endpoint`, or `search_index`, and emits no `CU_*` or `SEARCH_*` settings.
Do not deploy the old synchronous ingestion package with this configuration.

The active path uses Search S1 with an explicit `executionEnvironment: private`
indexer and API `2026-08-01-preview`. Direct private built-in-skill indexers require
a service created after April 3, 2024; embeddings additionally require a
high-capacity region. The current Central US S1 service, created September 9, 2026,
passed the specific native CU/embedding fixture path with South Central US models.
The generated private `azureBlob` S2+ route and its earlier quota blocker are
historical, not the active prerequisite. Root Terraform attaches a dedicated ingestion UAMI to Search alongside
its existing system identity. Use `native_ingestion.identity_resource_id` for
the ingestion identity and model `authIdentity`; a query-time vectorizer can use
the same identity. The system identity still owns primary-account planner access.

The parent must explicitly approve the three `shared_private_links` entries:
secondary staging `blob`, secondary Foundry `foundry_account`, and secondary
Foundry `openai_account`. The existing primary `spl-foundry` planner link remains
separate. Verify explicit indexer private execution and successful synchronization
before claiming readiness. There is no public fallback. Search-managed SPL traffic
does not establish transit through either lab hub; routing is unchanged.

See the [native ownership/migration guide](../../../docs/native-ingestion.md),
[private indexer connections][private-indexer] and the historical
[generated Blob prerequisites][blob-ks]. Staging retention, runtime 202
behavior, source creation, link approval, and synchronization checks are owned by
the parent runtime/scripts, not this Terraform module.

[blob-ks]: https://learn.microsoft.com/azure/search/agentic-knowledge-source-how-to-blob
[private-indexer]: https://learn.microsoft.com/azure/search/search-indexer-howto-access-private
[cu-formats]: https://learn.microsoft.com/azure/search/cognitive-search-skill-content-understanding

Responses use valid JSON and a generated `request_id`, also in `X-Request-ID`.
Staging acceptance returns identifiers, not document contents. Failures return a stable
code and stage; logs contain only correlation, stage, outcome, duration, and
exception type. Easy Auth can reject before the handler and has its own response
format; handler correlation is not promised for a platform-level rejection.

## Current SharePoint Boundary

Actual SharePoint integration is deferred because no sample is available. The user
accepted the structure for publication, not as acquisition proof or grant approval.
The fixture-backed native S1 baseline remains validated; no further cloud actions
are planned for this publication.

As of 2026-09-11, 15 UTC, deployment `077916bd-dee7-4c46-be1f-7b9965eb9de6`
includes TXT staging and root Graph site URL handling. Its package SHA-256 is
`e5e895a83396d468ab404abd78c4f95f737c9f9ee42c5841cee797dd7f0e78d8`.
The configured `funwithfoundry-architecture-note.txt` is unchanged. The earlier
pre-Graph HTTP 415 is historical; the retry now returns HTTP 502. Complete Function
Graph app-role inventory is empty (count 0, no more pages), confirming missing
`Sites.Selected`. Delegated root-site lookup succeeds but exact file metadata and
site-permissions GETs return 403 `accessDenied`. File existence and site consent
remain unknown. No directory/site/content permissions changed, and no actual
SharePoint CU acceptance is claimed.

After reviewing existing grants, an authorized administrator can use
[Grant-SharePointAccess.ps1](../../../scripts/Grant-SharePointAccess.ps1) with
`-TerraformDir .\terraform -Role read` from the repository root. The helper
inventories grants before writing, assigns `Sites.Selected` and read on one site
as needed, and never uses a broader fallback. Managing site permissions requires
`Sites.FullControl.All` on the **consenting Graph client, not the Function**, plus
operator authority to assign the Graph application role. Azure Owner PIM alone is
insufficient. This is optional future work requiring an approved sample and separate
consent. See the [administrator handoff](../../../docs/native-ingestion.md#sharepoint-administrator-handoff)
for output-derived setup and the private verification command; dated lab targets
remain in [validation history](../../../docs/VALIDATION.md#sharepoint-administrator-boundary).

## Local Verification

Use a disposable copy of the Terraform configuration and tests, without tfvars,
state, saved plans, or deployment artifacts. Initialize it with `-backend=false`
and the existing provider cache. Copy the root dependency lockfile read-only for
root validation; standalone module copies can prune unused providers from their
own copied lockfiles. Never change the deployment lockfile for a test run.

With `$checkRoot` pointing to that initialized disposable copy:

```powershell
terraform "-chdir=$checkRoot" validate -no-color
terraform "-chdir=$checkRoot" test -no-color
terraform "-chdir=$checkRoot/modules/foundry-agent-private" test -no-color
terraform "-chdir=$checkRoot/modules/ingest-function" test -no-color
```

Native Terraform tests mock **every** provider and run plans only. The root tests
check the exact native-ingestion output, resource-scoped grants, SPL targets,
Function role separation and the explicit S1 path. The primary module tests evaluate the
dual identity body and preserve the system-identity planner grant and primary SPL.
The Function tests check staging-only settings, Blob access, caller identity pairs,
the application-only role, empty allowlist rejection, and provider-tenant mismatch.
Targeting in the root and Search mock tests deliberately limits the graph under
test; it is not a deployment recommendation. Fixture IDs are known, so these tests
do not prove fresh-deployment unknown-value behavior or Azure service acceptance.

Historical generated-source validation on 2026-09-10: root validation and all seven mocked cases passed
with Terraform 1.15.8, AzureRM 4.81.0, AzAPI 2.12.0, and AzureAD 3.9.0. The new
mocks use plan-time overrides. No runtime package, Azure networking, preview
capability, SPL approval, or actual indexer execution is validated by these mocks.
Never substitute a live `terraform plan` or `apply` for this procedure.

The 2026-09-11 follow-up full gate passed 81 Python tests with zero skips (40
ingestion, 29 retrieval, 12 schema), initializer 12237 and end-to-end 1333 checks
on both PowerShell 7/5.1, deployment 456, five Terraform tests and 286 documentation
links. See [current validation](../../../docs/VALIDATION.md#current-native-follow-up);
the earlier seven-case result is not the current run's count.

## Private Runner Check

After compatible native-source creation, deployment and explicit approval, run
[Test-Ingestion.ps1](../../../scripts/jumpbox/Test-Ingestion.ps1) **inside the VNet**. Supply `FunctionHostname`
and `ApiClientId` from outputs. By default it obtains an IMDS token from the VM;
pass `ManagedIdentityClientId` to select an approved user-assigned identity.
Alternatively pass an already-acquired token as a `SecureString` in `AccessToken`.
Use `-WhatIf` for a no-network preview. The live check writes the fixed fixture
twice through the Function and verifies stable identity, plus unauthorized and
input-rejection probes. `-IncludeSharePoint` requires separate site consent.
`DeniedAccessToken` optionally tests a real unapproved caller's token for 403.
The script emits sanitized machine-readable checks and exits nonzero on failure.
It never labels generic 403 as proof of public-network isolation and does not
claim IQ/native-agent retrieval; the separate end-to-end verifier supplies those checks.

Normal Knowledge/Verify use default-off initializer `-RefreshDataSourceBinding`
to renew only a valid configuration-matched receipt whose ETag alone is stale.
The refresh issues one current-ETag `If-Match` PUT, validates readback and saves the
receipt; wrong/missing receipts or visible drift block and HTTP 412 is not retried.
Explicit `-RebindDataSource` remains reviewed adoption. Verify initializes after
authorization probes immediately before E2E, even with an existing checkpoint.
Two normal Verify passes and immediate same-ETag/no-PUT receipt reuse are recorded
in [validation](../../../docs/VALIDATION.md#current-native-follow-up); they do not
prove a full orchestrator DAG or deletion behavior.

The [end-to-end verifier](../../../scripts/jumpbox/Invoke-EndToEnd.ps1) defaults to
`-Mode fixture`. Real `-Mode sharepoint` requires explicit `-Question` and
`-ExpectedAnswer`, a matching returned staging mode and all existing provenance,
fresh indexing, IQ and strict agent guards. Use the
[complete private-runner example](../../../docs/native-ingestion.md#private-sharepoint-verification)
after approved consent; a fixture pass is not SharePoint acquisition proof.

No cloud deployment, consent grant, live Function ingestion, or retrieval test
is performed by the local verification commands above.
