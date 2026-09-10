<#
.SYNOPSIS
    Initialize the canonical text/semantic Search index and Foundry IQ on a private runner.
.DESCRIPTION
    Uses the runner managed identity. Does not ingest documents or delete incompatible indexes.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[a-zA-Z0-9-]+\.search\.windows\.net/?$')]
    [string]$SearchEndpoint,
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[a-zA-Z0-9-]+\.openai\.azure\.com/?$')]
    [string]$FoundryOpenAIEndpoint,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlannerDeployment,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlannerModel,
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..\src\shared\search-index.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json
if ($schema.name -ne 'spo-docs' -or (@($schema.fields.name) -join ',') -ne 'id,title,content,source_url,source_id,content_hash') {
    throw 'Unexpected canonical Search schema.'
}
if (-not $PSCmdlet.ShouldProcess($SearchEndpoint, 'PUT canonical index, knowledge source, and knowledge base')) { return }

$headers = @{}
try {
    $resource = [uri]::EscapeDataString('https://search.azure.com/')
    $identityUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource"
    $identity = Invoke-RestMethod -Uri $identityUri -Headers @{ Metadata = 'true' } -TimeoutSec 15 -MaximumRedirection 0
    if (-not $identity.access_token) { throw 'Managed identity returned no Search token.' }
    $headers.Authorization = "Bearer $($identity.access_token)"
    $source = @{
        name = 'spo-knowledge-source'
        kind = 'searchIndex'
        description = 'Documents processed by the authorized ingestion Function.'
        searchIndexParameters = @{ searchIndexName = $schema.name }
    }
    $knowledgeBase = @{
        name = 'spo-knowledge-base'
        description = 'Foundry IQ over Function-ingested content.'
        knowledgeSources = @(@{ name = $source.name })
        models = @(@{
            kind = 'azureOpenAI'
            azureOpenAIParameters = @{
                resourceUri = $FoundryOpenAIEndpoint.TrimEnd('/')
                deploymentId = $PlannerDeployment
                modelName = $PlannerModel
            }
        })
    }
    foreach ($definition in @(
        @{ path = "indexes/$($schema.name)"; api = '2024-07-01'; body = $schema },
        @{ path = "knowledgeSources/$($source.name)"; api = '2026-05-01-preview'; body = $source },
        @{ path = "knowledgeBases/$($knowledgeBase.name)"; api = '2026-05-01-preview'; body = $knowledgeBase }
    )) {
        $uri = "$($SearchEndpoint.TrimEnd('/'))/$($definition.path)?api-version=$($definition.api)"
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers `
                -ContentType 'application/json' -Body ($definition.body | ConvertTo-Json -Depth 20 -Compress) `
                -TimeoutSec 120 -MaximumRedirection 0
            $actual = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60 -MaximumRedirection 0
            if ($actual.name -ne $definition.body.name) { throw 'Read-back identity mismatch.' }
        }
        catch {
            throw "Knowledge initialization failed at $($definition.path). Check private DNS, Search RBAC, approved openai_account link, planner deployment, and schema compatibility. Existing indexes are never deleted automatically."
        }
    }
    [pscustomobject]@{
        status = 'succeeded'
        index = $schema.name
        knowledge_source = $source.name
        knowledge_base = $knowledgeBase.name
        schema_sha256 = (Get-FileHash -LiteralPath $SchemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
        planner_deployment = $PlannerDeployment
        planner_model = $PlannerModel
    }
}
finally {
    $headers.Clear()
    $identity = $null
}
