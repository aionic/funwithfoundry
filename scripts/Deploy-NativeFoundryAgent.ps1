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
    [string]$SearchConnectionName
)

$ErrorActionPreference = 'Stop'

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

if (-not (azd env list --output json | ConvertFrom-Json | Where-Object name -eq $EnvironmentName)) {
    azd env new $EnvironmentName --no-prompt | Out-Null
}
azd env select $EnvironmentName --no-prompt | Out-Null
azd env set AZURE_AI_PROJECT_ID $ProjectId | Out-Null
azd env set AZURE_LOCATION $Location | Out-Null
azd env set FOUNDRY_PROJECT_ENDPOINT $ProjectEndpoint | Out-Null
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $ModelDeployment | Out-Null
azd env set SEARCH_ENDPOINT $SearchEndpoint | Out-Null
azd env set SEARCH_CONNECTION_NAME $SearchConnectionName | Out-Null
azd env set FOUNDRY_IQ_KNOWLEDGE_BASE 'spo-knowledge-base' | Out-Null

$connections = azd ai connection list --project-endpoint $ProjectEndpoint --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Foundry project connections.' }
if (-not ($connections | Where-Object name -eq $SearchConnectionName)) {
    throw "The Terraform-managed Search connection '$SearchConnectionName' was not found."
}

$toolboxes = azd ai toolbox list --project-endpoint $ProjectEndpoint --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Foundry toolboxes.' }
if ($toolboxes | Where-Object name -eq 'foundry-rag') {
    $toolbox = azd ai toolbox show foundry-rag --project-endpoint $ProjectEndpoint --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the foundry-rag toolbox.' }
}

$toolboxQueryType = $toolbox.version.tools[0].azure_ai_search.indexes[0].query_type
if ($toolboxQueryType -ne 'simple') {
    $toolboxTemplate = Get-Content (Join-Path $PSScriptRoot '..\toolbox.yaml') -Raw
    $searchConnectionId = "$ProjectId/connections/$SearchConnectionName"
    $toolboxDefinition = $toolboxTemplate.Replace('__SEARCH_CONNECTION_NAME__', $SearchConnectionName).Replace('__SEARCH_CONNECTION_ID__', $searchConnectionId)
    $toolboxPath = Join-Path $env:TEMP 'funwithfoundry-toolbox.yaml'
    Set-Content -Path $toolboxPath -Value $toolboxDefinition -Encoding utf8
    try {
        if ($toolbox) {
            $deployedToolbox = azd ai toolbox deploy $toolboxPath `
                --project-endpoint $ProjectEndpoint --output json --no-prompt | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw 'Unable to deploy the foundry-rag toolbox.' }
            azd ai toolbox publish foundry-rag $deployedToolbox.version.version `
                --project-endpoint $ProjectEndpoint --no-prompt | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to publish the foundry-rag toolbox version.' }
        }
        else {
            azd ai toolbox create foundry-rag --from-file $toolboxPath `
                --project-endpoint $ProjectEndpoint --no-prompt | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to create the foundry-rag toolbox.' }
        }
    }
    finally {
        Remove-Item $toolboxPath -ErrorAction SilentlyContinue
    }
}

$toolbox = azd ai toolbox show foundry-rag --project-endpoint $ProjectEndpoint --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $toolbox.endpoint) { throw 'Unable to resolve the toolbox endpoint.' }

azd deploy funwithfoundry-rag-agent --environment $EnvironmentName --no-prompt
if ($LASTEXITCODE -ne 0) { throw 'Native Foundry agent deployment failed.' }

azd ai agent show funwithfoundry-rag-agent --environment $EnvironmentName --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the native Foundry agent.' }