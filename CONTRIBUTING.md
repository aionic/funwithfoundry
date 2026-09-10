# Contributing

Contributions are welcome through GitHub issues and pull requests.

## Development checks

Use PowerShell 7, uv, and an explicitly selected Python interpreter. The runner never uses an
unconfigured `python` from PATH. From the repository root, create separate native, Function,
client and documentation environments. Keep these outside packaged source directories:

```powershell
$PSNativeCommandUseErrorActionPreference = $true
uv venv --python 3.13.7 "$env:TEMP\fwf-native"
uv venv --python 3.11.13 "$env:TEMP\fwf-ingestion"
uv venv --python 3.13.7 "$env:TEMP\fwf-hello"
uv venv --python 3.13.7 "$env:TEMP\fwf-docs"
$env:FWF_PYTHON = "$env:TEMP\fwf-native\Scripts\python.exe"
$env:FWF_INGEST_PYTHON = "$env:TEMP\fwf-ingestion\Scripts\python.exe"
$env:FWF_HELLO_PYTHON = "$env:TEMP\fwf-hello\Scripts\python.exe"
$env:FWF_DOCS_PYTHON = "$env:TEMP\fwf-docs\Scripts\python.exe"
uv pip install --python $env:FWF_PYTHON --require-hashes -r src/foundry_native_agent/requirements.lock
uv pip install --python $env:FWF_INGEST_PYTHON --require-hashes -r src/ingest_func/requirements.lock
uv pip install --python $env:FWF_HELLO_PYTHON --require-hashes -r src/hello_world/requirements.lock
uv pip install --python $env:FWF_DOCS_PYTHON -r .github/requirements.txt
uv pip check --python $env:FWF_PYTHON
uv pip check --python $env:FWF_INGEST_PYTHON
uv pip check --python $env:FWF_HELLO_PYTHON
uv pip check --python $env:FWF_DOCS_PYTHON
npm ci --prefix .github --no-audit --no-fund
```

Run the same cloud-free release command used by Windows CI:

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1 -Terraform -Release
```

Alternatively supply `-PythonPath <native-python>`, `-IngestionPythonPath <function-python>`
and `-DocumentationPythonPath <docs-python>`.
An activated virtual environment is also accepted. Without a separate ingestion interpreter,
both suites use the selected interpreter, which is useful for limited local development but
does not validate the two distinct runtime dependency sets.

The Function pins `azure-identity==1.25.1`; native agent and client pin `1.25.3`. Do not merge
those manifests or override either pin just to install tests. CI installs the complete Function,
native and client locks, including dependencies mocked by some tests. Direct requirements
are resolver inputs; the three component `requirements.lock` files pin transitives and hashes.
CI uses `uv pip sync --require-hashes` for clean environments. No `uv.lock` is required for
these pip-compatible locks. Regenerate and review the relevant lock when changing requirements;
Dependabot changes to pip manifests alone are not a complete dependency update.

The native lock keeps stable Pydantic 2.13.5 and the explicitly required Azure preview
dependencies listed in [compatibility.md](docs/compatibility.md). Do not resolve the whole
environment with unrestricted prereleases. Function packaging and native staging both install
their locks through packaged `--require-hashes` / `-r requirements.lock` requirements.
Local setup success does not prove the remote build or private-runner Python bootstrap.

### What the command checks

- Parses all tracked PowerShell scripts/modules/data files plus new nonignored files, including tests.
- Compiles all tracked/new Python sources without executing application entrypoints.
- Runs standard-library unittest suites: 24 ingestion, 17 retrieval and 4 schema checks.
    The verified local total is 45 with zero skips, using actual Python 3.11.13 for ingestion
    and 3.13.7 for native tests. Four retrieval tests require LangGraph. Missing imports fail normally;
    local skips remain visible, and `-Release` makes any skip a failure. Zero discovered tests fail.
- Runs 156 operational assertions, four native deployment scenarios and 56 deployment guards.
- On Windows, runs 223 artifact-transfer guard assertions using local mocks and native Windows
    OpenSSH clients. These cover one narrow privileged transport lifecycle, not 223 live scenarios.
    No Azure credentials or Bastion connection are used. Live transfer/cleanup proof is separate.
- With `-Terraform`, checks root formatting recursively, initializes without a backend and
    validates root/module configuration in a disposable copy, then runs only the existing mocked
    ingestion auth tests (three passed). No local state, plans, tfvars, Azure login, apply, or refresh is used.
    Provider downloads need registry access. The root lockfile is honored read-only; the child
    module has no committed lockfile and resolves its declared provider constraints independently.
- Checks YAML with yamllint, basic Markdown structure, local file links, and temporary Mermaid
    renders using the npm lockfile. External URL availability and heading fragments are not checked.
    Render success is syntax evidence, not architecture approval or final diagram publication.
    The two current final contracts are already approved, with reproduced and inspected PNGs;
    do not automatically approve changed sources or refresh visual-inspection records.

Without `-Release`, documentation defaults to `Auto`: missing tools produce an explicit warning.
Use `-Documentation Required` to fail on missing tools or `-Documentation Skip` to opt out locally.
`-Release` requires documentation and rejects `-Quick` or `-Documentation Skip`. Terraform remains
an explicit flag; use **both** `-Terraform -Release` for the complete CI command. Missing tools,
nonzero subprocess exits, parse failures, and failed tests stop the run. No dependency is installed
by the runner itself. Mermaid needs Chromium and its OS libraries; npm installation downloads
the pinned Puppeteer browser. Its no-sandbox configuration is only for local/isolated CI rendering,
never a service processing customer content.

The full release gate must be rerun after the latest artifact-transfer integration.
Before that update, documentation checks passed for 10 YAML files, 17 Markdown files,
99 local links and two Mermaid contracts. Keep these dated results distinct from a
fresh release pass. For documentation-only work, use the
[targeted lint command](docs/automation.md#recorded-local-evidence).

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
    `Secret scan` before merging into `main`, after their first run.
- Require pull requests, fresh approvals after changes, resolved conversations, and code-owner
    review by `@aionic`; ensure the owner actually has repository write access. Disallow bypasses
    and force pushes according to the repository's policy.
- Keep the default workflow token read-only and require approval of workflows from outside
    contributors. Review workflow/dependency changes before running them. No automatic dependency merges.
- Review Dependabot PRs for actions, pip manifests, and the documentation npm lockfile.

### Cloud deployment is deferred

No deployment workflow is provided until the resumable orchestration and private-runner contract
are deployed and rehearsed. Do not interpret `workflow_dispatch` on the checks workflow as deployment.
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
Mermaid CLI 11.12.0, markdownlint-cli2 0.18.1, yamllint 1.37.1, markdown-it-py 4.0.0,
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

When behavior or deployment status changes, cross-check [README.md](README.md),
[docs/architecture.md](docs/architecture.md) and
[docs/ACCELERATOR-PLAN.md](docs/ACCELERATOR-PLAN.md). Preserve earlier evidence as explicitly
historical; do not carry old deployment success into the new accelerator status. Provisioning
a resource is not the same as exercising its application flow. No Azure writes or commits
are implied by local checks or documentation approval.
