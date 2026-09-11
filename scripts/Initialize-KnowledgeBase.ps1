<#
.SYNOPSIS
    Create or verify a private native indexer pipeline and searchIndex knowledge source.
.DESCRIPTION
    PowerShell 5.1-compatible private-runner entry point. Runner IMDS authenticates
    Search administration; the supplied UAMI authenticates storage and enrichment.
    Checks all six existing definitions before creating any missing definition with
    If-None-Match: *. Explicit RebindDataSource permits only an ETag-conditional
    credential rebind after all visible definitions match. RefreshDataSourceBinding
    permits the same conditional PUT only for a valid, configuration-matched receipt
    with a stale ETag; the new receipt is verified against the PUT readback.
    Never deletes, resets
    or explicitly runs an indexer. A local receipt binds redacted GET credentials.
    Creating the enabled PT5M indexer starts service-managed indexing independently
    of the Function. Success verifies configuration, not indexing or S1 eligibility.
    SchemaPath and ContractPath are version-2 native templates, not generated KS
    acceptance contracts. AsJson preserves the Python launcher's result interface.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][ValidatePattern('^https://[a-zA-Z0-9-]+\.search\.windows\.net/?$')]
    [string]$SearchEndpoint,
    [Parameter(Mandatory)][ValidatePattern('^https://[a-zA-Z0-9-]+\.openai\.azure\.com/?$')]
    [string]$FoundryOpenAIEndpoint,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$')][string]$PlannerDeployment,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$')][string]$PlannerModel,
    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}$')]
    [string]$StorageResourceId,
    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[a-zA-Z0-9_-]+$')]
    [string]$IngestionIdentityResourceId,
    [Parameter(Mandatory)][ValidatePattern('^https://[a-zA-Z0-9-]+\.services\.ai\.azure\.com/?$')]
    [string]$IngestionFoundryEndpoint,
    [Parameter(Mandatory)][ValidatePattern('^https://[a-zA-Z0-9-]+\.openai\.azure\.com/?$')]
    [string]$IngestionOpenAIEndpoint,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$')][string]$IngestionChatDeployment,
    [Parameter(Mandatory)][ValidateSet('gpt-5.2')][string]$IngestionChatModel,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$')][string]$EmbeddingDeployment,
    [Parameter(Mandatory)][ValidateSet('text-embedding-3-large')][string]$EmbeddingModel,
    [ValidatePattern('^[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]$')][string]$StagingContainer = 'spo-staging',
    [ValidatePattern('^native/(?:[a-zA-Z0-9_-]+/)*$')][string]$FolderPath = 'native/',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..\src\shared\search-index.json'),
    [string]$ContractPath = (Join-Path $PSScriptRoot '..\src\shared\native-ingestion.json'),
    [switch]$RebindDataSource,
    [switch]$RefreshDataSourceBinding,
    [ValidateNotNullOrEmpty()][string]$DataSourceReceiptPath = (Join-Path $PSScriptRoot '..\.azure\native-datasource-receipt.json'),
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Stop-NativeContract {
    param([string]$Path)
    throw "Native knowledge source blocked: contract mismatch at $Path. Drifted definitions are never modified or deleted. Resolve the mismatch explicitly; no custom-skill fallback is allowed."
}

function Get-NativeProperty {
    param($Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return ,$Value[$Name] }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Assert-NativeContract {
    param($Actual, $Expected, [string]$Path)
    if ($null -eq $Expected) {
        if ($null -ne $Actual) { Stop-NativeContract $Path }
        return
    }
    if ($Expected -is [System.Collections.IDictionary] -or $Expected -is [pscustomobject]) {
        if ($null -eq $Actual) { Stop-NativeContract $Path }
        $names = if ($Expected -is [System.Collections.IDictionary]) { @($Expected.Keys) } else { @($Expected.PSObject.Properties.Name) }
        foreach ($name in $names) {
            Assert-NativeContract (Get-NativeProperty $Actual $name) (Get-NativeProperty $Expected $name) "$Path/$name"
        }
        return
    }
    if ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count) { Stop-NativeContract $Path }
        for ($position = 0; $position -lt $Expected.Count; $position++) {
            $expectedItem = $Expected[$position]
            $itemName = Get-NativeProperty $expectedItem 'name'
            if ($null -ne $itemName) {
                $matches = @($Actual | Where-Object { (Get-NativeProperty $_ 'name') -ceq $itemName })
                if ($matches.Count -ne 1) { Stop-NativeContract $Path }
                Assert-NativeContract $matches[0] $expectedItem "$Path/$itemName"
            }
            elseif ($expectedItem -is [string]) {
                if (@($Actual | Where-Object { $_ -ceq $expectedItem }).Count -ne 1) { Stop-NativeContract $Path }
            }
            else { Assert-NativeContract $Actual[$position] $expectedItem $Path }
        }
        return
    }
    if ($Expected -is [string]) {
        if ($Actual -isnot [string]) { Stop-NativeContract $Path }
        if ($Path -match '/(resourceUri|uri|subdomainUrl)$') {
            if ($Actual.TrimEnd('/') -cne $Expected.TrimEnd('/')) { Stop-NativeContract $Path }
        }
        elseif ($Actual -cne $Expected) { Stop-NativeContract $Path }
    }
    elseif ($Expected -is [bool]) {
        if ($Actual -isnot [bool] -or $Actual -ne $Expected) { Stop-NativeContract $Path }
    }
    elseif ($null -eq $Actual -or $Actual -is [string] -or $Actual -is [bool] -or $Actual -ne $Expected) {
        Stop-NativeContract $Path
    }
}

function Assert-NativeKeyless {
    param($Value)
    if ($null -eq $Value) { return }
    if ($Value -is [array]) {
        foreach ($item in $Value) { Assert-NativeKeyless $item }
    }
    elseif ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary]) {
        $names = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($name in $names) {
            $child = Get-NativeProperty $Value $name
            if ($name -in @('apiKey', 'key', 'accessCredentials', 'federatedIdentityClientId') -and $null -ne $child -and $child -isnot [bool]) {
                Stop-NativeContract 'authentication/non-null-credential'
            }
            Assert-NativeKeyless $child
        }
    }
}

function Assert-NativeNoItems {
    param($Value, [string]$Path)
    if ($null -ne $Value -and ($Value -isnot [array] -or $Value.Count -ne 0)) { Stop-NativeContract $Path }
}

function Assert-NativeDirectInputs {
    param($Mappings, [string]$Path)
    foreach ($mapping in $Mappings) {
        if ($null -ne (Get-NativeProperty $mapping 'sourceContext') -or $null -ne (Get-NativeProperty $mapping 'mappingFunction')) {
            Stop-NativeContract $Path
        }
        Assert-NativeNoItems (Get-NativeProperty $mapping 'inputs') $Path
    }
}

function Get-NativeHttpStatus {
    param($Failure)
    $status = Get-NativeProperty (Get-NativeProperty $Failure.Exception 'Response') 'StatusCode'
    $statusNumber = 0
    if ($status -is [System.Enum]) { $status = [int]$status }
    if ([int]::TryParse([string]$status, [ref]$statusNumber) -and $statusNumber -ge 100 -and $statusNumber -le 599) { return $statusNumber }
    return 0
}

function Invoke-NativeSearch {
    param([ValidateSet('GET', 'PUT')][string]$Method, [string]$Collection, [string]$Name, $Body, [switch]$AllowMissing, [string]$IfMatch)
    $allowedNames = @{
        datasources = 'spo-native-datasource'; indexes = 'spo-native-index'
        skillsets = 'spo-native-skillset'; indexers = 'spo-native-indexer'
        knowledgesources = 'spo-native'; knowledgebases = 'spo-native-knowledge-base'
    }
    if ($Collection -cnotin @($allowedNames.Keys) -or $Name -cne $allowedNames[$Collection]) { Stop-NativeContract 'resource-address' }
    if ($Method -eq 'PUT' -and (Get-NativeProperty $Body 'name') -cne $Name) { Stop-NativeContract 'resource-body-name' }
    if ($PSBoundParameters.ContainsKey('IfMatch') -and ($Method -cne 'PUT' -or $Collection -cne 'datasources' -or
        (-not $RebindDataSource -and -not $RefreshDataSourceBinding) -or $IfMatch -cnotmatch '\A"[^"\x00-\x20\x7f]+"\z')) { Stop-NativeContract 'datasources/conditional-rebind' }
    $requestHeaders = @{ Authorization = $headers.Authorization }
    $request = @{
        Uri = "$($SearchEndpoint.TrimEnd('/'))/$Collection/${Name}?api-version=$($contract.apiVersion)"
        Method = $Method; Headers = $requestHeaders; TimeoutSec = 120; MaximumRedirection = 0
        ErrorAction = 'Stop'; Verbose = $false; Debug = $false
    }
    if ($Method -eq 'PUT') {
        if ($IfMatch) { $requestHeaders['If-Match'] = $IfMatch }
        else { $requestHeaders['If-None-Match'] = '*' }
        $requestHeaders.Prefer = 'return=representation'
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 50 -Compress))
    }
    try { $result = Invoke-RestMethod @request }
    catch {
        $status = Get-NativeHttpStatus $_
        if ($AllowMissing -and $Method -eq 'GET' -and $status -eq 404) { return $null }
        $statusLabel = if ($status) { [string]$status } else { 'unavailable' }
        $hint = switch ($status) {
            400 { 'Check the preview API payload and service/model prerequisites.' }
            401 { 'Check runner managed-identity authentication.' }
            403 { 'Check Search RBAC, private DNS and shared-private-link approvals.' }
            404 { 'A required readback disappeared; inspect the fixed resource before retrying.' }
            409 { 'Creation conflicted; inspect existing definitions before retrying.' }
            412 { 'A concurrent change won; inspect existing definitions before retrying. No new datasource receipt was saved.' }
            429 { 'Search throttled the request; retry manually after capacity recovers.' }
            default { 'Check API support, connectivity and dependency health.' }
        }
        throw "Native knowledge initialization failed: $Method $Collection/$Name (HTTP $statusLabel). $hint Response body suppressed; no automatic retry or rollback."
    }
    finally { $requestHeaders.Clear(); $request.Clear() }
    if ($Method -eq 'GET' -and ($null -eq $result -or $result -isnot [pscustomobject])) { Stop-NativeContract "$Collection/empty-or-malformed-readback" }
    return $result
}

function Assert-NativeResource {
    param([string]$Collection, $Actual, $Expected, [switch]$AllowRedactedCredential)
    Assert-NativeKeyless $Actual
    if ($Collection -eq 'datasources') {
        Assert-NativeDataSourceFields $Actual $Expected 'datasources'
        if ($AllowRedactedCredential -and $null -eq (Get-NativeProperty (Get-NativeProperty $Actual 'credentials') 'connectionString')) {
            $credentials = Get-NativeProperty $Actual 'credentials'
            if ($null -eq $credentials -or $null -eq $credentials.PSObject.Properties['connectionString']) { Stop-NativeContract 'datasources/credentials/connectionString' }
            $Expected = $Expected.Clone()
            $Expected.credentials = @{ connectionString = $null }
        }
    }
    if ($Collection -eq 'indexes') {
        foreach ($field in $Expected.fields) {
            $matches = @((Get-NativeProperty $Actual 'fields') | Where-Object { (Get-NativeProperty $_ 'name') -ceq $field.name })
            if ($matches.Count -ne 1) { Stop-NativeContract 'indexes/required-field' }
            Assert-NativeContract $matches[0] $field "indexes/$($field.name)"
        }
        $keys = @($Actual.fields | Where-Object { (Get-NativeProperty $_ 'key') -eq $true })
        if ($keys.Count -ne 1 -or $keys[0].name -cne 'snippet_id') { Stop-NativeContract 'indexes/key-count' }
        Assert-NativeContract $Actual @{ name = $Expected.name; vectorSearch = $Expected.vectorSearch; semantic = $Expected.semantic } 'indexes'
    }
    else { Assert-NativeContract $Actual $Expected $Collection }
    switch ($Collection) {
        'knowledgesources' {
            foreach ($property in @('azureBlobParameters', 'networkAccessMode')) {
                if ($null -ne (Get-NativeProperty $Actual $property)) { Stop-NativeContract "knowledgesources/$property" }
            }
            foreach ($property in @('baseFilter', 'queryHints', 'semanticConfigurationName')) {
                if ($null -ne (Get-NativeProperty $Actual.searchIndexParameters $property)) { Stop-NativeContract "knowledgesources/$property" }
            }
            Assert-NativeNoItems (Get-NativeProperty $Actual.searchIndexParameters 'searchFields') 'knowledgesources/searchFields'
        }
        'knowledgebases' {
            if ($null -ne (Get-NativeProperty $Actual.models[0].azureOpenAIParameters 'authIdentity')) { Stop-NativeContract 'knowledgebases/planner-system-identity' }
        }
        'skillsets' {
            if ($null -ne (Get-NativeProperty $Actual 'knowledgeStore')) { Stop-NativeContract 'skillsets/knowledgeStore' }
            foreach ($skill in $Actual.skills) { Assert-NativeDirectInputs $skill.inputs 'skillsets/input-transform' }
            Assert-NativeDirectInputs $Actual.indexProjections.selectors[0].mappings 'skillsets/projection-transform'
        }
        'indexers' {
            if ((Get-NativeProperty $Actual 'disabled') -eq $true) { Stop-NativeContract 'indexers/disabled' }
            foreach ($property in @('fieldMappings', 'outputFieldMappings')) { Assert-NativeNoItems (Get-NativeProperty $Actual $property) "indexers/$property" }
            if ($null -ne (Get-NativeProperty $Actual 'cache')) { Stop-NativeContract 'indexers/cache' }
        }
    }
}

function Assert-NativeDataSourceFields {
    param($Actual, $Expected, [string]$Path)
    if ($Actual -isnot [pscustomobject]) { return }
    foreach ($property in $Actual.PSObject.Properties) {
        if ($Path -ceq 'datasources' -and $property.Name -cin @('@odata.etag', '@odata.context')) { continue }
        if ($Path -ceq 'datasources' -and $property.Name -ceq 'indexerPermissionOptions' -and
            $property.Value -is [array] -and $property.Value.Count -eq 0) { continue }
        if ($Expected.Keys -cnotcontains $property.Name) {
            if ($null -ne $property.Value) { Stop-NativeContract "$Path/$($property.Name)" }
        }
        elseif ($Expected[$property.Name] -is [System.Collections.IDictionary]) {
            Assert-NativeDataSourceFields $property.Value $Expected[$property.Name] "$Path/$($property.Name)"
        }
    }
}

function Get-NativeDataSourceHash {
    param($Definition)
    $canonical = [ordered]@{
        name = $Definition.name; type = $Definition.type
        credentials = [ordered]@{ connectionString = $Definition.credentials.connectionString }
        container = [ordered]@{ name = $Definition.container.name; query = $Definition.container.query }
        identity = [ordered]@{ '@odata.type' = $Definition.identity.'@odata.type'; userAssignedIdentity = $Definition.identity.userAssignedIdentity }
    } | ConvertTo-Json -Depth 10 -Compress
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return -join ($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $hasher.Dispose() }
}

function Assert-NativeReceiptPath {
    param([string]$Path)
    if ($Path -notmatch '\A[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) { throw 'Native datasource receipt requires a local filesystem path.' }
    $ancestor = $Path
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Native datasource receipt path must not contain links or reparse points.' }
            if ($ancestor -ceq $Path -and ($item.PSIsContainer -or $item.Length -gt 16384)) { throw 'Native datasource receipt must be a bounded regular file.' }
        }
        $ancestor = Split-Path -Path $ancestor -Parent
    }
}

function Get-NativeDataSourceReceipt {
    param($Definition, $Actual)
    $etag = Get-NativeProperty $Actual '@odata.etag'
    if ($etag -isnot [string] -or $etag -cnotmatch '\A"[^"\x00-\x20\x7f]+"\z') { Stop-NativeContract 'datasources/missing-or-invalid-etag' }
    return [ordered]@{
        receipt_version = 1; search_endpoint = $SearchEndpoint.TrimEnd('/'); datasource = $Definition.name
        storage_resource_id = $StorageResourceId; staging_container = $Definition.container.name; folder_path = $Definition.container.query
        ingestion_identity_resource_id = $Definition.identity.userAssignedIdentity
        desired_config_sha256 = Get-NativeDataSourceHash $Definition; server_etag = $etag
    }
}

function Test-NativeDataSourceReceipt {
    param($Expected, [switch]$AllowStaleETag)
    try {
        Assert-NativeReceiptPath $receiptPath
        $receiptJson = Get-Content -LiteralPath $receiptPath -Raw
        if (-not $receiptJson.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { return $false }
        $receipt = $receiptJson | ConvertFrom-Json
        if ($receipt -isnot [pscustomobject] -or @($receipt.PSObject.Properties).Count -ne $Expected.Count) { return $false }
        $version = Get-NativeProperty $receipt 'receipt_version'
        if (($version -isnot [int] -and $version -isnot [long]) -or $version -ne 1) { return $false }
        $etag = Get-NativeProperty $receipt 'server_etag'
        if ($etag -isnot [string] -or $etag -cnotmatch '\A"[^"\x00-\x20\x7f]+"\z') { return $false }
        foreach ($name in $Expected.Keys) {
            if ($name -cnotin @($receipt.PSObject.Properties.Name)) { return $false }
            if ($AllowStaleETag -and $name -ceq 'server_etag') { continue }
            Assert-NativeContract (Get-NativeProperty $receipt $name) $Expected[$name] "datasources/receipt/$name"
        }
        return $true
    }
    catch { return $false }
}

function Save-NativeDataSourceReceipt {
    param($Receipt)
    $temporaryPath = $null
    try {
        Assert-NativeReceiptPath $receiptPath
        $parent = Split-Path -Path $receiptPath -Parent
        $null = New-Item -Path $parent -ItemType Directory -Force
        Assert-NativeReceiptPath $receiptPath
        $temporaryPath = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporaryPath, ($Receipt | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
        }
        Set-Acl -LiteralPath $temporaryPath -AclObject $acl
        Assert-NativeReceiptPath $receiptPath
        if (Test-Path -LiteralPath $receiptPath) {
            Set-Acl -LiteralPath $receiptPath -AclObject $acl
            [IO.File]::Replace($temporaryPath, $receiptPath, [NullString]::Value)
        }
        else { [IO.File]::Move($temporaryPath, $receiptPath) }
        if (-not (Test-NativeDataSourceReceipt $Receipt)) { throw 'Receipt readback failed.' }
    }
    catch { throw 'Native datasource receipt could not be saved and verified. ACTION: repair the local receipt path and explicitly rerun with -RebindDataSource if GET credentials are null. No automatic retry.' }
    finally {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

$headers = @{}
$identityToken = $null
try {
    foreach ($value in $PSBoundParameters.Values) {
        if ($value -is [string] -and $value -match '[\r\n\x00]') { Stop-NativeContract 'input/control-characters' }
    }
    try {
        $schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json
        $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    }
    catch { throw 'Native knowledge initialization failed: cannot read or parse local contracts. No HTTP requests were made.' }
    Assert-NativeContract $schema @{ contractVersion = 2; owner = 'accelerator-native-indexer'; name = 'spo-native-index' } 'local-index-contract'
    Assert-NativeContract $contract @{
        contractVersion = 2; owner = 'accelerator-native-indexer'; apiVersion = '2026-08-01-preview'
        knowledgeSourceName = 'spo-native'; knowledgeBaseName = 'spo-native-knowledge-base'
        pipeline = @{ datasource = 'spo-native-datasource'; indexer = 'spo-native-indexer'; skillset = 'spo-native-skillset'; index = 'spo-native-index' }
        schedule = @{ interval = 'PT5M' }
        indexerParameters = @{ maxFailedItems = 0; configuration = @{
            executionEnvironment = 'private'; allowSkillsetToReadFileData = $true; parsingMode = 'default'; dataToExtract = 'storageMetadata'
        } }
    } 'local-ingestion-contract'
    Assert-NativeKeyless $schema
    Assert-NativeKeyless $contract
    if (([uri]$IngestionFoundryEndpoint).Host.Split('.')[0] -ine ([uri]$IngestionOpenAIEndpoint).Host.Split('.')[0]) { Stop-NativeContract 'ingestion-endpoints/must-identify-same-secondary-account' }
    if (([uri]$FoundryOpenAIEndpoint).Host -ieq ([uri]$IngestionOpenAIEndpoint).Host) { Stop-NativeContract 'planner-and-ingestion/must-use-distinct-accounts' }
    $pipeline = $contract.pipeline
    $ingestionIdentity = @{
        '@odata.type' = '#Microsoft.Azure.Search.DataUserAssignedIdentity'
        userAssignedIdentity = $IngestionIdentityResourceId
    }
    $embeddingParameters = @{
        resourceUri = $IngestionOpenAIEndpoint.TrimEnd('/'); deploymentId = $EmbeddingDeployment
        modelName = $EmbeddingModel; authIdentity = $ingestionIdentity
    }
    $index = @{ name = $pipeline.index; fields = $schema.fields; vectorSearch = $schema.vectorSearch; semantic = $schema.semantic }
    $index.vectorSearch.vectorizers[0].azureOpenAIParameters = $embeddingParameters
    $contentSkill = $contract.expectedContentUnderstanding
    $contentSkill | Add-Member -NotePropertyName modelDeployment -NotePropertyValue $IngestionChatDeployment
    $embeddingSkill = $contract.expectedEmbedding
    foreach ($name in @('resourceUri', 'deploymentId', 'authIdentity')) { $embeddingSkill | Add-Member -NotePropertyName $name -NotePropertyValue $embeddingParameters[$name] }
    Assert-NativeContract $contentSkill @{
        '@odata.type' = '#Microsoft.Skills.Util.ContentUnderstandingSkill'; modelName = $IngestionChatModel
        context = '/document'; extractionOptions = @('images', 'locationMetadata')
        chunkingProperties = @{ method = 'semantic'; unit = 'tokens'; maximumLength = 500; overlapLength = 0 }
        inputs = @(@{ name = 'file_data'; source = '/document/file_data' })
        outputs = @(@{ name = 'text_sections'; targetName = 'text_sections' }, @{ name = 'normalized_images'; targetName = 'normalized_images' })
    } 'local-content-understanding'
    Assert-NativeContract $embeddingSkill @{
        '@odata.type' = '#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill'; modelName = $EmbeddingModel
        context = '/document/text_sections/*'; dimensions = 3072
        inputs = @(@{ name = 'text'; source = '/document/text_sections/*/content' })
        outputs = @(@{ name = 'embedding'; targetName = 'text_vector' })
    } 'local-embedding'
    $source = @{
        name = $contract.knowledgeSourceName; kind = 'searchIndex'
        searchIndexParameters = @{
            searchIndexName = $pipeline.index
            sourceDataFields = @(@{ name = 'snippet' }, @{ name = 'doc_url' }, @{ name = 'snippet_parent_id' })
        }
    }
    $knowledgeBase = @{
        name = $contract.knowledgeBaseName; knowledgeSources = @(@{ name = $source.name })
        models = @(@{ kind = 'azureOpenAI'; azureOpenAIParameters = @{
            resourceUri = $FoundryOpenAIEndpoint.TrimEnd('/'); deploymentId = $PlannerDeployment; modelName = $PlannerModel
        } })
    }
    $desired = [ordered]@{
        datasources = @{
            name = $pipeline.datasource; type = 'azureblob'; credentials = @{ connectionString = "ResourceId=$StorageResourceId" }
            container = @{ name = $StagingContainer; query = $FolderPath }; identity = $ingestionIdentity
        }
        indexes = $index
        skillsets = @{
            name = $pipeline.skillset; skills = @($contentSkill, $embeddingSkill)
            cognitiveServices = @{
                '@odata.type' = '#Microsoft.Azure.Search.AIServicesByIdentity'
                subdomainUrl = $IngestionFoundryEndpoint.TrimEnd('/'); identity = $ingestionIdentity
            }
            indexProjections = @{
                parameters = @{ projectionMode = $schema.projection.projectionMode }
                selectors = @(@{
                    targetIndexName = $pipeline.index; parentKeyFieldName = $schema.projection.parentKeyFieldName
                    sourceContext = $schema.projection.sourceContext; mappings = $schema.projection.mappings
                })
            }
        }
        indexers = @{
            name = $pipeline.indexer; dataSourceName = $pipeline.datasource; targetIndexName = $pipeline.index; skillsetName = $pipeline.skillset
            schedule = $contract.schedule; parameters = $contract.indexerParameters
        }
        knowledgesources = $source
        knowledgebases = $knowledgeBase
    }
    foreach ($collection in $desired.Keys) { Assert-NativeResource $collection $desired[$collection] $desired[$collection] }
    if (-not $PSCmdlet.ShouldProcess($SearchEndpoint, 'Create missing native resources and, only with RebindDataSource or RefreshDataSourceBinding, conditionally bind matching datasource credentials')) { return }
    $receiptPath = [IO.Path]::GetFullPath($DataSourceReceiptPath)
    Assert-NativeReceiptPath $receiptPath
    try {
        $schemaHash = (Get-FileHash -LiteralPath $SchemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $contractHash = (Get-FileHash -LiteralPath $ContractPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch { throw 'Native knowledge initialization failed: cannot hash local contracts. No HTTP requests were made.' }
    try {
        $resource = [uri]::EscapeDataString('https://search.azure.com/')
        $identityToken = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource" `
            -Headers @{ Metadata = 'true' } -TimeoutSec 15 -MaximumRedirection 0 -Verbose:$false -Debug:$false
    }
    catch {
        $status = Get-NativeHttpStatus $_
        $statusLabel = if ($status) { [string]$status } else { 'unavailable' }
        throw "Native knowledge initialization failed: runner managed identity could not acquire a Search token (IMDS HTTP $statusLabel). Response body suppressed."
    }
    $token = Get-NativeProperty $identityToken 'access_token'
    if ($token -isnot [string] -or [string]::IsNullOrWhiteSpace($token) -or $token -match '[\r\n\x00]') { throw 'Native knowledge initialization failed: runner managed identity returned no usable Search token.' }
    $headers.Authorization = "Bearer $token"
    $existing = @{}
    foreach ($collection in @('knowledgesources', 'knowledgebases', 'datasources', 'indexes', 'skillsets', 'indexers')) {
        $expected = $desired[$collection]
        $existing[$collection] = Invoke-NativeSearch GET $collection $expected.name -AllowMissing
        if ($null -ne $existing[$collection]) { Assert-NativeResource $collection $existing[$collection] $expected -AllowRedactedCredential }
    }
    $dataSourceAction = 'reused-visible'
    $dataSourceReceiptStatus = 'not-required'
    $dataSourceETag = Get-NativeProperty $existing.datasources '@odata.etag'
    $rebind = $false
    $refresh = $false
    if ($null -ne $existing.datasources -and ($RebindDataSource -or $null -eq $existing.datasources.credentials.connectionString)) {
        $expectedReceipt = Get-NativeDataSourceReceipt $desired.datasources $existing.datasources
        if ($RebindDataSource) { $rebind = $true }
        elseif (Test-NativeDataSourceReceipt $expectedReceipt) { $dataSourceAction = 'reused-receipt'; $dataSourceReceiptStatus = 'matched' }
        elseif ($RefreshDataSourceBinding -and (Test-NativeDataSourceReceipt $expectedReceipt -AllowStaleETag)) { $rebind = $true; $refresh = $true }
        else { throw 'Native datasource credentials are null and no matching receipt binds this configuration and ETag. ACTION: rerun with -RebindDataSource to explicitly bind the desired storage using If-Match, or restore the matching -DataSourceReceiptPath. No writes were made.' }
    }
    foreach ($collection in $desired.Keys) {
        if ($null -ne $existing[$collection] -and -not ($collection -ceq 'datasources' -and $rebind)) { continue }
        $expected = $desired[$collection]
        if ($collection -ceq 'datasources' -and $rebind) { $putResult = Invoke-NativeSearch PUT $collection $expected.name $expected -IfMatch $dataSourceETag }
        else { $putResult = Invoke-NativeSearch PUT $collection $expected.name $expected }
        if ($collection -ceq 'datasources' -and $null -ne $putResult) { Assert-NativeResource $collection $putResult $expected -AllowRedactedCredential }
        $actual = Invoke-NativeSearch GET $collection $expected.name
        Assert-NativeResource $collection $actual $expected -AllowRedactedCredential
        if ($collection -ceq 'datasources') {
            $receipt = Get-NativeDataSourceReceipt $expected $actual
            $putETag = Get-NativeProperty $putResult '@odata.etag'
            if ($null -ne $putETag -and $putETag -cne $receipt.server_etag) { Stop-NativeContract 'datasources/put-readback-etag' }
            Save-NativeDataSourceReceipt $receipt
            $dataSourceETag = $receipt.server_etag
            $dataSourceAction = if ($refresh) { 'refreshed' } elseif ($rebind) { 'rebound' } else { 'created' }
            $dataSourceReceiptStatus = 'saved'
        }
    }
    $result = [pscustomobject]@{
        status = 'succeeded'; verification = 'configuration-only'; indexing_verified = $false
        api_version = $contract.apiVersion; search_endpoint = $SearchEndpoint.TrimEnd('/')
        index = $pipeline.index; knowledge_source = $source.name; knowledge_base = $knowledgeBase.name
        indexer = $pipeline.indexer; skillset = $pipeline.skillset; datasource = $pipeline.datasource
        datasource_action = $dataSourceAction; datasource_receipt_status = $dataSourceReceiptStatus
        datasource_receipt_path = $receiptPath; datasource_etag = $dataSourceETag
        schema_sha256 = $schemaHash; contract_sha256 = $contractHash; contract_version = 2; owner = 'accelerator-native-indexer'
        planner_deployment = $PlannerDeployment; planner_model = $PlannerModel; planner_endpoint = $FoundryOpenAIEndpoint.TrimEnd('/')
        storage_resource_id = $StorageResourceId; staging_container = $StagingContainer; folder_path = $FolderPath
        ingestion_identity_resource_id = $IngestionIdentityResourceId
        ingestion_foundry_endpoint = $IngestionFoundryEndpoint.TrimEnd('/'); ingestion_openai_endpoint = $IngestionOpenAIEndpoint.TrimEnd('/')
        ingestion_chat_deployment = $IngestionChatDeployment; ingestion_chat_model = $IngestionChatModel
        embedding_deployment = $EmbeddingDeployment; embedding_model = $EmbeddingModel; embedding_dimensions = 3072
        ingestion_schedule = 'PT5M'; document_url_source = $schema.projection.mappings[2].source
    }
    if ($AsJson) { $result | ConvertTo-Json -Depth 10 -Compress } else { $result }
}
finally { $headers.Clear(); $identityToken = $null; $token = $null }
