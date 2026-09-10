## Change

Describe the behavior changed and link the issue. State any security or deployment impact.

## Evidence

- [ ] Ran `scripts/Test-Repository.ps1 -Terraform -Release` with both configured interpreters.
- [ ] Included actual test results and listed any blocked checks or missing dependencies.
- [ ] No state, plans, credentials, document contents, or environment-specific output included.
- [ ] Documentation distinguishes mocked checks from live integration evidence.

Local syntax-only hooks do not replace the required cloud-free CI checks. Do not include
tokens or raw customer documents in logs or screenshots.
