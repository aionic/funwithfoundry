[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$receiptDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ingestion-receipt-' + [guid]::NewGuid().ToString('N'))
$receiptPath = Join-Path $receiptDirectory 'native-datasource-receipt.json'
try {
$tlsBefore = [System.Net.ServicePointManager]::SecurityProtocol
$invokeScript = Join-Path $root 'scripts\jumpbox\Invoke-IngestFunction.ps1'
$parameters = @{ FunctionHostname = 'test-function.azurewebsites.net'; ApiClientId = '11111111-1111-1111-1111-111111111111' }
$state = @{ Status = 202; Body = $null; Calls = 0; FailureStatus = 0; Checks = 0; ProbeMode = $false; RerunMismatch = $false; FixtureCalls = 0; EndToEnd = $false }
$baseline = @{
    status = 'staged'; request_id = '22222222-2222-2222-8222-222222222222'; mode = 'fixture'
    source_id = ('a' * 64); content_hash = ('b' * 64); bytes = 123
    source_url = 'urn:funwithfoundry:fixture:accelerator-v1'
    blob_name = "native/$('a' * 64)/source.txt"
    blob_url = "https://stagingtest.blob.core.windows.net/spo-staging/native/$('a' * 64)/source.txt"
} | ConvertTo-Json -Compress
function az { throw 'Cloud CLI prohibited.' }
function terraform { throw 'Cloud CLI prohibited.' }
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)
    if ($PSBoundParameters['Verbose'] -ne $false -or $PSBoundParameters['Debug'] -ne $false) { throw 'HTTP logging must be suppressed.' }
    if ($Uri -notlike 'http://169.254.169.254/metadata/identity/oauth2/token?*') { throw 'Unexpected request.' }
    if ($MaximumRedirection -ne 0 -or $Headers.Metadata -ne 'true') { throw 'Unsafe IMDS request.' }
    if ($state.EndToEnd) { $flow.TokenRequests.Add($Uri) }
    return [pscustomobject]@{ access_token = 'DO-NOT-LEAK-TOKEN' }
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $ContentType, $Body, $MaximumRedirection, $TimeoutSec, [switch]$UseBasicParsing)
    if ($PSBoundParameters['Verbose'] -ne $false -or $PSBoundParameters['Debug'] -ne $false) { throw 'HTTP logging must be suppressed.' }
    if ($state.EndToEnd -and $Uri -cne 'https://test-function.azurewebsites.net/api/ingest') {
        return Invoke-MockedIngestionRequest @PSBoundParameters
    }
    $state.Calls++
    if ($Uri -cne 'https://test-function.azurewebsites.net/api/ingest' -or $Method -ne 'Post' -or $MaximumRedirection -ne 0) { throw 'Unexpected request.' }
    if ($state.EndToEnd) { $flow.IngestionRequests.Add(($Body | ConvertFrom-Json)) }
    if ($state.ProbeMode) {
        $payload = $Body | ConvertFrom-Json
        $status = $state.Status
        $responseBody = $state.Body | ConvertTo-Json -Compress | ConvertFrom-Json
        if (-not $Headers['Authorization'] -or $Headers['Authorization'] -eq 'Bearer invalid-token') { $status = 401 }
        elseif ($Headers['Authorization'] -eq 'Bearer denied-token') { $status = 403 }
        elseif ($payload.PSObject.Properties.Name -contains 'filePath') { $status = 400 }
        elseif ($payload.mode -eq 'sharepoint') { $responseBody.mode = 'sharepoint'; $responseBody.source_url = 'https://tenant.sharepoint.com/sites/test/file.pdf' }
        else {
            $state.FixtureCalls++
            if ($state.RerunMismatch -and $state.FixtureCalls -eq 2) { $responseBody.blob_url = $responseBody.blob_url.Replace('stagingtest', 'stagingother') }
        }
        return [pscustomobject]@{ StatusCode = $status; Content = ($responseBody | ConvertTo-Json -Compress) }
    }
    if ($state.FailureStatus) {
        $exception = New-Object System.Exception 'DO-NOT-LEAK-BODY'
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $state.FailureStatus })
        throw $exception
    }
    return [pscustomobject]@{ StatusCode = $state.Status; Content = ($state.Body | ConvertTo-Json -Compress) }
}
function Assert-Check {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw "Failed: $Label" }
    $state.Checks++
}
function Assert-StagingBlocked {
    param([string]$Label)
    $failure = ''
    try { $null = & $invokeScript @parameters -Confirm:$false } catch { $failure = $_.Exception.Message }
    Assert-Check (-not [string]::IsNullOrWhiteSpace($failure)) $Label
    Assert-Check ($failure -notmatch 'DO-NOT-LEAK') "$Label sanitization"
}
$state.Body = $baseline | ConvertFrom-Json
$result = & $invokeScript @parameters -Confirm:$false
Assert-Check ($result.status -ceq 'staged' -and $result.indexing -ceq 'not_tested') '202 stages without claiming indexing'
Assert-Check ($result.source_id -ceq $state.Body.source_id -and $result.blob_url -ceq $state.Body.blob_url) 'staging provenance returned'
Assert-Check ($result.PSObject.Properties.Name -notcontains 'document_id') 'no legacy document identity'
$state.Status = 200
Assert-StagingBlocked '200 rejected'
$state.Status = 202
foreach ($field in @('source_id', 'content_hash', 'source_url', 'blob_url', 'blob_name', 'bytes', 'mode', 'request_id')) {
    $state.Body = $baseline | ConvertFrom-Json
    $state.Body.PSObject.Properties.Remove($field)
    Assert-StagingBlocked "missing $field"
}
$state.Body = $baseline | ConvertFrom-Json
$state.Body.status = 'indexed'
Assert-StagingBlocked 'indexed rejected'
$state.Body = $baseline | ConvertFrom-Json
$state.Body.blob_url += '?sig=DO-NOT-LEAK'
Assert-StagingBlocked 'SAS URL rejected'
$state.FailureStatus = 403
Assert-StagingBlocked '403 rejected'
$state.FailureStatus = 0
$state.Calls = 0
$null = & $invokeScript @parameters -WhatIf
Assert-Check ($state.Calls -eq 0) 'WhatIf makes no Function call'
$probeScript = Join-Path $root 'scripts\jumpbox\Test-Ingestion.ps1'
$state.Body = $baseline | ConvertFrom-Json
$state.ProbeMode = $true
$probe = & $probeScript @parameters -AccessToken (ConvertTo-SecureString 'allowed-token' -AsPlainText -Force) `
    -DeniedAccessToken (ConvertTo-SecureString 'denied-token' -AsPlainText -Force) -IncludeSharePoint -Confirm:$false | ConvertFrom-Json
Assert-Check ($probe.status -ceq 'passed' -and $probe.checks.Count -eq 9 -and $probe.indexing -ceq 'not_tested') 'auth negatives and staging positives'
foreach ($check in $probe.checks) { Assert-Check ($check.status -ceq 'passed') $check.check }
$state.Status = 200
$probe = & $probeScript @parameters -Confirm:$false | ConvertFrom-Json
Assert-Check ($probe.status -ceq 'failed') 'probe rejects 200'
$state.Status = 202
foreach ($property in @('document_id', 'indexed')) {
    $state.Body = $baseline | ConvertFrom-Json
    $state.Body | Add-Member -NotePropertyName $property -NotePropertyValue $null
    Assert-StagingBlocked "forbidden property $property"
    $probe = & $probeScript @parameters -Confirm:$false | ConvertFrom-Json
    Assert-Check ($probe.status -ceq 'failed') "probe forbids $property"
}
$state.Body = $baseline | ConvertFrom-Json
$state.RerunMismatch = $true
$state.FixtureCalls = 0
$probe = & $probeScript @parameters -Confirm:$false | ConvertFrom-Json
Assert-Check ($probe.status -ceq 'failed' -and $probe.checks[6].status -ceq 'failed') 'stable identity includes blob URL'
$state.ProbeMode = $false
$global:LASTEXITCODE = 0

$endToEndScript = Join-Path $root 'scripts\jumpbox\Invoke-EndToEnd.ps1'
$endToEndParameters = $parameters.Clone()
$endToEndParameters.SearchEndpoint = 'https://test-search.search.windows.net'
$endToEndParameters.ProjectEndpoint = 'https://test.services.ai.azure.com/api/projects/test'
$endToEndParameters.SearchToolName = 'search_docs'
$endToEndParameters.ModelDeployment = 'gpt-4o'
$endToEndParameters.PythonExecutable = 'Invoke-MockedNativeClient'
$endToEndParameters.TimeoutSeconds = 30
$endToEndParameters.DataSourceReceiptPath = $receiptPath
$storageId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/stagingtest'
$endToEndParameters.StorageResourceId = $storageId
$ingestionIdentityId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/native-ingestion'
$endToEndParameters.IngestionIdentityResourceId = $ingestionIdentityId
$contractBaseline = @{
    contractVersion = 2; owner = 'accelerator-native-indexer'; apiVersion = '2026-08-01-preview'
    knowledgeSourceName = 'spo-native'; knowledgeBaseName = 'spo-native-knowledge-base'
    pipeline = @{ index = 'spo-native-index'; indexer = 'spo-native-indexer'; datasource = 'spo-native-datasource'; skillset = 'spo-native-skillset' }
} | ConvertTo-Json -Depth 5 -Compress
function Get-Content {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Raw)
    if ([IO.Path]::GetFullPath($LiteralPath) -ieq [IO.Path]::GetFullPath($endToEndParameters.DataSourceReceiptPath)) {
        return Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw
    }
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $root 'src\shared\native-ingestion.json'))
    if (-not $Raw -or [IO.Path]::GetFullPath($LiteralPath) -ine $expectedPath) { throw 'Unexpected contract path.' }
    if ($flow.ContractMode -eq 'missing') { throw 'DO-NOT-LEAK missing contract.' }
    if ($flow.ContractMode -eq 'malformed') { return '{DO-NOT-LEAK' }
    return $flow.Contract | ConvertTo-Json -Depth 10 -Compress
}
$fixtureBlobUrl = ($baseline | ConvertFrom-Json).blob_url
$resourceBaseline = @{
    'knowledgesources/spo-native' = @{
        name = 'spo-native'; kind = 'searchIndex'
        searchIndexParameters = @{ searchIndexName = 'spo-native-index' }
    }
    'indexers/spo-native-indexer' = @{
        name = 'spo-native-indexer'; dataSourceName = 'spo-native-datasource'; skillsetName = 'spo-native-skillset'; targetIndexName = 'spo-native-index'
        parameters = @{ configuration = @{ executionEnvironment = 'private' } }
    }
    'datasources/spo-native-datasource' = @{
        '@odata.etag' = '"datasource-created"'
        '@odata.context' = 'https://test-search.search.windows.net/$metadata#datasources/$entity'
        indexerPermissionOptions = @()
        name = 'spo-native-datasource'; type = 'azureblob'; credentials = @{ connectionString = "ResourceId=$storageId" }
        identity = @{ '@odata.type' = '#Microsoft.Azure.Search.DataUserAssignedIdentity'; userAssignedIdentity = $ingestionIdentityId }
        container = @{ name = 'spo-staging'; query = 'native/' }
    }
    'skillsets/spo-native-skillset' = @{
        name = 'spo-native-skillset'; indexProjections = @{
            parameters = @{ projectionMode = 'skipIndexingParentDocuments' }
            selectors = @(@{ targetIndexName = 'spo-native-index'; parentKeyFieldName = 'snippet_parent_id'
                mappings = @(@{ name = 'doc_url'; source = '/document/metadata_storage_path' }) })
        }
    }
    'indexes/spo-native-index' = @{
        name = 'spo-native-index'; fields = @(
            @{ name = 'snippet_id'; key = $true }, @{ name = 'snippet_parent_id' }, @{ name = 'snippet' }, @{ name = 'doc_url' }
            @{ name = 'snippet_vector'; retrievable = $true; dimensions = 3072 }
        )
    }
    'indexes/spo-native-index/docs/search' = @{
        '@odata.count' = 2
        value = @(
            @{ snippet_id = 'chunk-1'; snippet_parent_id = 'parent-1'; snippet = 'Project Cedar is owned by Morgan Example.'; doc_url = $fixtureBlobUrl; snippet_vector = @(0.1) * 3072 },
            @{ snippet_id = 'chunk-2'; snippet_parent_id = 'parent-1'; snippet = 'This is synthetic test content.'; doc_url = $fixtureBlobUrl; snippet_vector = @(0.2) * 3072 }
        )
    }
    'knowledgebases/spo-native-knowledge-base/retrieve' = @{
        response = @(@{ content = @(@{ text = 'Morgan Example owns Project Cedar.' }) }); activity = @(@{ status = 'success' })
        references = @(@{ knowledgeSourceName = 'spo-native'; docKey = 'chunk-1'; sourceData = @{ doc_url = $fixtureBlobUrl } })
    }
} | ConvertTo-Json -Depth 30 -Compress

function Reset-EndToEndFixture {
    foreach ($parameterName in @('Mode', 'Question', 'ExpectedAnswer')) { $endToEndParameters.Remove($parameterName) }
    $endToEndParameters.StorageResourceId = $storageId
    $endToEndParameters.IngestionIdentityResourceId = $ingestionIdentityId
    $endToEndParameters.DataSourceReceiptPath = $receiptPath
    if (Test-Path -LiteralPath $receiptDirectory) { Remove-Item -LiteralPath $receiptDirectory -Recurse -Force }
    $state.EndToEnd = $true
    $state.Body = $baseline | ConvertFrom-Json
    $state.Status = 202
    $state.FailureStatus = 0
    $script:flow = @{
        Now = [datetime]::Parse('2026-09-10T21:00:00Z').ToUniversalTime(); Submitted = $false; Posts = 0; Polls = 0
        ExistingPolls = 0; ProgressPolls = 1; Sleeps = 0; RunStatus = 202; Mode = 'success'; FailPath = ''; FailStatus = 403
        Resources = @{}; Calls = [System.Collections.Generic.List[object]]::new(); TokenRequests = [System.Collections.Generic.List[string]]::new()
        IngestionRequests = [System.Collections.Generic.List[object]]::new()
        HeadCount = 0; HeadStatus = 200; NativeCalls = 0; NativeExitCode = 0; NativeText = "=== Answer ===`nMorgan Example. [$fixtureBlobUrl]"
        NativeArguments = @(); IqQuestion = ''; BlobMutation = $null
        Contract = ($contractBaseline | ConvertFrom-Json); ContractMode = 'valid'
        Run = [pscustomobject]@{ status = 'success'; startTime = ''; endTime = ''; itemsProcessed = 1; itemsFailed = 0; errors = @(); errorMessage = $null }
        BlobHeaders = @{
            'x-ms-meta-source_id' = ('a' * 64); 'x-ms-meta-content_hash' = ('b' * 64); 'Content-Length' = '123'
            'Last-Modified' = 'Thu, 10 Sep 2026 21:00:00 GMT'; ETag = '"fixture-etag"'
        }
    }
    foreach ($property in ($resourceBaseline | ConvertFrom-Json).PSObject.Properties) { $flow.Resources[$property.Name] = $property.Value }
}
function Reset-EndToEndSharePoint {
    Reset-EndToEndFixture
    $endToEndParameters.Mode = 'sharepoint'
    $endToEndParameters.Question = 'Which team approves Harbor changes?'
    $endToEndParameters.ExpectedAnswer = 'Harbor Operations'
    $state.Body.mode = 'sharepoint'
    $state.Body.source_id = 'c' * 64
    $state.Body.content_hash = 'd' * 64
    $state.Body.source_url = 'https://tenant.sharepoint.com/sites/test/architecture.pdf'
    $state.Body.blob_name = "native/$($state.Body.source_id)/source.pdf"
    $state.Body.blob_url = "https://stagingtest.blob.core.windows.net/spo-staging/$($state.Body.blob_name)"
    $flow.BlobHeaders['x-ms-meta-source_id'] = $state.Body.source_id
    $flow.BlobHeaders['x-ms-meta-content_hash'] = $state.Body.content_hash
    foreach ($chunk in $flow.Resources['indexes/spo-native-index/docs/search'].value) {
        $chunk.doc_url = $state.Body.blob_url
        $chunk.snippet_id = $chunk.snippet_id.Replace('chunk-', 'sharepoint-chunk-')
        $chunk.snippet_parent_id = 'sharepoint-parent-1'
        $chunk.snippet = 'Harbor Operations approves Harbor changes.'
    }
    $iq = $flow.Resources['knowledgebases/spo-native-knowledge-base/retrieve']
    $iq.response[0].content[0].text = 'Harbor Operations approves Harbor changes.'
    $iq.references[0].docKey = 'sharepoint-chunk-1'
    $iq.references[0].sourceData.doc_url = $state.Body.blob_url
    $flow.NativeText = "=== Answer ===`nHarbor Operations. [$($state.Body.blob_url)]"
}
function Get-Date {
    if ($state.EndToEnd) { return $flow.Now }
    return Microsoft.PowerShell.Utility\Get-Date
}
function Start-Sleep {
    param([int]$Seconds)
    if (-not $state.EndToEnd) { throw 'Real waiting prohibited.' }
    $flow.Sleeps++
    $flow.Now = $flow.Now.AddSeconds($Seconds)
    if ($flow.Sleeps -gt 20) { throw 'Unbounded polling.' }
}
function Invoke-MockedNativeClient {
    $flow.NativeCalls++
    $flow.NativeArguments = @($args)
    $global:LASTEXITCODE = $flow.NativeExitCode
    return $flow.NativeText
}
function Throw-MockedHttpFailure {
    param([int]$StatusCode)
    $exception = New-Object System.Exception 'DO-NOT-LEAK-BODY'
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $StatusCode })
    throw $exception
}
function Invoke-MockedIngestionRequest {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing)
    if ($MaximumRedirection -ne 0 -or $TimeoutSec -lt 1 -or $TimeoutSec -gt 120 -or -not $UseBasicParsing -or
        $Headers['Authorization'] -cne 'Bearer DO-NOT-LEAK-TOKEN') { throw 'Unsafe request options.' }
    $flow.Calls.Add(@{ Uri = $Uri; Method = $Method; Body = $Body; Headers = $Headers.Clone() })
    if ($Uri -ceq $state.Body.blob_url -and $Method -eq 'Head') {
        if ($Headers['x-ms-version'] -cne '2023-11-03') { throw 'Missing Blob API version.' }
        $flow.HeadCount++
        if ($flow.BlobMutation) { & $flow.BlobMutation }
        if ($flow.HeadStatus -ne 200) { Throw-MockedHttpFailure $flow.HeadStatus }
        return [pscustomobject]@{ StatusCode = 200; Headers = $flow.BlobHeaders.Clone() }
    }
    if ($Uri -cnotmatch '^https://test-search\.search\.windows\.net/(?<path>[a-z]+/[a-z0-9_-]+(?:/(?:run|status|docs/search|retrieve))?)\?api-version=2026-08-01-preview\z') { throw 'Unscoped Search request.' }
    $path = $Matches.path
    if ($path -ceq $flow.FailPath) { Throw-MockedHttpFailure $flow.FailStatus }
    if ($path -ceq 'indexers/spo-native-indexer/run') {
        if ($Method -cne 'POST') { throw 'Run must POST.' }
        $flow.Posts++
        $flow.Submitted = $true
        $flow.Run.startTime = $flow.Now.ToString('o')
        $flow.Run.endTime = $flow.Now.ToString('o')
        if ($flow.RunStatus -eq 409) { Throw-MockedHttpFailure 409 }
        return [pscustomobject]@{ StatusCode = $flow.RunStatus; Content = '' }
    }
    if ($path -ceq 'indexers/spo-native-indexer/status') {
        $row = $flow.Run | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        if (-not $flow.Submitted) {
            $row.startTime = $flow.Now.AddMinutes(-10).ToString('o'); $row.endTime = $flow.Now.AddMinutes(-9).ToString('o')
            if ($flow.ExistingPolls -gt 0) { $flow.ExistingPolls--; $row.status = 'inProgress' }
        }
        else {
            $flow.Polls++
            if ($flow.Polls -le $flow.ProgressPolls) { $row.status = 'inProgress' }
            switch ($flow.Mode) {
                'old' { $row.startTime = $flow.Now.AddMinutes(-10).ToString('o'); $row.endTime = $flow.Now.AddMinutes(-9).ToString('o') }
                'empty' { $row = $null }
                'inProgress' { $row.status = 'inProgress' }
                'noEnd' { $row.endTime = $null }
                'badStart' { $row.startTime = 'not-a-timestamp' }
                'future' { $row.endTime = $flow.Now.AddMinutes(1).ToString('o') }
            }
        }
        $status = @{ status = 'running'; lastResult = $row; executionHistory = @() }
        if ($flow.Mode -eq 'history' -and $flow.Submitted) { $status.lastResult = $null; $status.executionHistory = @($row) }
        if ($flow.Mode -eq 'serviceError') { $status.status = 'error' }
        return [pscustomobject]@{ StatusCode = 200; Content = ($status | ConvertTo-Json -Depth 10 -Compress) }
    }
    if (-not $flow.Resources.ContainsKey($path)) { throw 'Unexpected resource.' }
    if ($path -ceq 'indexes/spo-native-index/docs/search') {
        $query = $Body | ConvertFrom-Json
        $expectedSelect = 'snippet_id,snippet_parent_id,snippet,doc_url'
        if ($flow.Resources['indexes/spo-native-index'].fields[4].retrievable) { $expectedSelect += ',snippet_vector' }
        if ($Method -cne 'POST' -or $query.filter -cne "doc_url eq '$($state.Body.blob_url)'" -or $query.top -ne 100 -or
            $query.count -ne $true -or $query.select -cne $expectedSelect -or $flow.HeadCount -ne 2) { throw 'Unsafe or premature document query.' }
    }
    elseif ($path -ceq 'knowledgebases/spo-native-knowledge-base/retrieve') {
        if ($Method -cne 'POST') { throw 'IQ must POST.' }
        $flow.IqQuestion = ($Body | ConvertFrom-Json).messages[0].content[0].text
    }
    elseif ($Method -cne 'GET') { throw 'Native resources must be read-only.' }
    return [pscustomobject]@{ StatusCode = 200; Content = ($flow.Resources[$path] | ConvertTo-Json -Depth 30 -Compress) }
}

function Assert-EndToEndBlocked {
    param([string]$Label, [string]$Pattern, [switch]$NoSummary)
    $failure = ''
    $output = [System.Collections.Generic.List[object]]::new()
    try { & $endToEndScript @endToEndParameters -Confirm:$false | ForEach-Object { $output.Add($_) } } catch { $failure = $_.Exception.Message }
    Assert-Check (-not [string]::IsNullOrWhiteSpace($failure)) $Label
    Assert-Check ($failure -notmatch 'DO-NOT-LEAK|Project Cedar') "$Label sanitized"
    Assert-Check ($failure -match $Pattern) "$Label expected blocker: $failure"
    Assert-Check ($flow.Posts -le 1) "$Label no repeated POST"
    if ($NoSummary) { Assert-Check ($output.Count -eq 0) "$Label emits no success summary" }
}

$initializerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Initialize-KnowledgeBase.ps1'), [ref]$null, [ref]$null)
$receiptHelpers = @(foreach ($name in @('Get-NativeProperty', 'Get-NativeDataSourceHash', 'Get-NativeDataSourceReceipt')) {
    $definition = $initializerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
    Assert-Check ($null -ne $definition) "Initializer receipt helper exists: $name"
    [scriptblock]::Create($definition.Extent.Text)
})
function Set-EndToEndReceipt {
    foreach ($helper in $receiptHelpers) { . $helper }
    $SearchEndpoint = $endToEndParameters.SearchEndpoint
    $StorageResourceId = $storageId
    $desired = $flow.Resources['datasources/spo-native-datasource'] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $desired.credentials.connectionString = "ResourceId=$storageId"
    $receipt = Get-NativeDataSourceReceipt $desired $flow.Resources['datasources/spo-native-datasource']
    $null = New-Item -Path $receiptDirectory -ItemType Directory -Force
    $receipt | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $receiptPath
}

Reset-EndToEndFixture
$result = & $endToEndScript @endToEndParameters -Confirm:$false
Assert-Check ($result.status -ceq 'passed' -and $result.indexing -ceq 'passed' -and $result.staging -ceq 'passed') 'native indexing proof'
Assert-Check ($result.chunk_count -eq 2 -and $result.chunk_set_complete -eq $true) 'complete child set'
Assert-Check ($result.indexer -ceq 'spo-native-indexer' -and $flow.Posts -eq 1 -and $flow.Polls -eq 2) 'explicit native indexer single POST and bounded poll'
Assert-Check ($result.blob_metadata -ceq 'matched' -and $flow.HeadCount -eq 2) 'metadata provenance before run and query'
Assert-Check ($result.sharepoint -ceq 'not_tested' -and $result.vector_validation -ceq '3072_dimensions') 'explicit validation boundaries'
Assert-Check ($flow.NativeArguments -ccontains $flow.IqQuestion) 'same scoped question for IQ and native'
Assert-Check (@($flow.TokenRequests | Where-Object { $_ -like '*https%3A%2F%2Fstorage.azure.com%2F*' }).Count -eq 2) 'storage managed identity token'
Assert-Check (@($flow.Calls | Where-Object { $_.Method -eq 'Head' -and $_.Headers['If-Match'] -eq '"fixture-etag"' }).Count -eq 1) 'blob concurrency precondition'
$summaryJson = $result | ConvertTo-Json -Compress
Assert-Check ([System.Text.Encoding]::UTF8.GetByteCount($summaryJson) -le 3072 -and $summaryJson -notmatch 'DO-NOT-LEAK|snippet_vector|Morgan Example|document_id') 'compact summary without raw data'

$modeChecksBefore = $state.Checks
Assert-Check ($result.mode -ceq 'fixture' -and $flow.IngestionRequests.Count -eq 1 -and
    $flow.IngestionRequests[0].mode -ceq 'fixture' -and $flow.IngestionRequests[0].fixtureId -ceq 'accelerator-v1') 'default fixture request remains backward compatible'
Reset-EndToEndFixture
$endToEndParameters.Mode = 'fixture'
$endToEndParameters.Question = 'Name the Cedar owner.'
$endToEndParameters.ExpectedAnswer = 'Morgan'
$result = & $endToEndScript @endToEndParameters -Confirm:$false
Assert-Check ($result.status -ceq 'passed' -and $result.mode -ceq 'fixture' -and $result.sharepoint -ceq 'not_tested') 'explicit fixture mode and custom fact never claim SharePoint'

foreach ($receiptMode in @('visible', 'redacted')) {
    Reset-EndToEndSharePoint
    if ($receiptMode -eq 'redacted') {
        Set-EndToEndReceipt
        $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
    }
    $result = & $endToEndScript @endToEndParameters -Confirm:$false
    Assert-Check ($result.status -ceq 'passed' -and $result.mode -ceq 'sharepoint' -and $result.sharepoint -ceq 'passed') 'SharePoint passes only after all proofs'
    Assert-Check ($flow.IngestionRequests.Count -eq 1 -and $flow.IngestionRequests[0].mode -ceq 'sharepoint' -and
        $flow.IngestionRequests[0].PSObject.Properties.Name -notcontains 'fixtureId') 'SharePoint mode forwarded without fixture ID'
    Assert-Check ($result.source_url -ceq $state.Body.source_url -and $result.source_id -ceq $state.Body.source_id -and
        $result.content_hash -ceq $state.Body.content_hash -and $result.blob_url -cne $fixtureBlobUrl) 'SharePoint summary carries distinct staged-source provenance'
    Assert-Check ($result.staging -ceq 'passed' -and $result.blob_metadata -ceq 'matched' -and $flow.HeadCount -eq 2 -and
        $flow.Posts -eq 1 -and $flow.Polls -eq 2 -and $result.indexing -ceq 'passed') 'SharePoint requires blob metadata and a fresh completed indexer run'
    Assert-Check ($result.chunk_set_complete -eq $true -and $result.chunk_count -eq 2 -and
        $result.vector_validation -ceq '3072_dimensions') 'SharePoint retains complete child and vector proof'
    $expectedQuestion = "$($endToEndParameters.Question)`nUse the staged document at $($state.Body.blob_url). Include its exact doc_url or snippet_id in the answer."
    Assert-Check ($flow.IqQuestion -ceq $expectedQuestion -and $flow.NativeArguments -ccontains $expectedQuestion -and
        $flow.NativeArguments -cnotcontains '--allow-partial' -and $flow.NativeCalls -eq 1 -and
        $result.iq_retrieval -ceq 'passed' -and $result.native_dual_retrieval -ceq 'passed') 'SharePoint question remains source scoped for IQ and strict native retrieval'
    Assert-Check (($receiptMode -eq 'redacted' -and $result.datasource_receipt_status -ceq 'matched') -or
        ($receiptMode -eq 'visible' -and $result.datasource_receipt_status -ceq 'not-required')) 'SharePoint retains receipt semantics'
    $summaryJson = $result | ConvertTo-Json -Compress
    Assert-Check ([Text.Encoding]::UTF8.GetByteCount($summaryJson) -le 3072 -and
        $summaryJson -notmatch 'Harbor Operations|DO-NOT-LEAK|snippet_vector') 'SharePoint summary stays bounded without raw facts'
}

Reset-EndToEndSharePoint
$endToEndParameters.Remove('Question')
$endToEndParameters.Remove('ExpectedAnswer')
$functionCalls = $state.Calls
Assert-EndToEndBlocked 'SharePoint cannot inherit fixture defaults' 'SharePoint.*explicit.*Question.*ExpectedAnswer' -NoSummary
Assert-Check ($state.Calls -eq $functionCalls -and $flow.TokenRequests.Count -eq 0 -and $flow.Calls.Count -eq 0) 'missing SharePoint inputs rejected before network access'
foreach ($field in @('Question', 'ExpectedAnswer')) {
    foreach ($inputMode in @('omitted', 'empty', 'whitespace', 'null')) {
        Reset-EndToEndSharePoint
        switch ($inputMode) {
            'omitted' { $endToEndParameters.Remove($field) }
            'empty' { $endToEndParameters[$field] = '' }
            'whitespace' { $endToEndParameters[$field] = " `t`r`n" }
            'null' { $endToEndParameters[$field] = $null }
        }
        $functionCalls = $state.Calls
        Assert-EndToEndBlocked "SharePoint $field $inputMode" $field -NoSummary
        Assert-Check ($state.Calls -eq $functionCalls -and $flow.TokenRequests.Count -eq 0 -and $flow.Calls.Count -eq 0) 'explicit nonempty SharePoint inputs required before network access'
    }
}
Reset-EndToEndFixture
$endToEndParameters.Mode = 'other'
$functionCalls = $state.Calls
Assert-EndToEndBlocked 'invalid verification mode' 'Mode' -NoSummary
Assert-Check ($state.Calls -eq $functionCalls -and $flow.TokenRequests.Count -eq 0) 'invalid mode rejected before staging'
Reset-EndToEndFixture
$state.Body.mode = 'sharepoint'
Assert-EndToEndBlocked 'fixture rejects SharePoint staging response' 'staging failed' -NoSummary
Assert-Check ($flow.IngestionRequests[0].mode -ceq 'fixture' -and $flow.Calls.Count -eq 0 -and $flow.NativeCalls -eq 0) 'fixture mode mismatch never reaches indexing or retrieval'

foreach ($failureMode in @('graph-403', 'graph-502', 'staging-mode', 'receipt', 'blob-hash', 'blob-etag', 'indexer',
    'chunks', 'chunks-fact', 'iq-http', 'iq-fact', 'iq-activity', 'iq-mixed-reference', 'iq-mixed-id', 'native', 'native-fact', 'native-source')) {
    Reset-EndToEndSharePoint
    $iq = $flow.Resources['knowledgebases/spo-native-knowledge-base/retrieve']
    switch ($failureMode) {
        'graph-403' { $state.FailureStatus = 403 }
        'graph-502' { $state.FailureStatus = 502 }
        'staging-mode' { $state.Body.mode = 'fixture' }
        'receipt' { $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null }
        'blob-hash' { $flow.BlobHeaders['x-ms-meta-content_hash'] = 'b' * 64 }
        'blob-etag' { $flow.BlobMutation = { if ($flow.HeadCount -eq 2) { $flow.BlobHeaders.ETag = '"changed-etag"' } } }
        'indexer' { $flow.Run.itemsProcessed = 0 }
        'chunks' { $flow.Resources['indexes/spo-native-index/docs/search'].'@odata.count' = 101 }
        'chunks-fact' { foreach ($chunk in $flow.Resources['indexes/spo-native-index/docs/search'].value) { $chunk.snippet = 'Morgan Example owns Project Cedar.' } }
        'iq-http' { $flow.FailPath = 'knowledgebases/spo-native-knowledge-base/retrieve' }
        'iq-fact' { $iq.response[0].content[0].text = 'Morgan Example owns Project Cedar.' }
        'iq-activity' { $iq.activity[0].status = 'failed' }
        'iq-mixed-reference' { $iq.references += [pscustomobject]@{ knowledgeSourceName = 'spo-native'; docKey = 'chunk-1'; sourceData = @{ doc_url = $fixtureBlobUrl } } }
        'iq-mixed-id' { $iq.references += [pscustomobject]@{ knowledgeSourceName = 'spo-native'; docKey = 'chunk-1' } }
        'native' { $flow.NativeExitCode = 1; $flow.NativeText = 'DO-NOT-LEAK-BODY' }
        'native-fact' { $flow.NativeText = "=== Answer ===`nMorgan Example. [$($state.Body.blob_url)]" }
        'native-source' { $flow.NativeText = "=== Answer ===`nHarbor Operations. [$fixtureBlobUrl]" }
    }
    Assert-EndToEndBlocked "SharePoint $failureMode" 'staging failed|receipt|blob provenance|completed run|chunks|IQ|HTTP 403|Native' -NoSummary
    Assert-Check ($flow.IngestionRequests.Count -eq 1 -and $flow.IngestionRequests[0].mode -ceq 'sharepoint') 'failed SharePoint proof never falls back to fixture staging'
    if ($failureMode -notlike 'native*') { Assert-Check ($flow.NativeCalls -eq 0) 'failed SharePoint prerequisite blocks native retrieval' }
}
Reset-EndToEndSharePoint
$functionCalls = $state.Calls
$null = & $endToEndScript @endToEndParameters -WhatIf
Assert-Check ($state.Calls -eq $functionCalls -and $flow.Calls.Count -eq 0 -and $flow.TokenRequests.Count -eq 0) 'SharePoint WhatIf makes no network requests'
$verificationModeChecks = $state.Checks - $modeChecksBefore

Reset-EndToEndFixture
Set-EndToEndReceipt
$flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
$result = & $endToEndScript @endToEndParameters -Confirm:$false
Assert-Check ($result.status -ceq 'passed' -and $result.datasource_receipt_status -ceq 'matched') 'Initializer receipt permits redacted credential proof.'
Assert-Check ($flow.HeadCount -eq 2 -and $flow.Posts -eq 1 -and $flow.Polls -eq 2 -and $flow.NativeCalls -eq 1) 'Receipt does not replace blob, fresh indexer or retrieval proof.'
Assert-Check ($result.chunk_set_complete -eq $true -and $result.chunk_count -eq 2) 'Receipt retains complete chunk proof.'
Assert-Check (@($flow.Calls | Where-Object Method -in @('PUT', 'PATCH', 'DELETE')).Count -eq 0) 'Verification never alters native resource definitions.'

foreach ($mode in @('blob', 'indexer', 'chunks')) {
    Reset-EndToEndFixture
    Set-EndToEndReceipt
    $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
    switch ($mode) {
        'blob' { $flow.HeadStatus = 403 }
        'indexer' { $flow.Run.itemsProcessed = 0 }
        'chunks' { $flow.Resources['indexes/spo-native-index/docs/search'].value = @() }
    }
    Assert-EndToEndBlocked "receipt still requires $mode proof" 'blob provenance|completed run|chunks'
    Assert-Check ($flow.NativeCalls -eq 0) 'Receipt cannot bypass failed provenance or ingestion proof.'
}

foreach ($mode in @('missing', 'malformed', 'directory', 'etag-changed', 'etag-missing', 'etag-wildcard', 'credential-missing', 'credentials-missing')) {
    Reset-EndToEndFixture
    Set-EndToEndReceipt
    $datasource = $flow.Resources['datasources/spo-native-datasource']
    $datasource.credentials.connectionString = $null
    switch ($mode) {
        'missing' { Remove-Item -LiteralPath $receiptPath -Force }
        'malformed' { Set-Content -LiteralPath $receiptPath -Value '{DO-NOT-LEAK' }
        'directory' { $endToEndParameters.DataSourceReceiptPath = $receiptDirectory }
        'etag-changed' { $datasource.'@odata.etag' = '"changed"' }
        'etag-missing' { $datasource.PSObject.Properties.Remove('@odata.etag') }
        'etag-wildcard' { $datasource.'@odata.etag' = '*' }
        'credential-missing' { $datasource.credentials.PSObject.Properties.Remove('connectionString') }
        'credentials-missing' { $datasource.PSObject.Properties.Remove('credentials') }
    }
    Assert-EndToEndBlocked "redacted $mode" 'receipt|scope'
    Assert-Check ($flow.HeadCount -eq 0 -and $flow.Posts -eq 0 -and $flow.NativeCalls -eq 0) 'Unbound null credentials block before proof.'
}
foreach ($field in @('receipt_version', 'search_endpoint', 'datasource', 'storage_resource_id', 'staging_container', 'folder_path', 'ingestion_identity_resource_id', 'desired_config_sha256', 'server_etag')) {
    foreach ($mutation in @('wrong', 'missing', 'array')) {
        Reset-EndToEndFixture
        Set-EndToEndReceipt
        $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        switch ($mutation) {
            'wrong' { $receipt.$field = 'wrong' }
            'missing' { $receipt.PSObject.Properties.Remove($field) }
            'array' { $receipt.$field = @($receipt.$field) }
        }
        $receipt | ConvertTo-Json -Compress | Set-Content -LiteralPath $receiptPath
        Assert-EndToEndBlocked "receipt $field $mutation" 'receipt'
        Assert-Check ($flow.Posts -eq 0 -and $flow.HeadCount -eq 0) 'Receipt mismatch blocks before HEAD or indexing.'
    }
}
foreach ($field in @('StorageResourceId', 'IngestionIdentityResourceId')) {
    foreach ($mutation in @('omitted', 'empty', 'invalid', 'different')) {
        Reset-EndToEndFixture
        Set-EndToEndReceipt
        $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
        switch ($mutation) {
            'omitted' { $endToEndParameters.Remove($field) }
            'empty' { $endToEndParameters[$field] = '' }
            'invalid' { $endToEndParameters[$field] = 'https://foreign.invalid/DO-NOT-LEAK' }
            'different' { $endToEndParameters[$field] += 'other' }
        }
        Assert-EndToEndBlocked "explicit $field $mutation" 'receipt|scope'
        Assert-Check ($flow.Posts -eq 0 -and $flow.HeadCount -eq 0) 'Explicit intended IDs required for redacted credentials.'
    }
}
Reset-EndToEndFixture
Set-EndToEndReceipt
$flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
$receiptLink = Join-Path $receiptDirectory 'link'
$null = New-Item -Path $receiptLink -ItemType Junction -Target $receiptDirectory
$endToEndParameters.DataSourceReceiptPath = Join-Path $receiptLink 'native-datasource-receipt.json'
Assert-EndToEndBlocked 'linked receipt path' 'receipt'
Assert-Check ($flow.Posts -eq 0 -and $flow.HeadCount -eq 0) 'Linked receipt rejected before proof.'
[IO.Directory]::Delete($receiptLink)

foreach ($mode in @('missing', 'malformed')) {
    Reset-EndToEndFixture
    $flow.ContractMode = $mode
    $functionCalls = $state.Calls
    Assert-EndToEndBlocked "$mode contract" 'contract is missing or malformed'
    Assert-Check ($state.Calls -eq $functionCalls -and $flow.Calls.Count -eq 0 -and $flow.TokenRequests.Count -eq 0) "$mode contract fails before network access"
}
$contractMutations = [ordered]@{
    'old version' = { $flow.Contract.contractVersion = 1 }
    'string version' = { $flow.Contract.contractVersion = '2' }
    'missing version' = { $flow.Contract.PSObject.Properties.Remove('contractVersion') }
    'wrong owner' = { $flow.Contract.owner = 'provider' }
    'missing owner' = { $flow.Contract.PSObject.Properties.Remove('owner') }
    'array owner' = { $flow.Contract.owner = @('accelerator-native-indexer') }
    'wrong API version' = { $flow.Contract.apiVersion = '2025-11-01-preview' }
    'wrong source name' = { $flow.Contract.knowledgeSourceName = 'other-source' }
    'array source name' = { $flow.Contract.knowledgeSourceName = @('spo-native') }
    'wrong KB name' = { $flow.Contract.knowledgeBaseName = 'other-kb' }
    'array KB name' = { $flow.Contract.knowledgeBaseName = @('spo-native-knowledge-base') }
    'missing pipeline' = { $flow.Contract.PSObject.Properties.Remove('pipeline') }
    'malformed pipeline' = { $flow.Contract.pipeline = 'spo-native' }
    'null contract' = { $flow.Contract = $null }
}
foreach ($entry in $contractMutations.GetEnumerator()) {
    Reset-EndToEndFixture
    & $entry.Value
    $functionCalls = $state.Calls
    Assert-EndToEndBlocked $entry.Key 'contract'
    Assert-Check ($state.Calls -eq $functionCalls -and $flow.Calls.Count -eq 0 -and $flow.TokenRequests.Count -eq 0) "$($entry.Key) fails before network access"
}
foreach ($field in @('index', 'indexer', 'skillset', 'datasource')) {
    foreach ($invalidName in @($null, '', '../other', 'https://foreign.invalid', 'other-resource', "SPO-NATIVE-$field", @("spo-native-$field"))) {
        Reset-EndToEndFixture
        $flow.Contract.pipeline.$field = $invalidName
        Assert-EndToEndBlocked "invalid pipeline $field name" 'contract.*resource name'
        Assert-Check ($flow.Calls.Count -eq 0 -and $flow.TokenRequests.Count -eq 0) 'invalid resource names never form a request'
    }
    Reset-EndToEndFixture
    $flow.Contract.pipeline.PSObject.Properties.Remove($field)
    Assert-EndToEndBlocked "missing pipeline $field name" 'contract.*resource name'
}
Reset-EndToEndFixture
$flow.Resources['datasources/spo-native-datasource'].credentials.connectionString += ';'
$result = & $endToEndScript @endToEndParameters -Confirm:$false
Assert-Check ($result.status -ceq 'passed') 'keyless ResourceId accepts one trailing delimiter'

foreach ($mappingFunction in @('omitted', 'null')) {
    Reset-EndToEndFixture
    $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings[0].source = '/document/doc_url'
    $fieldMapping = [pscustomobject]@{ sourceFieldName = 'metadata_storage_path'; targetFieldName = 'doc_url' }
    if ($mappingFunction -eq 'null') { $fieldMapping | Add-Member mappingFunction $null }
    $flow.Resources['indexers/spo-native-indexer'] | Add-Member fieldMappings @(
        $fieldMapping, [pscustomobject]@{ sourceFieldName = 'doc_url'; targetFieldName = 'originalURL' }
    )
    $flow.Resources['indexes/spo-native-index'].fields += [pscustomobject]@{ name = 'originalURL'; type = 'Edm.String'; retrievable = $true }
    $flow.BlobHeaders['x-ms-meta-doc_url'] = 'https://tenant.sharepoint.com/sites/test/original.txt'
    $unchangedResources = $flow.Resources | ConvertTo-Json -Depth 30 -Compress
    $result = & $endToEndScript @endToEndParameters -Confirm:$false
    Assert-Check ($result.status -ceq 'passed' -and $result.search_provenance -ceq 'staged_blob_url_and_child_ids') "mapped doc_url with $mappingFunction mappingFunction"
    Assert-Check ($flow.HeadCount -eq 2 -and $flow.Posts -eq 1 -and $flow.NativeCalls -eq 1) 'alternate URL still requires blob HEAD, indexing and retrieval'
    Assert-Check (($flow.Resources | ConvertTo-Json -Depth 30 -Compress) -ceq $unchangedResources) 'URL verification leaves native resources intact'
    Assert-Check ($flow.BlobHeaders['x-ms-meta-doc_url'] -ceq 'https://tenant.sharepoint.com/sites/test/original.txt') 'original blob URL metadata retained separately'
}

Reset-EndToEndFixture
$flow.Resources['indexes/spo-native-index'].fields[4].retrievable = $false
foreach ($chunk in $flow.Resources['indexes/spo-native-index/docs/search'].value) { $chunk.PSObject.Properties.Remove('snippet_vector') }
$result = & $endToEndScript @endToEndParameters -Confirm:$false
Assert-Check ($result.vector_validation -ceq 'not_retrievable') 'non-retrievable vectors are not requested or claimed'
Reset-EndToEndFixture
$flow.ExistingPolls = 1
$result = & $endToEndScript @endToEndParameters -Confirm:$false
Assert-Check ($flow.Posts -eq 1 -and $flow.Sleeps -eq 2 -and $result.indexing -ceq 'passed') 'existing run awaited before own POST'
Reset-EndToEndFixture
$flow.Mode = 'history'
$result = & $endToEndScript @endToEndParameters -Confirm:$false
Assert-Check ($result.indexing -ceq 'passed') 'fresh completed history entry accepted'

$resourceMutations = [ordered]@{
    'wrong source kind' = { $flow.Resources['knowledgesources/spo-native'].kind = 'azureBlob' }
    'legacy Blob parameters' = { $flow.Resources['knowledgesources/spo-native'] | Add-Member azureBlobParameters ([pscustomobject]@{ createdResources = @{ index = 'spo-native-index' } }) }
    'legacy created resources' = { $flow.Resources['knowledgesources/spo-native'] | Add-Member createdResources ([pscustomobject]@{ index = 'spo-native-index' }) }
    'missing source index' = { $flow.Resources['knowledgesources/spo-native'].PSObject.Properties.Remove('searchIndexParameters') }
    'wrong child index' = { $flow.Resources['knowledgesources/spo-native'].searchIndexParameters.searchIndexName = 'spo-docs' }
    'foreign storage' = { $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = "ResourceId=$($storageId.Replace('stagingtest', 'stagingother'))" }
    'redacted scope' = { $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = '<REDACTED>' }
    'missing credentials' = { $flow.Resources['datasources/spo-native-datasource'].PSObject.Properties.Remove('credentials') }
    'keyed credentials' = { $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = 'AccountName=stagingtest;AccountKey=DO-NOT-LEAK' }
    'credential suffix' = { $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString += ';AccountKey=DO-NOT-LEAK' }
    'missing identity' = { $flow.Resources['datasources/spo-native-datasource'].PSObject.Properties.Remove('identity') }
    'wrong identity type' = { $flow.Resources['datasources/spo-native-datasource'].identity.'@odata.type' = '#Microsoft.Azure.Search.DataNoneIdentity' }
    'wrong identity' = { $flow.Resources['datasources/spo-native-datasource'].identity.userAssignedIdentity += '-other' }
    'foreign identity' = { $flow.Resources['datasources/spo-native-datasource'].identity.userAssignedIdentity = $ingestionIdentityId.Replace('11111111', '22222222') }
    'identity URL' = { $flow.Resources['datasources/spo-native-datasource'].identity.userAssignedIdentity = 'https://foreign.invalid' }
    'container scope' = { $flow.Resources['datasources/spo-native-datasource'].container.name = 'other' }
    'folder scope' = { $flow.Resources['datasources/spo-native-datasource'].container.query = '' }
    'missing container' = { $flow.Resources['datasources/spo-native-datasource'].PSObject.Properties.Remove('container') }
    'public indexer' = { $flow.Resources['indexers/spo-native-indexer'].parameters.configuration.executionEnvironment = 'standard' }
    'disabled indexer' = { $flow.Resources['indexers/spo-native-indexer'] | Add-Member disabled $true }
    'wrong datasource type' = { $flow.Resources['datasources/spo-native-datasource'].type = 'adlsgen2' }
    'wrong datasource link' = { $flow.Resources['indexers/spo-native-indexer'].dataSourceName = 'other' }
    'wrong skillset link' = { $flow.Resources['indexers/spo-native-indexer'].skillsetName = 'other' }
    'wrong index link' = { $flow.Resources['indexers/spo-native-indexer'].targetIndexName = 'other' }
    'wrong datasource scope' = { $flow.Resources['datasources/spo-native-datasource'].container.query = 'other/' }
    'wrong parent projection' = { $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].parentKeyFieldName = 'source_id' }
    'original URL projection' = { $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings[0].source = '/document/source_url' }
    'missing URL projection source' = { $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings[0].PSObject.Properties.Remove('source') }
    'duplicate URL projection' = { $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings += [pscustomobject]@{ name = 'doc_url'; source = '/document/metadata_storage_path' } }
    'URL projection transform' = { $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings[0] | Add-Member mappingFunction ([pscustomobject]@{ name = 'base64Encode' }) }
    'URL projection context' = { $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings[0] | Add-Member sourceContext '/document/other/*' }
    'URL projection inputs' = { $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings[0] | Add-Member inputs @([pscustomobject]@{ name = 'value'; source = '/document/source_url' }) }
    'direct URL field mapping wrong source' = { $flow.Resources['indexers/spo-native-indexer'] | Add-Member fieldMappings @([pscustomobject]@{ sourceFieldName = 'doc_url'; targetFieldName = 'doc_url' }) }
    'direct URL field mapping transform' = { $flow.Resources['indexers/spo-native-indexer'] | Add-Member fieldMappings @([pscustomobject]@{ sourceFieldName = 'metadata_storage_path'; targetFieldName = 'doc_url'; mappingFunction = [pscustomobject]@{ name = 'base64Encode' } }) }
}
foreach ($entry in $resourceMutations.GetEnumerator()) {
    Reset-EndToEndFixture
    & $entry.Value
    Assert-EndToEndBlocked $entry.Key 'source|scope|private|resource|projection|doc_url|index'
    Assert-Check ($flow.Posts -eq 0) "$($entry.Key) blocked before indexer run"
    Reset-EndToEndFixture
    Set-EndToEndReceipt
    $flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
    & $entry.Value
    Assert-EndToEndBlocked "receipt with $($entry.Key)" 'source|scope|private|resource|projection|doc_url|index'
    Assert-Check ($flow.Posts -eq 0) 'Receipt never overrides visible-field drift.'
}
$urlMutations = [ordered]@{
    'missing field mappings' = { $flow.Resources['indexers/spo-native-indexer'].PSObject.Properties.Remove('fieldMappings') }
    'empty field mappings' = { $flow.Resources['indexers/spo-native-indexer'].fieldMappings = @() }
    'wrong source' = { $flow.Resources['indexers/spo-native-indexer'].fieldMappings[0].sourceFieldName = 'doc_url' }
    'missing source' = { $flow.Resources['indexers/spo-native-indexer'].fieldMappings[0].PSObject.Properties.Remove('sourceFieldName') }
    'wrong target' = { $flow.Resources['indexers/spo-native-indexer'].fieldMappings[0].targetFieldName = 'originalURL' }
    'transformed source' = { $flow.Resources['indexers/spo-native-indexer'].fieldMappings[0] | Add-Member mappingFunction ([pscustomobject]@{ name = 'base64Encode' }) }
    'duplicate target' = { $flow.Resources['indexers/spo-native-indexer'].fieldMappings += [pscustomobject]@{ sourceFieldName = 'metadata_storage_path'; targetFieldName = 'doc_url' } }
}
foreach ($entry in $urlMutations.GetEnumerator()) {
    Reset-EndToEndFixture
    $flow.Resources['skillsets/spo-native-skillset'].indexProjections.selectors[0].mappings[0].source = '/document/doc_url'
    $flow.Resources['indexers/spo-native-indexer'] | Add-Member fieldMappings @([pscustomobject]@{ sourceFieldName = 'metadata_storage_path'; targetFieldName = 'doc_url' })
    & $entry.Value
    Assert-EndToEndBlocked "mapped document URL $($entry.Key)" 'doc_url.*field mapping'
    Assert-Check ($flow.Posts -eq 0 -and $flow.HeadCount -eq 0 -and $flow.NativeCalls -eq 0) 'unproven URL binding blocked before indexing or retrieval'
}
foreach ($mode in @('old', 'empty', 'inProgress', 'noEnd', 'badStart', 'future', 'serviceError')) {
    Reset-EndToEndFixture
    $flow.Mode = $mode
    Assert-EndToEndBlocked "poll $mode" 'deadline|timestamp|completed run|not available'
    Assert-Check ($flow.NativeCalls -eq 0) "poll $mode blocks retrieval"
}
foreach ($field in @('status', 'itemsProcessed', 'itemsFailed', 'errors', 'errorMessage')) {
    Reset-EndToEndFixture
    switch ($field) {
        'status' { $flow.Run.status = 'transientFailure' }
        'itemsProcessed' { $flow.Run.itemsProcessed = 0 }
        'itemsFailed' { $flow.Run.itemsFailed = 1 }
        'errors' { $flow.Run.errors = @(@{ message = 'DO-NOT-LEAK-BODY' }) }
        'errorMessage' { $flow.Run.errorMessage = 'DO-NOT-LEAK-BODY' }
    }
    Assert-EndToEndBlocked "run $field" 'execution|completed run'
}
foreach ($statusCode in @(200, 409)) {
    Reset-EndToEndFixture
    $flow.RunStatus = $statusCode
    Assert-EndToEndBlocked "POST $statusCode" "HTTP $statusCode"
    Assert-Check ($flow.Posts -eq 1) "POST $statusCode never retried"
}
foreach ($header in @('x-ms-meta-source_id', 'x-ms-meta-content_hash', 'Content-Length', 'Last-Modified', 'ETag')) {
    Reset-EndToEndFixture
    $flow.BlobHeaders[$header] = ''
    Assert-EndToEndBlocked "blob $header" 'blob provenance'
    Assert-Check ($flow.Posts -eq 0) "blob $header blocks indexing"
}
Reset-EndToEndFixture
$flow.BlobMutation = { if ($flow.HeadCount -eq 2) { $flow.BlobHeaders.ETag = '"changed-etag"' } }
Assert-EndToEndBlocked 'blob changed during run' 'blob provenance'
Reset-EndToEndFixture
$flow.HeadStatus = 403
Assert-EndToEndBlocked 'blob HTTP 403' 'HTTP 403'
foreach ($path in @('knowledgesources/spo-native', 'indexers/spo-native-indexer/status', 'indexes/spo-native-index/docs/search', 'knowledgebases/spo-native-knowledge-base/retrieve')) {
    Reset-EndToEndFixture
    $flow.FailPath = $path
    Assert-EndToEndBlocked "Search 403 $path" 'HTTP 403'
}
$chunkMutations = [ordered]@{
    'no indexed chunks' = { $flow.Resources['indexes/spo-native-index/docs/search'].value = @(); $flow.Resources['indexes/spo-native-index/docs/search'].'@odata.count' = 0 }
    'empty snippet' = { $flow.Resources['indexes/spo-native-index/docs/search'].value[0].snippet = '' }
    'missing parent' = { $flow.Resources['indexes/spo-native-index/docs/search'].value[0].snippet_parent_id = '' }
    'wrong URL' = { $flow.Resources['indexes/spo-native-index/docs/search'].value[0].doc_url = 'urn:funwithfoundry:fixture:accelerator-v1' }
    'wrong vector size' = { $flow.Resources['indexes/spo-native-index/docs/search'].value[0].snippet_vector = @(0.1) * 1536 }
    'wrong fact' = { $flow.Resources['indexes/spo-native-index/docs/search'].value[0].snippet = 'Unrelated document.' }
    'duplicate key' = { $flow.Resources['indexes/spo-native-index/docs/search'].value[1].snippet_id = 'chunk-1' }
    'multiple parents' = { $flow.Resources['indexes/spo-native-index/docs/search'].value[1].snippet_parent_id = 'parent-2' }
    'truncated count' = { $flow.Resources['indexes/spo-native-index/docs/search'].'@odata.count' = 101 }
    'continuation link' = { $flow.Resources['indexes/spo-native-index/docs/search'] | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue 'https://foreign.invalid' }
    'continuation parameters' = { $flow.Resources['indexes/spo-native-index/docs/search'] | Add-Member -NotePropertyName '@search.nextPageParameters' -NotePropertyValue @{ skip = 100 } }
}
foreach ($entry in $chunkMutations.GetEnumerator()) {
    Reset-EndToEndFixture
    & $entry.Value
    Assert-EndToEndBlocked $entry.Key 'chunks|snippet|parent|vector'
    Assert-Check ($flow.NativeCalls -eq 0) "$($entry.Key) blocks native retrieval"
}
foreach ($mode in @('iq-empty', 'iq-fact', 'iq-source', 'iq-id', 'iq-error', 'native-error', 'native-fact', 'native-source', 'native-prefix')) {
    Reset-EndToEndFixture
    $iq = $flow.Resources['knowledgebases/spo-native-knowledge-base/retrieve']
    switch ($mode) {
        'iq-empty' { $iq.response = @() }
        'iq-fact' { $iq.response[0].content[0].text = 'Another person.' }
        'iq-source' { $iq.references[0].sourceData.doc_url = 'https://foreign.invalid/document' }
        'iq-id' { $iq.references[0].docKey = 'unverified-child' }
        'iq-error' { $iq.activity[0].status = 'failed' }
        'native-error' { $flow.NativeExitCode = 1; $flow.NativeText = 'DO-NOT-LEAK-BODY' }
        'native-fact' { $flow.NativeText = "=== Answer ===`nAnother person [$fixtureBlobUrl]" }
        'native-source' { $flow.NativeText = '=== Answer === Morgan Example.' }
        'native-prefix' { $flow.NativeText = "=== Answer === Morgan Example [$fixtureBlobUrl.evil]" }
    }
    Assert-EndToEndBlocked $mode 'IQ|Native'
}
Reset-EndToEndFixture
$flow.Resources['datasources/spo-native-datasource'].credentials.connectionString = $null
$null = & $endToEndScript @endToEndParameters -WhatIf
Assert-Check ($flow.Calls.Count -eq 0 -and $flow.TokenRequests.Count -eq 0) 'end-to-end WhatIf has no network access'
Assert-Check (-not (Test-Path -LiteralPath $receiptDirectory)) 'Declined verification does not create local receipt state.'
$state.EndToEnd = $false
$global:LASTEXITCODE = 0
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($endToEndScript, [ref]$null, [ref]$parseErrors)
Assert-Check ($parseErrors.Count -eq 0) 'end-to-end AST parses'
$defaultPathExpression = @($scriptAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'DataSourceReceiptPath' })[0].DefaultValue.Extent.Text
$defaultReceiptPath = & ([scriptblock]::Create("param([string]`$PSScriptRoot) $defaultPathExpression")) (Split-Path $endToEndScript -Parent)
Assert-Check ([IO.Path]::GetFullPath($defaultReceiptPath) -ieq (Join-Path $root '.azure\native-datasource-receipt.json')) 'End-to-end default receipt shares source .azure with initializer.'
$escapeAssignments = @($scriptAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$escapedBlobUrl'
}, $true))
Assert-Check ($escapeAssignments.Count -eq 1) 'one OData URL escaping assignment'
$escaped = & {
    $ingestion = @{ blob_url = "https://stagingtest.blob.core.windows.net/spo-staging/native/a/source'quote.pdf" }
    . ([scriptblock]::Create($escapeAssignments[0].Extent.Text))
    $escapedBlobUrl
}
Assert-Check ($escaped -ceq "https://stagingtest.blob.core.windows.net/spo-staging/native/a/source''quote.pdf") 'actual OData escaping handles quotes'
Assert-Check ([System.Net.ServicePointManager]::SecurityProtocol -eq $tlsBefore) 'TLS settings untouched'
Write-Output "Native ingestion tests passed ($($state.Checks) checks, including $verificationModeChecks verification mode checks)."
}
finally {
    if (Test-Path -LiteralPath $receiptDirectory) { Remove-Item -LiteralPath $receiptDirectory -Recurse -Force }
}