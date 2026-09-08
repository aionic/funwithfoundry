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
```

Never commit Terraform state, plans, variable files, deployment logs, preflight output, Azure
credentials, or environment-specific identifiers. Use `terraform/terraform.tfvars.example` as the
starting point for local configuration.