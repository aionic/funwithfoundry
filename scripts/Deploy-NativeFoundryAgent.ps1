<#
.SYNOPSIS
    Deploy the New Foundry hosted agent and its Search-backed toolbox.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [string]$EnvironmentName = 'funwithfoundry-dev',
    [string]$ProjectId,
    [string]$Location,
    [string]$ProjectEndpoint,
    [string]$ModelDeployment,
    [string]$SearchEndpoint,
    [string]$SearchConnectionName,
    [switch]$AzdDebug,
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'

function Test-NativeSearchToolbox {
    param($Toolbox, [string]$ConnectionId, [string]$ConnectionName)
    $tools = @($Toolbox.version.tools | Where-Object { $null -ne $_ })
    $indexes = @($tools | ForEach-Object { $_.azure_ai_search.indexes } | Where-Object { $null -ne $_ })
    if ($tools.Count -ne 1 -or $indexes.Count -ne 1) { return $false }
    return $tools[0].type -ceq 'azure_ai_search' -and $tools[0].name -ceq $ConnectionName -and
        $indexes[0].project_connection_id -ceq $ConnectionId -and $indexes[0].index_name -ceq 'spo-native-index' -and
        $indexes[0].query_type -ceq 'vector_semantic_hybrid' -and $indexes[0].top_k -eq 5
}

function Invoke-Azd {
    param([string[]]$CliArguments)
    $logDirectory = Join-Path (Get-Location) '.azure\native-diagnostics'
    $null = New-Item -ItemType Directory -Path $logDirectory -Force
    $logPath = Join-Path $logDirectory "$([guid]::NewGuid().ToString('N')).log"
    $readOnly = ($CliArguments[0] -eq 'env' -and $CliArguments[1] -eq 'list') -or
        ($CliArguments[0] -eq 'ai' -and $CliArguments[2] -in @('list', 'show'))
    $attemptLimit = if ($readOnly) { 3 } else { 1 }
    if ($AzdDebug) { $CliArguments += '--debug' }
    for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
        $ErrorActionPreference = 'Continue'
        $result = & azd @CliArguments 2>> $logPath
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($exitCode -eq 0) { break }
        if (($result -join ' ') -notmatch 'AzureDeveloperCLICredential|connection.*reset|temporarily unavailable') { break }
    }
    if ($exitCode -ne 0) { throw "ACTION: azd $($CliArguments[0..([Math]::Min(2, $CliArguments.Count - 1))] -join ' ') failed (exit $exitCode). Inspect protected runner diagnostics: $logPath" }
    $result
}

if ($ReadOnly) {
    if ([string]::IsNullOrWhiteSpace($ProjectEndpoint) -or [string]::IsNullOrWhiteSpace($EnvironmentName)) {
        throw 'Read-only native metadata requires ProjectEndpoint and EnvironmentName.'
    }
    $agent = Invoke-Azd @('ai', 'agent', 'show', 'funwithfoundry-rag-agent', '--environment', $EnvironmentName, '--output', 'json') | ConvertFrom-Json
    if ($null -eq $agent) { throw 'Native agent readback returned no metadata.' }
    $toolbox = Invoke-Azd @('ai', 'toolbox', 'show', 'foundry-rag', '--project-endpoint', $ProjectEndpoint, '--output', 'json') | ConvertFrom-Json
    if ($null -eq $toolbox) { throw 'Native toolbox readback returned no metadata.' }
    return [pscustomobject]@{ agent = $agent; toolbox = $toolbox }
}

if (-not $ProjectId) {
    $primary = terraform -chdir=$TerraformDir output -json foundry_primary | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read Foundry Terraform outputs.' }

    $ProjectId = terraform -chdir=$TerraformDir output -raw foundry_primary_project_id
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the Foundry project resource ID.' }
    $Location = $primary.location
    $ProjectEndpoint = $primary.project_endpoint
    $ModelDeployment = $primary.agent_tool_model
    $SearchEndpoint = $primary.search_endpoint
    $SearchConnectionName = $primary.search
}

$requiredValues = @{
    ProjectId           = $ProjectId
    Location            = $Location
    ProjectEndpoint     = $ProjectEndpoint
    ModelDeployment     = $ModelDeployment
    SearchEndpoint      = $SearchEndpoint
    SearchConnectionName = $SearchConnectionName
}
foreach ($entry in $requiredValues.GetEnumerator()) {
    if (-not $entry.Value) { throw "Missing required deployment value: $($entry.Key)" }
}

$environments = Invoke-Azd @('env', 'list', '--output', 'json') | ConvertFrom-Json
if (-not ($environments | Where-Object name -eq $EnvironmentName)) {
    Invoke-Azd @('env', 'new', $EnvironmentName, '--no-prompt') | Out-Null
}
Invoke-Azd @('env', 'select', $EnvironmentName, '--no-prompt') | Out-Null
Invoke-Azd @('env', 'set', 'AZURE_AI_PROJECT_ID', $ProjectId) | Out-Null
Invoke-Azd @('env', 'set', 'AZURE_LOCATION', $Location) | Out-Null
Invoke-Azd @('env', 'set', 'FOUNDRY_PROJECT_ENDPOINT', $ProjectEndpoint) | Out-Null
Invoke-Azd @('env', 'set', 'AZURE_AI_MODEL_DEPLOYMENT_NAME', $ModelDeployment) | Out-Null
Invoke-Azd @('env', 'set', 'SEARCH_ENDPOINT', $SearchEndpoint) | Out-Null
Invoke-Azd @('env', 'set', 'SEARCH_CONNECTION_NAME', $SearchConnectionName) | Out-Null
Invoke-Azd @('env', 'set', 'FOUNDRY_IQ_KNOWLEDGE_BASE', 'spo-native-knowledge-base') | Out-Null

$connections = Invoke-Azd @('ai', 'connection', 'list', '--project-endpoint', $ProjectEndpoint, '--output', 'json') | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Foundry project connections.' }
if (-not ($connections | Where-Object name -eq $SearchConnectionName)) {
    throw "The Terraform-managed Search connection '$SearchConnectionName' was not found."
}

$toolboxResponse = Invoke-Azd @('ai', 'toolbox', 'list', '--project-endpoint', $ProjectEndpoint, '--output', 'json') | ConvertFrom-Json
$toolboxes = if ($toolboxResponse.PSObject.Properties.Name -contains 'toolboxes') { @($toolboxResponse.toolboxes) } else { @($toolboxResponse) }
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Foundry toolboxes.' }
$toolbox = $null
if ($toolboxes | Where-Object name -eq 'foundry-rag') {
    $toolbox = Invoke-Azd @('ai', 'toolbox', 'show', 'foundry-rag', '--project-endpoint', $ProjectEndpoint, '--output', 'json') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the foundry-rag toolbox.' }
}

$searchConnectionId = "$($ProjectId.TrimEnd('/'))/connections/$SearchConnectionName"
$matches = Test-NativeSearchToolbox $toolbox $searchConnectionId $SearchConnectionName
if (-not $matches) {
    $toolboxTemplate = Get-Content (Join-Path $PSScriptRoot '..\toolbox.yaml') -Raw
    $toolboxDefinition = $toolboxTemplate.Replace('__SEARCH_CONNECTION_NAME__', $SearchConnectionName).Replace('__SEARCH_CONNECTION_ID__', $searchConnectionId)
    $toolboxPath = Join-Path $env:TEMP ("funwithfoundry-toolbox-$([guid]::NewGuid().ToString('N')).yaml")
    Set-Content -Path $toolboxPath -Value $toolboxDefinition -Encoding utf8
    try {
        if ($toolbox) {
            $deployedToolbox = Invoke-Azd @('ai', 'toolbox', 'deploy', $toolboxPath, '--project-endpoint', $ProjectEndpoint, '--output', 'json', '--no-prompt') | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw 'Unable to deploy the foundry-rag toolbox.' }
            $version = $deployedToolbox.version.version
            if (-not $version -and $deployedToolbox.version -is [string]) { $version = $deployedToolbox.version }
            if (-not $version) { throw 'Toolbox deployment returned no version; refusing to publish an unknown version.' }
            Invoke-Azd @('ai', 'toolbox', 'publish', 'foundry-rag', $version, '--project-endpoint', $ProjectEndpoint, '--no-prompt') | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to publish the foundry-rag toolbox version.' }
        }
        else {
            Invoke-Azd @('ai', 'toolbox', 'create', 'foundry-rag', '--from-file', $toolboxPath, '--project-endpoint', $ProjectEndpoint, '--no-prompt') | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to create the foundry-rag toolbox.' }
        }
    }
    finally {
        Remove-Item $toolboxPath -ErrorAction SilentlyContinue
    }
}

$toolbox = Invoke-Azd @('ai', 'toolbox', 'show', 'foundry-rag', '--project-endpoint', $ProjectEndpoint, '--output', 'json') | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $toolbox.endpoint) { throw 'Unable to resolve the toolbox endpoint.' }
if (-not (Test-NativeSearchToolbox $toolbox $searchConnectionId $SearchConnectionName)) {
    throw 'Native toolbox readback must match the configured Search connection, spo-native-index, and vector_semantic_hybrid.'
}

Invoke-Azd @('deploy', 'funwithfoundry-rag-agent', '--environment', $EnvironmentName, '--no-prompt')
if ($LASTEXITCODE -ne 0) { throw 'Native Foundry agent deployment failed.' }

Invoke-Azd @('ai', 'agent', 'show', 'funwithfoundry-rag-agent', '--environment', $EnvironmentName, '--output', 'json')
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the native Foundry agent.' }
