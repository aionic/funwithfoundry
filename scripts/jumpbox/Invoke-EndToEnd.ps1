[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$FunctionHostname,
    [Parameter(Mandatory)][guid]$ApiClientId,
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[a-zA-Z0-9-]+\.search\.windows\.net/?$')][string]$SearchEndpoint,
    [Parameter(Mandatory)][string]$ProjectEndpoint,
    [Parameter(Mandatory)][string]$SearchToolName,
    [Parameter(Mandatory)][string]$ModelDeployment,
    [Parameter(Mandatory)][string]$PythonExecutable,
    [string]$Question = 'Who is the fictional owner of Project Cedar?',
    [ValidateNotNullOrEmpty()][string]$ExpectedAnswer = 'Morgan Example'
)

$ErrorActionPreference = 'Stop'
if (-not $PSCmdlet.ShouldProcess($FunctionHostname, 'Ingest authorized fixture, read back provenance, and verify IQ plus native dual retrieval')) { return }
$ingestion = & (Join-Path $PSScriptRoot 'Invoke-IngestFunction.ps1') -FunctionHostname $FunctionHostname -ApiClientId $ApiClientId -Confirm:$false
if ($ingestion.status -ne 'indexed') { throw 'Function ingestion did not complete.' }
$headers = @{}
try {
    $resource = [uri]::EscapeDataString('https://search.azure.com/')
    $identity = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource" `
        -Headers @{ Metadata = 'true' } -TimeoutSec 15 -MaximumRedirection 0
    if (-not $identity.access_token) { throw 'Search managed identity token unavailable.' }
    $headers.Authorization = "Bearer $($identity.access_token)"
    $search = $SearchEndpoint.TrimEnd('/')
    $documentUri = "$search/indexes/spo-docs/docs/$($ingestion.document_id)?api-version=2024-07-01&`$select=id,source_id,content_hash"
    $deadline = [datetime]::UtcNow.AddMinutes(2)
    do {
        $document = $null
        try { $document = Invoke-RestMethod -Uri $documentUri -Headers $headers -TimeoutSec 30 -MaximumRedirection 0 }
        catch {
            $response = $_.Exception.PSObject.Properties['Response']
            if (-not $response -or [int]$response.Value.StatusCode -ne 404) { throw 'Search provenance read-back failed (not an indexing-delay 404).' }
        }
        if ($document.id -eq $ingestion.document_id -and $document.source_id -eq $ingestion.document_id -and $document.content_hash -eq $ingestion.content_hash) { break }
        if ([datetime]::UtcNow -ge $deadline) { throw 'Function-indexed provenance was not visible in Search before the deadline.' }
        Start-Sleep -Seconds 5
    } while ($true)
    $query = @{ messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = $Question }) }) }
    $retrieval = Invoke-RestMethod -Uri "$search/knowledgeBases/spo-knowledge-base/retrieve?api-version=2026-05-01-preview" `
        -Method Post -Headers $headers -ContentType 'application/json' -Body ($query | ConvertTo-Json -Depth 10 -Compress) `
        -TimeoutSec 120 -MaximumRedirection 0
    $texts = @($retrieval.response | ForEach-Object { $_.content } | ForEach-Object { $_.text } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $errors = @($retrieval.activity | Where-Object { $_.error -or $_.status -in @('failed', 'error') })
    if ($retrieval.error -or $errors.Count -or -not $texts.Count) { throw 'IQ retrieval failed or returned empty content.' }
    if (($texts -join "`n") -notmatch [regex]::Escape($ExpectedAnswer)) { throw 'IQ did not retrieve the expected fixture fact.' }
    $client = Join-Path $PSScriptRoot '..\..\src\hello_world\ask_agent.py'
    $global:LASTEXITCODE = 0
    $answer = & $PythonExecutable $client --project-endpoint $ProjectEndpoint --search-tool-name $SearchToolName `
        --model $ModelDeployment --question $Question 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $answer) { throw 'Native response failed the required IQ and toolbox validation.' }
    if (($answer -join "`n") -notmatch [regex]::Escape($ExpectedAnswer)) { throw 'Native answer did not contain the expected fixture fact.' }
    [pscustomobject]@{
        status = 'passed'
        request_id = $ingestion.request_id
        document_id = $ingestion.document_id
        content_hash = $ingestion.content_hash
        ingestion_path = 'authorized_function_to_search'
        provenance = 'matched'
        iq_retrieval = 'passed'
        native_dual_retrieval = 'passed'
        sharepoint = 'not_tested'
    }
}
finally {
    $headers.Clear()
    $identity = $null
    $answer = $null
}
