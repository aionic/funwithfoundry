# Contributing

Contributions are welcome through GitHub issues and pull requests.

## Development checks

Before opening a pull request:

```powershell
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate

Get-ChildItem scripts -Recurse -Filter *.ps1 | ForEach-Object {
    [void][scriptblock]::Create((Get-Content $_.FullName -Raw))
}

python -m compileall -q scripts src

# Validate the checked-in Mermaid architecture contracts
$preview = Join-Path $env:TEMP 'funwithfoundry-mermaid-check'
New-Item -ItemType Directory -Force -Path $preview | Out-Null
Get-ChildItem .\docs\diagrams\*.mmd | ForEach-Object {
    npx --yes @mermaid-js/mermaid-cli@11.12.0 -i $_.FullName -o (Join-Path $preview "$($_.BaseName).png")
    if ($LASTEXITCODE -ne 0) { throw "Mermaid validation failed: $($_.Name)" }
}
```

Never commit Terraform state, plans, variable files, deployment logs, preflight output, Azure
credentials, or environment-specific identifiers. Use `terraform/terraform.tfvars.example` as the
starting point for local configuration.

When behavior or deployment status changes, cross-check `README.md`, `docs/architecture.md`, and
`docs/PLAN.md`. Keep unverified paths explicitly labeled; provisioning a resource is not the same as
exercising its application flow.