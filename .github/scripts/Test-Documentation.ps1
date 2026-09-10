[CmdletBinding()]
param([Parameter(Mandatory)][string]$PythonPath, [switch]$Required)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$suffix = if ($IsWindows) { '.cmd' } else { '' }
$markdownlint = Join-Path $root ".github/node_modules/.bin/markdownlint-cli2$suffix"
$mermaid = Join-Path $root ".github/node_modules/.bin/mmdc$suffix"
$missing = [System.Collections.Generic.List[string]]::new()
& $PythonPath -c 'import importlib.util, sys; sys.exit(int(any(importlib.util.find_spec(name) is None for name in ("yamllint", "markdown_it"))))'
if ($LASTEXITCODE -ne 0) { $missing.Add('Python documentation requirements') }
foreach ($tool in @($markdownlint, $mermaid)) { if (-not (Test-Path -LiteralPath $tool)) { $missing.Add($tool) } }
if ($missing.Count) {
    $message = "Documentation dependencies missing: $($missing -join ', '). See CONTRIBUTING.md."
    if ($Required) { throw $message }
    Write-Warning "NOT RUN: $message"
    return
}

function Invoke-DocumentationCheck {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Documentation check failed: $Command (exit $LASTEXITCODE)." }
}

Push-Location $root
$preview = Join-Path ([System.IO.Path]::GetTempPath()) "fwf-mermaid-$([guid]::NewGuid().ToString('N'))"
try {
    $files = @(git -c core.quotepath=false ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate documentation inputs.' }
    $files = @($files | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $yamlFiles = @($files | Where-Object { $_ -match '\.ya?ml$' })
    $markdownFiles = @($files | Where-Object { $_ -match '\.md$' })
    $diagrams = @($files | Where-Object { $_ -match '^docs/diagrams/.*\.mmd$' })
    if (-not $yamlFiles.Count -or -not $markdownFiles.Count -or -not $diagrams.Count) {
        throw 'Expected YAML, Markdown, and Mermaid inputs; refusing an empty documentation check.'
    }
    Invoke-DocumentationCheck $PythonPath (@('-m', 'yamllint', '-c', '.github/.yamllint.yaml') + $yamlFiles)
    Invoke-DocumentationCheck $markdownlint (@('--config', '.github/.markdownlint-cli2.jsonc') + $markdownFiles)
    Invoke-DocumentationCheck $PythonPath (@('.github/scripts/check-local-links.py') + $markdownFiles)
    $null = New-Item -ItemType Directory -Path $preview
    foreach ($diagram in $diagrams) {
        $image = Join-Path $preview "$([System.IO.Path]::GetFileNameWithoutExtension($diagram)).png"
        Invoke-DocumentationCheck $mermaid @('-i', $diagram, '-o', $image, '-p', '.github/puppeteer.json', '-b', 'white', '-w', '1600')
        if (-not (Test-Path -LiteralPath $image) -or (Get-Item -LiteralPath $image).Length -lt 100) {
            throw "Mermaid produced no usable render: $diagram"
        }
    }
    Write-Host "PASS documentation: $($yamlFiles.Count) YAML, $($markdownFiles.Count) Markdown, local file links, $($diagrams.Count) Mermaid renders"
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $preview) { Remove-Item -LiteralPath $preview -Recurse -Force }
}
