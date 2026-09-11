[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*\.azurewebsites\.net\z')][string]$FunctionHostname,
    [Parameter(Mandatory)][guid]$ApiClientId,
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[a-zA-Z0-9-]+\.search\.windows\.net/?\z')][string]$SearchEndpoint,
    [Parameter(Mandatory)][string]$ProjectEndpoint,
    [Parameter(Mandatory)][string]$SearchToolName,
    [Parameter(Mandatory)][string]$ModelDeployment,
    [Parameter(Mandatory)][string]$PythonExecutable,
    [ValidateNotNullOrEmpty()][string]$Question = 'Who is the fictional owner of Project Cedar?',
    [ValidateNotNullOrEmpty()][string]$ExpectedAnswer = 'Morgan Example',
    [string]$StorageResourceId,
    [string]$IngestionIdentityResourceId,
    [ValidateNotNullOrEmpty()][string]$DataSourceReceiptPath = (Join-Path $PSScriptRoot '..\..\.azure\native-datasource-receipt.json'),
    [ValidatePattern('^[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]\z')][string]$StagingContainer = 'spo-staging',
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 1500,
    [ValidateSet('fixture', 'sharepoint')][string]$Mode = 'fixture'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Mode -eq 'sharepoint' -and (-not $PSBoundParameters.ContainsKey('Question') -or
    -not $PSBoundParameters.ContainsKey('ExpectedAnswer') -or [string]::IsNullOrWhiteSpace($Question) -or
    [string]::IsNullOrWhiteSpace($ExpectedAnswer))) {
    throw 'SharePoint verification requires explicit nonempty -Question and -ExpectedAnswer from the intended source document.'
}
if (-not $PSCmdlet.ShouldProcess($FunctionHostname, "Stage $Mode, run private native indexer, verify blob metadata, chunks, IQ and native retrieval")) { return }

function Get-IngestionField {
    param($Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return ,$Value[$Name] }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Get-IngestionTime { return (Get-Date).ToUniversalTime() }

function Assert-IngestionDataSourceReceipt {
    param($DataSource)
    try {
        $receiptPath = [IO.Path]::GetFullPath($DataSourceReceiptPath)
        if ($receiptPath -notmatch '\A[A-Za-z]:\\' -or $receiptPath.Substring(2).Contains(':')) { throw 'Not a local file.' }
        $ancestor = $receiptPath
        while ($ancestor) {
            if (Test-Path -LiteralPath $ancestor) {
                $item = Get-Item -LiteralPath $ancestor -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    ($ancestor -ceq $receiptPath -and ($item.PSIsContainer -or $item.Length -gt 16384))) { throw 'Unsafe receipt path.' }
            }
            $ancestor = Split-Path -Path $ancestor -Parent
        }
        $definition = [ordered]@{
            name = $pipeline.datasource; type = 'azureblob'
            credentials = [ordered]@{ connectionString = "ResourceId=$StorageResourceId" }
            container = [ordered]@{ name = $StagingContainer; query = 'native/' }
            identity = [ordered]@{ '@odata.type' = '#Microsoft.Azure.Search.DataUserAssignedIdentity'; userAssignedIdentity = $IngestionIdentityResourceId }
        }
        foreach ($section in @('', 'credentials', 'container', 'identity')) {
            $actual = if ($section) { Get-IngestionField $DataSource $section } else { $DataSource }
            $expected = if ($section) { $definition[$section] } else { $definition }
            if ($actual -isnot [pscustomobject]) { throw 'Missing definition.' }
            foreach ($property in $actual.PSObject.Properties) {
                if (-not $section -and $property.Name -cin @('@odata.etag', '@odata.context')) { continue }
                if (-not $section -and $property.Name -ceq 'indexerPermissionOptions' -and
                    $property.Value -is [array] -and $property.Value.Count -eq 0) { continue }
                if ($expected.Keys -cnotcontains $property.Name -and $null -ne $property.Value) { throw 'Unexpected visible field.' }
            }
            foreach ($field in $expected.Keys) {
                if ($expected[$field] -isnot [string] -or $section -ceq 'credentials') { continue }
                $value = Get-IngestionField $actual $field
                if ($value -isnot [string] -or $value -cne $expected[$field]) { throw 'Visible definition mismatch.' }
            }
        }
        $etag = Get-IngestionField $DataSource '@odata.etag'
        if ($etag -isnot [string] -or $etag -cnotmatch '\A"[^"\x00-\x20\x7f]+"\z') { throw 'Missing ETag.' }
        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $canonical = $definition | ConvertTo-Json -Depth 10 -Compress
            $configHash = -join ($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)) | ForEach-Object { $_.ToString('x2') })
        }
        finally { $hasher.Dispose() }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $version = Get-IngestionField $receipt 'receipt_version'
        if (($version -isnot [int] -and $version -isnot [long]) -or $version -ne 1) { throw 'Receipt version mismatch.' }
        $expectedReceipt = @{
            search_endpoint = $SearchEndpoint.TrimEnd('/'); datasource = $pipeline.datasource
            storage_resource_id = $StorageResourceId; staging_container = $StagingContainer; folder_path = 'native/'
            ingestion_identity_resource_id = $IngestionIdentityResourceId; desired_config_sha256 = $configHash; server_etag = $etag
        }
        foreach ($field in $expectedReceipt.Keys) {
            $value = Get-IngestionField $receipt $field
            if ($value -isnot [string] -or $value -cne $expectedReceipt[$field]) { throw 'Receipt binding mismatch.' }
        }
    }
    catch { throw 'Native datasource receipt is missing, unsafe or does not match the visible definition, explicit IDs, desired configuration and server ETag. ACTION: use Initialize-KnowledgeBase.ps1 -RebindDataSource with the intended IDs and -DataSourceReceiptPath before verification.' }
}

function Get-IngestionTimeout {
    param([int]$Maximum = 30)
    $remaining = ($deadline - (Get-IngestionTime)).TotalSeconds
    if ($remaining -lt 1) { throw 'Native ingestion verification deadline exceeded; no completed proof.' }
    return [int][math]::Min($Maximum, [math]::Floor($remaining))
}

function Wait-IngestionPoll {
    $remaining = Get-IngestionTimeout 5
    Start-Sleep -Seconds $remaining
}

function Get-IngestionHttpStatus {
    param($ErrorRecord, [int]$Fallback = 0)
    $response = Get-IngestionField $ErrorRecord.Exception 'Response'
    if ($null -ne $response) { return [int]$response.StatusCode }
    return $Fallback
}

function Get-IngestionToken {
    param([string]$Resource)
    try {
        $encoded = [uri]::EscapeDataString($Resource)
        $identity = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encoded" `
            -Headers @{ Metadata = 'true' } -TimeoutSec (Get-IngestionTimeout 15) -MaximumRedirection 0 -Verbose:$false -Debug:$false
        $token = Get-IngestionField $identity 'access_token'
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'No token.' }
        return $token
    }
    catch { throw 'Runner managed identity token acquisition failed; no token or response body reported.' }
    finally { $identity = $null; $token = $null }
}

function Invoke-IngestionSearch {
    param([string]$Path, [string]$Method = 'GET', $Body, [int]$ExpectedStatus = 200, [int]$MaximumSeconds = 30)
    $requestTimeout = Get-IngestionTimeout $MaximumSeconds
    $statusCode = 0
    try {
        $request = @{
            Uri = "$search/${Path}?api-version=2026-08-01-preview"; Method = $Method; Headers = $headers
            TimeoutSec = $requestTimeout; MaximumRedirection = 0; UseBasicParsing = $true
            Verbose = $false; Debug = $false
        }
        if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress; $request.ContentType = 'application/json' }
        $response = Invoke-WebRequest @request
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne $ExpectedStatus) { throw 'Unexpected HTTP status.' }
        if ($ExpectedStatus -eq 202) { return }
        $parsed = $response.Content | ConvertFrom-Json
        if ($null -eq $parsed -or (Get-IngestionField $parsed 'error') -or (Get-IngestionField $parsed 'errors')) { throw 'Missing or failed response.' }
        return $parsed
    }
    catch {
        $statusCode = Get-IngestionHttpStatus $_ $statusCode
        if ($statusCode -eq 409 -and $Path -like 'indexers/*/run') {
            throw 'Native indexer run conflicted (HTTP 409). No repeated POST was attempted; rerun verification after the competing run completes.'
        }
        throw "Native Search verification failed at $Path (HTTP $statusCode; expected $ExpectedStatus). No response body reported; check private DNS, RBAC and service health."
    }
}

function Convert-IngestionTimestamp {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $parsed = [datetimeoffset]::MinValue
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T' -or
        -not [datetimeoffset]::TryParse($Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        throw 'Indexer result contains no valid timestamp.'
    }
    return $parsed.UtcDateTime
}

function Read-IngestionBlob {
    param([string]$ETag)
    $blobHeaders = @{ Authorization = "Bearer $(Get-IngestionToken 'https://storage.azure.com/')"; 'x-ms-version' = '2023-11-03' }
    if ($ETag) { $blobHeaders['If-Match'] = $ETag }
    $statusCode = 0
    try {
        $response = Invoke-WebRequest -Uri $ingestion.blob_url -Method Head -Headers $blobHeaders `
            -UseBasicParsing -MaximumRedirection 0 -TimeoutSec (Get-IngestionTimeout) -Verbose:$false -Debug:$false
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne 200) { throw 'Blob HEAD failed.' }
        if ([string]$response.Headers['x-ms-meta-source_id'] -cne $ingestion.source_id -or
            [string]$response.Headers['x-ms-meta-content_hash'] -cne $ingestion.content_hash -or
            [string]$response.Headers['Content-Length'] -cne [string]$ingestion.bytes) { throw 'Blob metadata mismatch.' }
        $lastModified = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$response.Headers['Last-Modified'], [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$lastModified) -or
            $lastModified.UtcDateTime -lt $stageStarted.AddSeconds(-1) -or
            [string]::IsNullOrWhiteSpace([string]$response.Headers['ETag']) -or
            ($ETag -and [string]$response.Headers['ETag'] -cne $ETag)) { throw 'Blob overwrite not verified.' }
        return [string]$response.Headers['ETag']
    }
    catch {
        $statusCode = Get-IngestionHttpStatus $_ $statusCode
        throw "Staged blob provenance failed (HTTP $statusCode): metadata, length, last-modified or ETag mismatch, or HEAD denied. Search doc_url alone does not prove a digest."
    }
    finally { $blobHeaders.Clear() }
}

function Test-IngestionReference {
    param($Reference, [string[]]$ChunkIds, [string[]]$ParentIds)
    $sourceData = Get-IngestionField $Reference 'sourceData'
    $sourceName = Get-IngestionField $Reference 'knowledgeSourceName'
    if ($sourceName -and $sourceName -cne 'spo-native') { return $false }
    $matched = $false
    foreach ($record in @($Reference, $sourceData)) {
        foreach ($field in @('doc_url', 'url')) {
            $value = Get-IngestionField $record $field
            if ($value) {
                if ($value -cne $ingestion.blob_url) { return $false }
                $matched = $true
            }
        }
        foreach ($field in @('docKey', 'snippet_id', 'snippet_parent_id')) {
            $value = Get-IngestionField $record $field
            if ($value) {
                if ($ChunkIds -cnotcontains $value -and $ParentIds -cnotcontains $value) { return $false }
                $matched = $true
            }
        }
    }
    return $matched
}

$stageStarted = Get-IngestionTime
$deadline = $stageStarted.AddSeconds($TimeoutSeconds)
$headers = @{}
$answer = $null
try {
    try {
        $contract = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\shared\native-ingestion.json') -Raw | ConvertFrom-Json
    }
    catch { throw 'Native ingestion contract is missing or malformed; stage the shared version 2 contract before verification.' }
    $contractVersion = Get-IngestionField $contract 'contractVersion'
    if (($contractVersion -isnot [int] -and $contractVersion -isnot [long]) -or $contractVersion -ne 2) {
        throw 'Native ingestion contract version must be 2.'
    }
    $expectedContract = @{
        owner = 'accelerator-native-indexer'; apiVersion = '2026-08-01-preview'
        knowledgeSourceName = 'spo-native'; knowledgeBaseName = 'spo-native-knowledge-base'
    }
    foreach ($field in $expectedContract.Keys) {
        $value = Get-IngestionField $contract $field
        if ($value -isnot [string] -or $value -cne $expectedContract[$field]) {
            throw 'Native ingestion contract owner, API or knowledge resource names do not match.'
        }
    }
    $pipeline = Get-IngestionField $contract 'pipeline'
    foreach ($field in @('index', 'indexer', 'skillset', 'datasource')) {
        $name = Get-IngestionField $pipeline $field
        if ($name -isnot [string] -or $name -cne "spo-native-$field") { throw 'Native ingestion contract has an unsafe, missing or unexpected pipeline resource name.' }
    }
    $ingestion = & (Join-Path $PSScriptRoot 'Invoke-IngestFunction.ps1') -FunctionHostname $FunctionHostname -ApiClientId $ApiClientId -Mode $Mode -Confirm:$false
    if ($ingestion.status -cne 'staged' -or $ingestion.indexing -cne 'not_tested') { throw 'Function did not confirm staging only.' }
    if ((Get-IngestionField $ingestion 'mode') -cne $Mode) { throw 'Function staging mode does not match the requested verification mode.' }
    $headers.Authorization = "Bearer $(Get-IngestionToken 'https://search.azure.com/')"
    $search = $SearchEndpoint.TrimEnd('/')
    $source = Invoke-IngestionSearch 'knowledgesources/spo-native'
    if ((Get-IngestionField $source 'name') -cne 'spo-native' -or (Get-IngestionField $source 'kind') -cne 'searchIndex' -or
        (Get-IngestionField (Get-IngestionField $source 'searchIndexParameters') 'searchIndexName') -cne $pipeline.index -or
        $null -ne (Get-IngestionField $source 'azureBlobParameters') -or $null -ne (Get-IngestionField $source 'createdResources')) {
        throw 'Expected native searchIndex knowledge source bound to the explicit child index, without Blob ingestion resources.'
    }
    $indexer = Invoke-IngestionSearch "indexers/$($pipeline.indexer)"
    $datasource = Invoke-IngestionSearch "datasources/$($pipeline.datasource)"
    $skillset = Invoke-IngestionSearch "skillsets/$($pipeline.skillset)"
    $index = Invoke-IngestionSearch "indexes/$($pipeline.index)"
    $credentials = Get-IngestionField $datasource 'credentials'
    $connectionString = Get-IngestionField $credentials 'connectionString'
    $dataSourceReceiptStatus = 'not-required'
    if ($null -eq $connectionString) {
        if ($credentials -isnot [pscustomobject] -or $null -eq $credentials.PSObject.Properties['connectionString'] -or
            -not $PSBoundParameters.ContainsKey('StorageResourceId') -or -not $PSBoundParameters.ContainsKey('IngestionIdentityResourceId') -or
            [string]::IsNullOrWhiteSpace($IngestionIdentityResourceId) -or
            $StorageResourceId -cnotmatch '\A/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft\.Storage/storageAccounts/([a-z0-9]{3,24})\z') {
            throw 'Native datasource null credential scope requires explicit valid StorageResourceId and IngestionIdentityResourceId plus a matching receipt.'
        }
        $sourceStorageId = $StorageResourceId
        $accountName = $Matches[1]
        Assert-IngestionDataSourceReceipt $datasource
        $dataSourceReceiptStatus = 'matched'
    }
    elseif ($connectionString -is [string] -and
        $connectionString -cmatch '^ResourceId=(/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft\.Storage/storageAccounts/([a-z0-9]{3,24}));?\z') {
        $sourceStorageId = $Matches[1]
        $accountName = $Matches[2]
    }
    else {
        throw 'Native datasource storage scope is missing, redacted or not keyless.'
    }
    $identity = Get-IngestionField $datasource 'identity'
    $identityResourceId = Get-IngestionField $identity 'userAssignedIdentity'
    $identityScope = '^/subscriptions/' + [regex]::Escape(($sourceStorageId -split '/')[2]) +
        '/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[a-zA-Z0-9_-]+\z'
    if ((Get-IngestionField $identity '@odata.type') -cne '#Microsoft.Azure.Search.DataUserAssignedIdentity' -or
        $identityResourceId -isnot [string] -or $identityResourceId -notmatch $identityScope -or
        ($IngestionIdentityResourceId -and $identityResourceId -ine $IngestionIdentityResourceId)) {
        throw 'Native datasource identity does not match the ingestion managed identity scope.'
    }
    $container = Get-IngestionField $datasource 'container'
    if (($StorageResourceId -and $sourceStorageId -ine $StorageResourceId) -or
        (Get-IngestionField $container 'name') -cne $StagingContainer -or (Get-IngestionField $container 'query') -cne 'native/' -or
        $ingestion.blob_url -cne "https://$accountName.blob.core.windows.net/$StagingContainer/$($ingestion.blob_name)") {
        throw 'Native datasource scope does not match the staged blob.'
    }
    if ($indexer.name -cne $pipeline.indexer -or $indexer.dataSourceName -cne $pipeline.datasource -or
        $indexer.targetIndexName -cne $pipeline.index -or $indexer.skillsetName -cne $pipeline.skillset -or
        (Get-IngestionField $indexer 'disabled') -eq $true -or
        $indexer.parameters.configuration.executionEnvironment -cne 'private' -or
        $datasource.name -cne $pipeline.datasource -or $datasource.type -cne 'azureblob' -or
        $skillset.name -cne $pipeline.skillset -or $index.name -cne $pipeline.index) {
        throw 'Native indexer private configuration or resource associations do not match.'
    }
    $selectors = @($skillset.indexProjections.selectors)
    if ($skillset.indexProjections.parameters.projectionMode -cne 'skipIndexingParentDocuments' -or
        $selectors.Count -ne 1 -or $selectors[0].targetIndexName -cne $pipeline.index -or
        $selectors[0].parentKeyFieldName -cne 'snippet_parent_id') { throw 'Native child-parent projection mismatch.' }
    $urlMappings = @($selectors[0].mappings | Where-Object { $_.name -ceq 'doc_url' })
    if ($urlMappings.Count -ne 1) { throw 'Child doc_url must project the staged blob URL.' }
    $urlSource = Get-IngestionField $urlMappings[0] 'source'
    $urlInputs = Get-IngestionField $urlMappings[0] 'inputs'
    if ($urlSource -cnotin @('/document/metadata_storage_path', '/document/doc_url') -or
        $null -ne (Get-IngestionField $urlMappings[0] 'sourceContext') -or
        $null -ne (Get-IngestionField $urlMappings[0] 'mappingFunction') -or
        ($null -ne $urlInputs -and ($urlInputs -isnot [array] -or $urlInputs.Count -ne 0))) {
        throw 'Child doc_url must directly project the staged blob URL.'
    }
    $urlFieldMappings = @((Get-IngestionField $indexer 'fieldMappings') | Where-Object { (Get-IngestionField $_ 'targetFieldName') -ceq 'doc_url' })
    if ($urlFieldMappings.Count -gt 1 -or ($urlSource -ceq '/document/doc_url' -and $urlFieldMappings.Count -ne 1)) {
        throw 'Child doc_url requires exactly one explicit staged blob URL field mapping.'
    }
    foreach ($mapping in $urlFieldMappings) {
        if ((Get-IngestionField $mapping 'sourceFieldName') -cne 'metadata_storage_path' -or
            $null -ne (Get-IngestionField $mapping 'mappingFunction')) { throw 'Child doc_url field mapping must preserve the staged blob URL.' }
    }
    $vectorFields = @($index.fields | Where-Object { $_.name -ceq 'snippet_vector' })
    if ($vectorFields.Count -ne 1) { throw 'Missing child vector field.' }
    $vectorRetrievable = (Get-IngestionField $vectorFields[0] 'retrievable') -ne $false
    $blobETag = Read-IngestionBlob

    do {
        $status = Invoke-IngestionSearch "indexers/$($pipeline.indexer)/status"
        if ($status.status -cne 'running') { throw 'Native indexer is not available for execution.' }
        $existing = Get-IngestionField $status 'lastResult'
        if ((Get-IngestionField $existing 'status') -cne 'inProgress') { break }
        Wait-IngestionPoll
    } while ($true)
    $runBaseline = Get-IngestionTime
    $null = Invoke-IngestionSearch "indexers/$($pipeline.indexer)/run" -Method POST -ExpectedStatus 202
    $completed = $null
    do {
        $status = Invoke-IngestionSearch "indexers/$($pipeline.indexer)/status"
        if ($status.status -cne 'running') { throw 'Native indexer status reports an execution error.' }
        $runs = @((Get-IngestionField $status 'lastResult')) + @((Get-IngestionField $status 'executionHistory'))
        foreach ($run in $runs) {
            if ($null -eq $run) { continue }
            $startTime = Convert-IngestionTimestamp (Get-IngestionField $run 'startTime')
            if ($startTime -lt $runBaseline) { continue }
            $runStatus = Get-IngestionField $run 'status'
            if ((Get-IngestionField $run 'errorMessage') -or @((Get-IngestionField $run 'errors') | Where-Object { $null -ne $_ }).Count) {
                throw 'Fresh native indexer execution reported errors.'
            }
            if ($runStatus -ceq 'inProgress') { continue }
            if ($runStatus -cne 'success') { throw 'Fresh native indexer execution did not succeed.' }
            $endTime = Convert-IngestionTimestamp (Get-IngestionField $run 'endTime')
            $processed = Get-IngestionField $run 'itemsProcessed'
            $failed = Get-IngestionField $run 'itemsFailed'
            if ($endTime -lt $startTime -or $endTime -gt (Get-IngestionTime) -or
                ($processed -isnot [int] -and $processed -isnot [long]) -or $processed -lt 1 -or
                ($failed -isnot [int] -and $failed -isnot [long]) -or $failed -ne 0) {
                throw 'Fresh indexer result lacks a completed run with processed >= 1 and failed = 0.'
            }
            $completed = $run
        }
        if ($null -ne $completed) { break }
        Wait-IngestionPoll
    } while ($true)

    $null = Read-IngestionBlob -ETag $blobETag
    $selection = 'snippet_id,snippet_parent_id,snippet,doc_url'
    if ($vectorRetrievable) { $selection += ',snippet_vector' }
    $escapedBlobUrl = $ingestion.blob_url.Replace("'", "''")
    $documents = Invoke-IngestionSearch "indexes/$($pipeline.index)/docs/search" -Method POST -Body @{
        search = '*'; filter = "doc_url eq '$escapedBlobUrl'"; select = $selection; top = 100; count = $true
    }
    $chunks = @((Get-IngestionField $documents 'value') | Where-Object { $null -ne $_ })
    $total = Get-IngestionField $documents '@odata.count'
    if ($chunks.Count -lt 1 -or $chunks.Count -gt 100 -or $null -eq $total -or $total -ne $chunks.Count -or
        (Get-IngestionField $documents '@odata.nextLink') -or (Get-IngestionField $documents '@search.nextPageParameters')) {
        throw 'No complete bounded set of staged-source chunks; empty, truncated or continued Search results cannot pass.'
    }
    $chunkIds = @()
    $parentIds = @()
    foreach ($chunk in $chunks) {
        foreach ($field in @('snippet_id', 'snippet_parent_id', 'snippet', 'doc_url')) {
            if ((Get-IngestionField $chunk $field) -isnot [string]) { throw 'Child fields must contain strings.' }
        }
        if ([string]::IsNullOrWhiteSpace($chunk.snippet_id) -or [string]::IsNullOrWhiteSpace($chunk.snippet_parent_id) -or
            [string]::IsNullOrWhiteSpace($chunk.snippet) -or $chunk.doc_url -cne $ingestion.blob_url -or
            $chunkIds -ccontains $chunk.snippet_id) { throw 'Child snippet, parent, unique key or staged URL mismatch.' }
        if ($vectorRetrievable -and @((Get-IngestionField $chunk 'snippet_vector')).Count -ne 3072) { throw 'Retrievable child vector must have 3072 dimensions.' }
        $chunkIds += $chunk.snippet_id
        $parentIds += $chunk.snippet_parent_id
    }
    if (@($parentIds | Select-Object -Unique).Count -ne 1 -or ($chunks.snippet -join "`n") -notmatch [regex]::Escape($ExpectedAnswer)) {
        throw 'Staged-source chunks do not establish one parent and the expected source fact.'
    }
    $scopedQuestion = "$Question`nUse the staged document at $($ingestion.blob_url). Include its exact doc_url or snippet_id in the answer."
    $retrieval = Invoke-IngestionSearch 'knowledgebases/spo-native-knowledge-base/retrieve' -Method POST -MaximumSeconds 120 -Body @{
        messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = $scopedQuestion }) })
    }
    foreach ($activity in @((Get-IngestionField $retrieval 'activity'))) {
        if ((Get-IngestionField $activity 'error') -or (Get-IngestionField $activity 'errors') -or
            (Get-IngestionField $activity 'status') -in @('failed', 'error', 'incomplete', 'cancelled')) { throw 'IQ retrieval activity failed.' }
    }
    $texts = @(foreach ($message in (Get-IngestionField $retrieval 'response')) {
        foreach ($part in (Get-IngestionField $message 'content')) {
            $text = Get-IngestionField $part 'text'
            if (-not [string]::IsNullOrWhiteSpace($text)) { $text }
        }
    })
    if (-not $texts.Count -or ($texts -join "`n") -notmatch [regex]::Escape($ExpectedAnswer)) { throw 'IQ did not retrieve the expected source fact.' }
    $references = @((Get-IngestionField $retrieval 'references') | Where-Object { $null -ne $_ })
    if (-not $references.Count) { throw 'IQ returned no staged-source references.' }
    foreach ($reference in $references) {
        if (-not (Test-IngestionReference $reference $chunkIds $parentIds)) { throw 'IQ reference does not match the staged blob or verified child/parent IDs.' }
    }
    $client = Join-Path $PSScriptRoot '..\..\src\hello_world\ask_agent.py'
    $nativeTimeout = Get-IngestionTimeout 900
    try {
        $global:LASTEXITCODE = 0
        $answer = & $PythonExecutable $client --project-endpoint $ProjectEndpoint --search-tool-name $SearchToolName `
            --model $ModelDeployment --question $scopedQuestion --timeout $nativeTimeout 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $answer) { throw 'Native client failed.' }
    }
    catch { throw 'Native response failed the required IQ and toolbox validation; no client output reported.' }
    $answerText = $answer -join "`n"
    if ($answerText -notmatch '(?s)=== Answer ===\s*(?<answer>.+)\z') { throw 'Native client did not return a validated answer.' }
    $answerText = $Matches.answer
    if ($answerText -notmatch [regex]::Escape($ExpectedAnswer)) { throw 'Native answer did not contain the expected source fact.' }
    $sourceMatched = $false
    foreach ($identifier in (@($ingestion.blob_url) + $chunkIds)) {
        if ($answerText -cmatch ("(?<![\w/])" + [regex]::Escape($identifier) + '(?=$|[\s<>\[\)\]"'',;]|[.!?](?:\s|$))')) { $sourceMatched = $true }
    }
    if (-not $sourceMatched) { throw 'Native answer did not cite the staged blob URL or a verified snippet ID.' }
    $null = Get-IngestionTimeout
    $summary = [pscustomobject]@{
        status = 'passed'; request_id = $ingestion.request_id; source_id = $ingestion.source_id; content_hash = $ingestion.content_hash
        mode = $Mode
        source_url = $ingestion.source_url; blob_url = $ingestion.blob_url; staging = 'passed'
        ingestion_path = 'authorized_function_to_blob_to_native_indexer'; blob_metadata = 'matched'
        search_provenance = 'staged_blob_url_and_child_ids'; chunk_count = $chunks.Count; chunk_set_complete = $true
        index = $pipeline.index; indexer = $pipeline.indexer; indexing = 'passed'
        datasource_receipt_status = $dataSourceReceiptStatus
        indexer_start_time = $completed.startTime; indexer_items_processed = $completed.itemsProcessed; indexer_items_failed = $completed.itemsFailed
        vector_validation = $(if ($vectorRetrievable) { '3072_dimensions' } else { 'not_retrievable' })
        iq_retrieval = 'passed'; native_dual_retrieval = 'passed'; sharepoint = $(if ($Mode -eq 'sharepoint') { 'passed' } else { 'not_tested' })
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount(($summary | ConvertTo-Json -Depth 5 -Compress)) -gt 3072) { throw 'Verification summary exceeds the transport budget.' }
    $summary
}
finally {
    $headers.Clear()
    $answer = $null
    $answerText = $null
    $retrieval = $null
    $documents = $null
    $chunks = $null
}
