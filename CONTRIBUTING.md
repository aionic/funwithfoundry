# Contributing

Contributions are welcome through GitHub issues and pull requests.

## Development checks

Use [docs/TESTING.md](docs/TESTING.md) for canonical local setup, isolated uv
environments, focused checks and the full cloud-free release gate. Local checks
do not authorize Azure writes or certify a remote build or private-runner bootstrap.

Keep the Function, native agent and client dependency sets separate. The Function
pins `azure-identity==1.25.1`; native and client pin `1.25.3`. Direct requirements are
resolver inputs; component `requirements.lock` files pin transitives and hashes.
CI syncs the complete locks with `uv pip sync --require-hashes`, including dependencies
mocked by tests. No `uv.lock` is required for these pip-compatible locks. Regenerate
and review the relevant lock when requirements change; a manifest-only Dependabot
update is incomplete. Retain required extras, including the Function's `PyJWT[crypto]`.

Function packaging writes the full hashed lock into the packaged `requirements.txt`;
the included hashes activate pip hash-checking mode. Native staging uses a wrapper
containing `--require-hashes` and `-r requirements.lock`, alongside the lock itself.
Preserve both packaging contracts. The native lock keeps stable Pydantic 2.13.5 and
only the required Azure previews in [compatibility.md](docs/compatibility.md);
do not resolve the whole environment with unrestricted prereleases.

## Optional local hook

The single hook configuration is [.pre-commit-config.yaml](.pre-commit-config.yaml). Opt in locally:

```powershell
uv tool install pre-commit==4.3.0
pre-commit install
pre-commit run --all-files
```

Keep `FWF_PYTHON` set or a virtual environment activated in the process launching Git (including
your editor). The hook runs `-Quick`, meaning syntax only, against the current working tree.
It does not certify staged-only contents or replace CI. No hook or Git configuration is installed
automatically. Uninstall with `pre-commit uninstall`.

## GitHub controls

[Repository checks](.github/workflows/repository.yml) runs on every pull request, including
documentation-only changes, and pushes to `main`. There are no path filters or success-only
placeholder jobs. Windows executes the full gate; Linux runs quick syntax and the Python
ingestion/retrieval/schema suites only, using the same 3.11.13/3.13.7 runtime split. Linux does
not claim the Windows transport, Terraform or full documentation gate. All runners are GitHub-hosted;
checkout does not persist credentials. No Azure secrets, federated identity, `id-token: write`,
`pull_request_target`, environment access, or private-runner labels are used.

Gitleaks uses its pinned action and scanner, with a read-only GitHub token, comments and artifact
uploads disabled. It scans PR changes/history selected by the action, not arbitrary untracked
local files. No Azure credentials are passed to PRs. Personal-owner repositories need no Gitleaks
license; transfer to an organization requires revisiting licensing or replacing the action with
the standalone scanner. Do not expose an organization license to fork code to bypass that gate.

A maintainer must configure these controls in GitHub; adding these files does **not** configure
rulesets, branch protection, reviewer permissions, environments, or merge restrictions:

- Require `Cloud-free checks (windows-2022)`, `Cloud-free checks (ubuntu-24.04)` and
    `Secret scan` before merging into `main`.
- Require pull requests, fresh approvals after changes, resolved conversations, and code-owner
    review by `@aionic`; ensure the owner actually has repository write access. Disallow bypasses
    and force pushes according to the repository's policy.
- Keep the default workflow token read-only and require approval of workflows from outside
    contributors. Review workflow/dependency changes before running them. No automatic dependency merges.
- Review Dependabot PRs for actions, pip manifests, and the documentation npm lockfile.

The dated [publication verification](docs/VALIDATION.md#publication) records a green
hosted Windows/Linux/secret-scan baseline, but `main` was unprotected with no rulesets.
Passing checks are not enforced merge requirements; administrative configuration
and verification remain separate from workflow execution.

### Cloud deployment is deferred

No cloud deployment workflow is provided. The accepted rehearsal recorded in
[VALIDATION.md](docs/VALIDATION.md) does not configure GitHub deployment automation.
Do not interpret `workflow_dispatch` on the checks workflow as deployment.
A future workflow must consume an explicitly selected, protected environment's user-configured
subscription/project variables, validate them against Terraform outputs, and fail on missing or
mismatched values. It must use manual dispatch from a reviewed commit on a protected branch,
required environment approvers with self-approval prevented, and environment-scoped OIDC with
least-privilege roles. Grant `id-token: write` only to that approved deployment job.

Restrict its runner group to the deployment workflow and trusted repository, using dedicated,
isolated private-runner labels, ephemeral workspaces, and no shared login caches. Fork PRs and
other untrusted code must never run there, even after a PR label or ordinary workflow approval.
Do not trigger deployment through `pull_request_target`, automatic `workflow_run`, schedules,
or downloaded untrusted artifacts. Capture sanitized stage results and require separate approval
for teardown. Verify these settings before enabling any deploy job; none is configured here.

## Compatibility record

CI selection as of 2026-09-09: Python 3.11.13 (Function) and 3.13.7 (native/client),
Terraform 1.15.8, uv 0.8.13, Node 22.16.0,
Mermaid CLI 11.12.0, markdownlint-cli2 0.18.1, yamllint 1.38.0, markdown-it-py 4.2.0,
Gitleaks 8.24.2. Python runtime pins remain in their source manifests. A selected version is
not evidence of a completed GitHub run or live deployment. Record actual execution results
and environment blockers in the PR/release evidence.

Action refs below were resolved with `git ls-remote` against the official repositories on
2026-09-09, not inferred from a version string:

| Action | Source tag | Resolved commit |
| --- | --- | --- |
| actions/checkout | v4.2.2 | `11bd71901bbe5b1630ceea73d27597364c9af683` |
| actions/setup-python | v5.6.0 | `a26af69be951a213d495a4c3e4e4022e16d87065` |
| astral-sh/setup-uv | v6.8.0 | `d0cc045d04ccac9d8b7881df0226f9e82c39688e` |
| hashicorp/setup-terraform | v3.1.2 | `b9cd54a3c349d3f38e8881555d616ced269862dd` |
| actions/setup-node | v4.4.0 | `49933ea5288caeca8642d1e84afbd3f7d6820020` |
| gitleaks/gitleaks-action | v2.3.9 | `ff98106e4c7b2bc287b24eaf42907196329070c7` |

The scanner source tag `gitleaks/gitleaks` v8.24.2 separately resolves to
`9c72c5f9f05200fdc06e3f1b16e9aaa89fbe9f75`. Local installation is not required by the
repository runner; the secret-scan job must complete before merge/release.

## Evidence hygiene

Never commit Terraform state, plans, variable files, deployment logs, preflight output, Azure
credentials, or environment-specific identifiers. Use `terraform/terraform.tfvars.example` as the
starting point for local configuration.

When behavior changes, cross-check [docs/architecture.md](docs/architecture.md) and
[docs/deployment.md](docs/deployment.md). Keep dated results in
[docs/VALIDATION.md](docs/VALIDATION.md) and status/history in
[docs/STATUS.md](docs/STATUS.md), reachable from the [documentation hub](docs/README.md).
Preserve earlier evidence as explicitly historical; do not carry old deployment
success into a new release. Provisioning a resource is not the same as exercising
its application flow. No Azure writes or commits are implied by local checks or
documentation approval.
