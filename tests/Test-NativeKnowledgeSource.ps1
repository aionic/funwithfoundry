[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$initializer = Join-Path $root 'scripts\Initialize-KnowledgeBase.ps1'
$receiptDirectory = Join-Path ([IO.Path]::GetTempPath()) ('native-receipt-' + [guid]::NewGuid().ToString('N'))
$receiptPath = Join-Path $receiptDirectory 'nested\receipt.json'
try {
$parameters = @{
    DataSourceReceiptPath = $receiptPath
    SearchEndpoint = 'https://test-search.search.windows.net'
    FoundryOpenAIEndpoint = 'https://primary.openai.azure.com'
    PlannerDeployment = 'planner'; PlannerModel = 'gpt-5.2'
    StorageResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/stagingtest'
    IngestionIdentityResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ingestion'
    IngestionFoundryEndpoint = 'https://secondary.services.ai.azure.com'
    IngestionOpenAIEndpoint = 'https://secondary.openai.azure.com'
    IngestionChatDeployment = 'gpt52-ingest'; IngestionChatModel = 'gpt-5.2'
    EmbeddingDeployment = 'embed-large'; EmbeddingModel = 'text-embedding-3-large'
}
$paths = @(
    'datasources/spo-native-datasource', 'indexes/spo-native-index', 'skillsets/spo-native-skillset',
    'indexers/spo-native-indexer', 'knowledgesources/spo-native', 'knowledgebases/spo-native-knowledge-base'
)
$state = @{
    Calls = [System.Collections.Generic.List[object]]::new(); Resources = @{}
    FailPath = ''; FailMethod = ''; FailureStatus = 0; BadRead = $false; AfterCreate = $null
    Token = 'DO-NOT-LEAK-TOKEN'; MissingTokenProperty = $false; Checks = 0; RedactDataSource = $false
    ExpectRebind = $false; PutResponseMode = 'visible'; ReceiptWriteFailure = $false
}
function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $state.Checks++
}
function az { throw 'Cloud CLI prohibited.' }
function terraform { throw 'Cloud CLI prohibited.' }
function Set-Acl {
    [CmdletBinding()]
    param($LiteralPath, $AclObject)
    if ($state.ReceiptWriteFailure) { throw 'DO-NOT-LEAK local ACL failure.' }
    Microsoft.PowerShell.Security\Set-Acl -LiteralPath $LiteralPath -AclObject $AclObject
}
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Headers, $Method = 'GET', $Body, $ContentType, $TimeoutSec, $MaximumRedirection)
    $state.Calls.Add(@{ Uri = $Uri; Method = $Method; Body = $Body; Headers = $Headers.Clone() })
    Assert-Check ($MaximumRedirection -eq 0) 'Redirects must be disabled.'
    if ($Uri -like 'http://169.254.169.254/*') {
        if ($state.MissingTokenProperty) { return [pscustomobject]@{} }
        return [pscustomobject]@{ access_token = $state.Token }
    }
    if ($Uri -notmatch '^https://test-search\.search\.windows\.net/(?<path>[a-z]+/[a-z0-9_-]+)\?api-version=2026-08-01-preview$') { throw 'Unscoped or unexpected request.' }
    $path = $Matches.path
    Assert-Check ($path -cin $paths) 'Only the six fixed resource addresses are allowed.'
    Assert-Check ($Method -cin @('GET', 'PUT')) 'No updates, deletes, runs or resets.'
    Assert-Check ($Headers.Authorization -ceq 'Bearer DO-NOT-LEAK-TOKEN') 'Search must use the runner token.'
    if ($state.FailPath -ceq $path -and $state.FailMethod -ceq $Method) {
        if ($state.BadRead) { return $null }
        $exception = New-Object System.Exception 'DO-NOT-LEAK-BODY'
        if ($state.FailureStatus) { $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $state.FailureStatus }) }
        throw $exception
    }
    if ($Method -eq 'PUT') {
        if ($state.Resources.ContainsKey($path)) {
            Assert-Check ($state.ExpectRebind -and $path -ceq $paths[0]) 'Only explicitly expected datasource rebinds may update.'
            Assert-Check ($Headers['If-Match'] -ceq $state.Resources[$path].'@odata.etag') 'Rebind must match the pre-read ETag.'
            Assert-Check (-not $Headers.ContainsKey('If-None-Match')) 'Rebind is not a conditional create.'
        }
        else {
            Assert-Check ($Headers['If-None-Match'] -ceq '*') 'Missing conditional-create protection.'
            Assert-Check (-not $Headers.ContainsKey('If-Match')) 'Missing resources require conditional create, even with rebind requested.'
        }
        $definition = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        Assert-Check ($definition.name -ceq $path.Split('/')[1]) 'Body and address name mismatch.'
        Assert-Check ($definition.PSObject.Properties.Name -cnotcontains '@odata.etag') 'ETag copied into create payload.'
        $dependencies = @{
            'skillsets/spo-native-skillset' = @('indexes/spo-native-index')
            'indexers/spo-native-indexer' = @('datasources/spo-native-datasource', 'indexes/spo-native-index', 'skillsets/spo-native-skillset')
            'knowledgesources/spo-native' = @('indexes/spo-native-index')
            'knowledgebases/spo-native-knowledge-base' = @('knowledgesources/spo-native')
        }
        foreach ($dependency in $dependencies[$path]) { Assert-Check ($state.Resources.ContainsKey($dependency)) 'Creation dependency missing.' }
        if ($path -ceq $paths[0]) {
            $etag = if ($state.Resources.ContainsKey($path)) { '"datasource-rebound"' } else { '"datasource-created"' }
            $definition | Add-Member -NotePropertyName '@odata.etag' -NotePropertyValue $etag
        }
        $state.Resources[$path] = $definition
        $putResponse = $definition | ConvertTo-Json -Depth 50 | ConvertFrom-Json
        if ($null -ne $state.AfterCreate) { & $state.AfterCreate $path }
        if ($path -ceq $paths[0]) {
            switch ($state.PutResponseMode) {
                'empty' { return }
                'noetag' { $putResponse.PSObject.Properties.Remove('@odata.etag') }
                'redacted' { $putResponse.credentials.connectionString = $null }
                'wrong' { $putResponse.container.name = 'wrong' }
            }
        }
        return $putResponse
    }
    if (-not $state.Resources.ContainsKey($path)) {
        $exception = New-Object System.Exception 'DO-NOT-LEAK-BODY'
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 404 })
        throw $exception
    }
    if ($state.Resources[$path] -isnot [pscustomobject]) { return $state.Resources[$path] }
    $readback = $state.Resources[$path] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    if ($state.RedactDataSource -and $path -ceq $paths[0]) { $readback.credentials.connectionString = $null }
    return $readback
}

$result = & $initializer @parameters
$createdReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
Assert-Check ($result.datasource_action -ceq 'created' -and $result.datasource_receipt_status -ceq 'saved') 'Fresh create must report a saved receipt.'
Assert-Check ($createdReceipt.server_etag -ceq '"datasource-created"' -and $createdReceipt.storage_resource_id -ceq $parameters.StorageResourceId) 'Fresh visible create must bind its current ETag and storage.'
Assert-Check ($createdReceipt.desired_config_sha256 -cmatch '^[0-9a-f]{64}$') 'Receipt requires SHA256.'
Assert-Check ((Get-Content -LiteralPath $receiptPath -Raw) -notmatch 'connectionString|DO-NOT-LEAK|AccountKey|Bearer') 'Receipt must not contain credentials or tokens.'
$receiptAcl = Get-Acl -LiteralPath $receiptPath
Assert-Check ($receiptAcl.AreAccessRulesProtected) 'Receipt ACL inheritance must be disabled.'
$trustedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
foreach ($rule in $receiptAcl.Access) {
    Assert-Check ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cin $trustedSids) 'Receipt must restrict access to owner, SYSTEM and Administrators.'
}
$writes = @($state.Calls | Where-Object Method -eq 'PUT')
$createOrder = @($writes | ForEach-Object { ([uri]$_.Uri).AbsolutePath.TrimStart('/') })
Assert-Check (($createOrder -join ',') -ceq ($paths -join ',')) 'Expected six native creates in dependency order.'
Assert-Check ($state.Calls.Count -eq 19) 'Expected one token, six pre-reads, six creates and six readbacks.'
$preReads = @($state.Calls | Select-Object -Skip 1 -First 6)
Assert-Check (@($preReads | Where-Object Method -ne 'GET').Count -eq 0) 'Every pre-read must precede the first write.'
Assert-Check ((@($preReads | ForEach-Object { ([uri]$_.Uri).AbsolutePath.TrimStart('/') } | Sort-Object) -join ',') -ceq (($paths | Sort-Object) -join ',')) 'Missing a preflight resource read.'
Assert-Check (([uri]$preReads[0].Uri).AbsolutePath -ceq '/knowledgesources/spo-native') 'Wrong-kind KS must be checked first.'
foreach ($name in @('index', 'indexer', 'skillset', 'datasource')) { Assert-Check ($result.$name -ceq "spo-native-$name") 'Output must retain fixed pipeline names.' }
Assert-Check ($result.knowledge_source -ceq 'spo-native' -and $result.knowledge_base -ceq 'spo-native-knowledge-base') 'Wrong KS/KB result.'
Assert-Check ($result.indexing_verified -eq $false -and $result.verification -ceq 'configuration-only') 'Do not claim indexing success.'
Assert-Check ($result.schema_sha256.Length -eq 64 -and $result.contract_sha256.Length -eq 64) 'Missing contract hashes.'
Assert-Check ($result.contract_version -eq 2 -and $result.owner -ceq 'accelerator-native-indexer') 'Wrong contract ownership.'
$source = $state.Resources['knowledgesources/spo-native']
Assert-Check ($source.kind -ceq 'searchIndex') 'KS must wrap the explicit index.'
Assert-Check ((@($source.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'kind,name,searchIndexParameters') 'Unexpected source properties.'
Assert-Check ($source.searchIndexParameters.searchIndexName -ceq 'spo-native-index') 'Wrong source index.'
Assert-Check (($source.searchIndexParameters.sourceDataFields.name -join ',') -ceq 'snippet,doc_url,snippet_parent_id') 'Wrong source fields.'
$datasource = $state.Resources['datasources/spo-native-datasource']
Assert-Check ($datasource.credentials.connectionString -ceq "ResourceId=$($parameters.StorageResourceId)") 'Storage must use resource-ID credentials.'
Assert-Check ($datasource.identity.userAssignedIdentity -ceq $parameters.IngestionIdentityResourceId) 'Storage identity missing.'
Assert-Check ($datasource.container.name -ceq 'spo-staging' -and $datasource.container.query -ceq 'native/') 'Staging scope mismatch.'
$indexer = $state.Resources['indexers/spo-native-indexer']
Assert-Check ($indexer.schedule.interval -ceq 'PT5M' -and $indexer.parameters.maxFailedItems -eq 0) 'Indexer schedule or failure policy mismatch.'
$configuration = $indexer.parameters.configuration
Assert-Check ($configuration.executionEnvironment -ceq 'private' -and $configuration.allowSkillsetToReadFileData -eq $true) 'Private file-data configuration missing.'
Assert-Check ($configuration.parsingMode -ceq 'default' -and $configuration.dataToExtract -ceq 'storageMetadata') 'CU must own content extraction.'
Assert-Check ((@($configuration.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'allowSkillsetToReadFileData,dataToExtract,executionEnvironment,parsingMode') 'Invented indexer configuration.'
$skillset = $state.Resources['skillsets/spo-native-skillset']
Assert-Check ($skillset.skills.Count -eq 2) 'Only CU and embedding skills are allowed.'
Assert-Check ($skillset.skills[0].modelName -ceq 'gpt-5.2' -and $skillset.skills[0].modelDeployment -ceq 'gpt52-ingest') 'Wrong CU model/deployment.'
Assert-Check ($skillset.skills[0].chunkingProperties.method -ceq 'semantic' -and $skillset.skills[0].chunkingProperties.maximumLength -eq 500 -and $skillset.skills[0].chunkingProperties.overlapLength -eq 0) 'Wrong chunking.'
Assert-Check ($skillset.skills[1].outputs[0].targetName -ceq 'text_vector' -and $skillset.skills[1].dimensions -eq 3072) 'Wrong embedding vector.'
Assert-Check ($skillset.cognitiveServices.'@odata.type' -ceq '#Microsoft.Azure.Search.AIServicesByIdentity') 'Billing must be keyless.'
Assert-Check ($skillset.cognitiveServices.subdomainUrl -ceq $parameters.IngestionFoundryEndpoint -and $skillset.cognitiveServices.identity.userAssignedIdentity -ceq $parameters.IngestionIdentityResourceId) 'Wrong secondary billing scope.'
Assert-Check ($skillset.indexProjections.selectors[0].mappings[2].source -ceq '/document/metadata_storage_path') 'Do not project an unproven original URL.'
$index = $state.Resources['indexes/spo-native-index']
Assert-Check ((@($index.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'fields,name,semantic,vectorSearch') 'Contract metadata leaked into REST payload.'
Assert-Check ($index.fields[0].analyzer -ceq 'keyword' -and $index.fields[0].key -eq $true) 'Child key requires keyword analyzer.'
Assert-Check ($index.fields[2].retrievable -eq $false -and $index.fields[2].dimensions -eq 3072) 'Wrong vector storage contract.'
Assert-Check ($index.vectorSearch.algorithms[0].kind -ceq 'hnsw' -and $index.vectorSearch.algorithms[0].hnswParameters.metric -ceq 'cosine') 'HNSW cosine is required.'
foreach ($model in @($skillset.skills[1], $index.vectorSearch.vectorizers[0].azureOpenAIParameters)) {
    Assert-Check ($model.resourceUri -ceq $parameters.IngestionOpenAIEndpoint -and $model.deploymentId -ceq 'embed-large') 'Embedding must use the secondary deployment.'
    Assert-Check ($model.authIdentity.userAssignedIdentity -ceq $parameters.IngestionIdentityResourceId) 'Embedding identity missing.'
}
foreach ($resource in $state.Resources.Values) { $resource | Add-Member -NotePropertyName '@odata.etag' -NotePropertyValue 'DO-NOT-COPY-ETAG' -Force }
$datasource.'@odata.etag' = '"datasource-existing"'
$datasource | Add-Member -NotePropertyName '@odata.context' -NotePropertyValue 'https://test-search.search.windows.net/$metadata#datasources/$entity'
$datasource | Add-Member -NotePropertyName 'indexerPermissionOptions' -NotePropertyValue @()
$baseline = $state.Resources | ConvertTo-Json -Depth 50

function Reset-NativeFixture {
    $state.Resources = @{}
    foreach ($property in ($baseline | ConvertFrom-Json).PSObject.Properties) { $state.Resources[$property.Name] = $property.Value }
    $state.Calls.Clear()
    $state.FailPath = ''; $state.FailMethod = ''; $state.FailureStatus = 0; $state.BadRead = $false; $state.AfterCreate = $null
    $state.Token = 'DO-NOT-LEAK-TOKEN'; $state.MissingTokenProperty = $false
    $state.RedactDataSource = $false
    $state.ExpectRebind = $false; $state.PutResponseMode = 'visible'; $state.ReceiptWriteFailure = $false
    $parameters.Remove('RebindDataSource')
    $parameters.Remove('RefreshDataSourceBinding')
    $parameters.DataSourceReceiptPath = $receiptPath
    if (Test-Path -LiteralPath $receiptDirectory) { Remove-Item -LiteralPath $receiptDirectory -Recurse -Force }
}
function Assert-NativeBlocked {
    param([string]$Label, [int]$ExpectedWrites = 0, [string]$ExpectedPath = '')
    $failure = $null
    try { $null = & $initializer @parameters } catch { $failure = $_.Exception.Message }
    Assert-Check (-not [string]::IsNullOrWhiteSpace($failure)) "Did not block: $Label"
    Assert-Check ($failure -notmatch 'DO-NOT-LEAK|DO-NOT-COPY') "Leaked diagnostic: $Label"
    if ($ExpectedPath) { Assert-Check ($failure.Contains($ExpectedPath)) "Wrong blocker for ${Label}: $failure" }
    Assert-Check (@($state.Calls | Where-Object Method -eq 'PUT').Count -eq $ExpectedWrites) "Unexpected writes: $Label"
}

Reset-NativeFixture
$beforeReuse = $state.Resources | ConvertTo-Json -Depth 50
$null = & $initializer @parameters
Assert-Check (@($state.Calls | Where-Object Method -eq 'PUT').Count -eq 0) 'Rerun must be read-only.'
Assert-Check (($state.Resources | ConvertTo-Json -Depth 50) -ceq $beforeReuse) 'Readback verification mutated existing objects.'
Reset-NativeFixture
$state.Resources[$paths[0]].indexerPermissionOptions = @('userIds')
Assert-NativeBlocked 'Unexpected permission options' -ExpectedPath 'datasources/indexerPermissionOptions'
Reset-NativeFixture
$null = & $initializer @parameters -WhatIf
Assert-Check ($state.Calls.Count -eq 0) 'WhatIf must be cloud-free.'
Reset-NativeFixture
$jsonResult = & $initializer @parameters -AsJson | ConvertFrom-Json
Assert-Check ($jsonResult.schema_sha256 -ceq $result.schema_sha256 -and $jsonResult.contract_sha256 -ceq $result.contract_sha256) 'JSON output lost hashes.'

$mutations = [ordered]@{
    'source-kind' = { $state.Resources[$paths[4]].kind = 'azureBlob' }
    'source-name' = { $state.Resources[$paths[4]].name = 'other-source' }
    'source-index' = { $state.Resources[$paths[4]].searchIndexParameters.searchIndexName = 'wrong' }
    'source-fields' = { $state.Resources[$paths[4]].searchIndexParameters.sourceDataFields[0].name = 'wrong' }
    'source-generated-parameters' = { $state.Resources[$paths[4]] | Add-Member azureBlobParameters ([pscustomobject]@{ connectionString = 'DO-NOT-LEAK-KEY' }) }
    'source-network-mode' = { $state.Resources[$paths[4]] | Add-Member networkAccessMode 'private' }
    'source-filter' = { $state.Resources[$paths[4]].searchIndexParameters | Add-Member baseFilter 'snippet eq 1' }
    'datasource-type' = { $state.Resources[$paths[0]].type = 'azuresql' }
    'datasource-identity' = { $state.Resources[$paths[0]].identity = $null }
    'datasource-container' = { $state.Resources[$paths[0]].container.name = 'wrong' }
    'datasource-query' = { $state.Resources[$paths[0]].container.query = '' }
    'datasource-storage' = { $state.Resources[$paths[0]].credentials.connectionString = 'AccountKey=DO-NOT-LEAK-KEY' }
    'datasource-redacted' = { $state.Resources[$paths[0]].credentials.connectionString = '<REDACTED>' }
    'datasource-wrong-resource-id' = { $state.Resources[$paths[0]].credentials.connectionString = 'ResourceId=/wrong' }
    'datasource-sas' = { $state.Resources[$paths[0]].credentials.connectionString = 'SharedAccessSignature=DO-NOT-LEAK-KEY' }
    'datasource-empty' = { $state.Resources[$paths[0]].credentials.connectionString = '' }
    'datasource-missing-credentials' = { $state.Resources[$paths[0]].PSObject.Properties.Remove('credentials') }
    'datasource-missing-connection-string' = { $state.Resources[$paths[0]].credentials.PSObject.Properties.Remove('connectionString') }
    'datasource-policy' = { $state.Resources[$paths[0]] | Add-Member dataDeletionDetectionPolicy ([pscustomobject]@{ '@odata.type' = '#Microsoft.Azure.Search.NativeBlobSoftDeleteDeletionDetectionPolicy' }) }
    'datasource-description' = { $state.Resources[$paths[0]] | Add-Member description 'Do not replace this configuration' }
    'public-indexer' = { $state.Resources[$paths[3]].parameters.configuration.executionEnvironment = 'standard' }
    'file-data' = { $state.Resources[$paths[3]].parameters.configuration.allowSkillsetToReadFileData = $false }
    'parsing-mode' = { $state.Resources[$paths[3]].parameters.configuration.parsingMode = 'json' }
    'data-to-extract' = { $state.Resources[$paths[3]].parameters.configuration.dataToExtract = 'contentAndMetadata' }
    'failed-items' = { $state.Resources[$paths[3]].parameters.maxFailedItems = -1 }
    'indexer-source-link' = { $state.Resources[$paths[3]].dataSourceName = 'wrong' }
    'indexer-skillset-link' = { $state.Resources[$paths[3]].skillsetName = 'wrong' }
    'indexer-index-link' = { $state.Resources[$paths[3]].targetIndexName = 'wrong' }
    'indexer-schedule' = { $state.Resources[$paths[3]].schedule.interval = 'PT1H' }
    'disabled-indexer' = { $state.Resources[$paths[3]] | Add-Member disabled $true }
    'indexer-url-override' = { $state.Resources[$paths[3]] | Add-Member fieldMappings @([pscustomobject]@{ sourceFieldName = 'originalURL'; targetFieldName = 'doc_url' }) }
    'indexer-output-override' = { $state.Resources[$paths[3]] | Add-Member outputFieldMappings @([pscustomobject]@{ sourceFieldName = '/document/content'; targetFieldName = 'snippet' }) }
    'custom-skill' = { $state.Resources[$paths[2]].skills += [pscustomobject]@{ '@odata.type' = '#Microsoft.Skills.Custom.WebApiSkill' } }
    'wrong-skill-type' = { $state.Resources[$paths[2]].skills[0].'@odata.type' = '#Microsoft.Skills.Text.SplitSkill' }
    'chunking-method' = { $state.Resources[$paths[2]].skills[0].chunkingProperties.method = 'fixedSize' }
    'chunking-units' = { $state.Resources[$paths[2]].skills[0].chunkingProperties.unit = 'characters' }
    'chunking-length' = { $state.Resources[$paths[2]].skills[0].chunkingProperties.maximumLength = 2000 }
    'chunking-overlap' = { $state.Resources[$paths[2]].skills[0].chunkingProperties.overlapLength = 50 }
    'chunking-overlap-string' = { $state.Resources[$paths[2]].skills[0].chunkingProperties.overlapLength = '0' }
    'chunking-overlap-boolean' = { $state.Resources[$paths[2]].skills[0].chunkingProperties.overlapLength = $false }
    'cu-chat-model' = { $state.Resources[$paths[2]].skills[0].modelName = 'gpt-4.1' }
    'cu-chat-deployment' = { $state.Resources[$paths[2]].skills[0].modelDeployment = 'wrong' }
    'cu-images' = { $state.Resources[$paths[2]].skills[0].extractionOptions = @('locationMetadata') }
    'cu-file-input' = { $state.Resources[$paths[2]].skills[0].inputs[0].source = '/document/content' }
    'cu-output' = { $state.Resources[$paths[2]].skills[0].outputs[0].targetName = 'wrong' }
    'embedding-context' = { $state.Resources[$paths[2]].skills[1].context = '/document' }
    'embedding-input' = { $state.Resources[$paths[2]].skills[1].inputs[0].source = '/document/content' }
    'embedding-alias' = { $state.Resources[$paths[2]].skills[1].outputs[0].targetName = 'embedding' }
    'embedding-outputs' = { $state.Resources[$paths[2]].skills[1].outputs = @() }
    'embedding-dimensions' = { $state.Resources[$paths[2]].skills[1].dimensions = 1536 }
    'embedding-model' = { $state.Resources[$paths[2]].skills[1].modelName = 'text-embedding-3-small' }
    'embedding-host' = { $state.Resources[$paths[2]].skills[1].resourceUri = $parameters.FoundryOpenAIEndpoint }
    'embedding-identity' = { $state.Resources[$paths[2]].skills[1].authIdentity = $null }
    'billing-type' = { $state.Resources[$paths[2]].cognitiveServices.'@odata.type' = '#Microsoft.Azure.Search.AIServicesByKey' }
    'billing-identity' = { $state.Resources[$paths[2]].cognitiveServices.identity = $null }
    'billing-endpoint' = { $state.Resources[$paths[2]].cognitiveServices.subdomainUrl = 'https://wrong.services.ai.azure.com' }
    'billing-key' = { $state.Resources[$paths[2]].cognitiveServices | Add-Member key 'DO-NOT-LEAK-KEY' }
    'projection-mode' = { $state.Resources[$paths[2]].indexProjections.parameters.projectionMode = 'includeIndexingParentDocuments' }
    'projection-target' = { $state.Resources[$paths[2]].indexProjections.selectors[0].targetIndexName = 'wrong' }
    'projection-parent' = { $state.Resources[$paths[2]].indexProjections.selectors[0].parentKeyFieldName = 'wrong' }
    'projection-context' = { $state.Resources[$paths[2]].indexProjections.selectors[0].sourceContext = '/document' }
    'projection-snippet' = { $state.Resources[$paths[2]].indexProjections.selectors[0].mappings[0].source = '/document/content' }
    'projection-vector' = { $state.Resources[$paths[2]].indexProjections.selectors[0].mappings[1].source = '/document/embedding' }
    'projection-url' = { $state.Resources[$paths[2]].indexProjections.selectors[0].mappings[2].source = '/document/originalURL' }
    'projection-extra-parent' = { $state.Resources[$paths[2]].indexProjections.selectors[0].mappings += [pscustomobject]@{ name = 'snippet_parent_id'; source = '/document/source_id' } }
    'projection-transform' = { $state.Resources[$paths[2]].indexProjections.selectors[0].mappings[0] | Add-Member inputs @([pscustomobject]@{ name = 'text'; source = '/document/wrong' }) }
    'cu-input-transform' = { $state.Resources[$paths[2]].skills[0].inputs[0] | Add-Member mappingFunction ([pscustomobject]@{ name = 'base64Encode' }) }
    'knowledge-store' = { $state.Resources[$paths[2]] | Add-Member knowledgeStore ([pscustomobject]@{ storageConnectionString = 'DO-NOT-LEAK-KEY' }) }
    'index-field-missing' = { $state.Resources[$paths[1]].fields = @($state.Resources[$paths[1]].fields | Where-Object name -ne 'snippet') }
    'index-key-count' = { $state.Resources[$paths[1]].fields[0].key = $false }
    'index-key-name' = { $state.Resources[$paths[1]].fields[0].name = 'other_id' }
    'index-key-analyzer' = { $state.Resources[$paths[1]].fields[0].analyzer = 'standard.lucene' }
    'index-url-filter' = { $state.Resources[$paths[1]].fields[3].filterable = $false }
    'index-parent-filter' = { $state.Resources[$paths[1]].fields[4].filterable = $false }
    'index-dimensions' = { $state.Resources[$paths[1]].fields[2].dimensions = 1536 }
    'index-dimensions-type' = { $state.Resources[$paths[1]].fields[2].dimensions = '3072' }
    'index-vector-retrievable' = { $state.Resources[$paths[1]].fields[2].retrievable = $true }
    'index-vector-profile' = { $state.Resources[$paths[1]].fields[2].vectorSearchProfile = 'missing' }
    'index-vector-metric' = { $state.Resources[$paths[1]].vectorSearch.algorithms[0].hnswParameters.metric = 'euclidean' }
    'index-vectorizer-host' = { $state.Resources[$paths[1]].vectorSearch.vectorizers[0].azureOpenAIParameters.resourceUri = $parameters.FoundryOpenAIEndpoint }
    'index-vectorizer-identity' = { $state.Resources[$paths[1]].vectorSearch.vectorizers[0].azureOpenAIParameters.authIdentity = $null }
    'index-semantic' = { $state.Resources[$paths[1]].semantic.configurations[0].prioritizedFields.prioritizedContentFields[0].fieldName = 'wrong' }
    'kb-planner-host' = { $state.Resources[$paths[5]].models[0].azureOpenAIParameters.resourceUri = $parameters.IngestionOpenAIEndpoint }
    'kb-planner-identity' = { $state.Resources[$paths[5]].models[0].azureOpenAIParameters | Add-Member authIdentity ([pscustomobject]@{ userAssignedIdentity = '/wrong' }) }
    'kb-source' = { $state.Resources[$paths[5]].knowledgeSources[0].name = 'other' }
}
foreach ($label in $mutations.Keys) {
    Reset-NativeFixture
    & $mutations[$label]
    Assert-NativeBlocked $label -ExpectedPath 'Native knowledge source blocked:'
    Reset-NativeFixture
    $state.RedactDataSource = -not $label.StartsWith('datasource-')
    $parameters.RebindDataSource = $true
    & $mutations[$label]
    Assert-NativeBlocked "rebind must not overwrite drift: $label" -ExpectedPath 'Native knowledge source blocked:'
}
foreach ($path in $paths) {
    Reset-NativeFixture
    $state.Resources.Remove($path)
    $null = & $initializer @parameters
    $writes = @($state.Calls | Where-Object Method -eq 'PUT')
    Assert-Check ($writes.Count -eq 1 -and ([uri]$writes[0].Uri).AbsolutePath -ceq "/$path") 'Create only the missing member.'
    Reset-NativeFixture
    $retained = $state.Resources[$path]
    $state.Resources.Clear()
    $state.Resources[$path] = $retained
    $retained.name = 'wrong'
    Assert-NativeBlocked "existing mismatch before any create: $path" -ExpectedPath 'Native knowledge source blocked:'
    foreach ($status in @(0, 400, 401, 403, 429, 500)) {
        Reset-NativeFixture
        $state.Resources.Clear()
        $state.FailPath = $path; $state.FailMethod = 'GET'; $state.FailureStatus = $status
        $statusLabel = if ($status) { [string]$status } else { 'unavailable' }
        Assert-NativeBlocked "read error: $path" -ExpectedPath "GET $path (HTTP $statusLabel)"
    }
    Reset-NativeFixture
    $state.Resources.Clear()
    $state.FailPath = $path; $state.FailMethod = 'GET'; $state.BadRead = $true
    Assert-NativeBlocked "empty read: $path" -ExpectedPath 'empty-or-malformed-readback'
    foreach ($status in @(409, 412)) {
        Reset-NativeFixture
        $state.Resources.Clear()
        $state.FailPath = $path; $state.FailMethod = 'PUT'; $state.FailureStatus = $status
        Assert-NativeBlocked "create race: $path" -ExpectedWrites (1 + [array]::IndexOf($paths, $path)) -ExpectedPath "PUT $path (HTTP $status)"
    }
    Reset-NativeFixture
    $state.Resources.Clear()
    $state.AfterCreate = { param($createdPath) if ($createdPath -ceq $path) { $state.Resources[$createdPath].name = 'wrong' } }.GetNewClosure()
    Assert-NativeBlocked "readback mismatch: $path" -ExpectedWrites (1 + [array]::IndexOf($paths, $path)) -ExpectedPath 'Native knowledge source blocked:'
    Reset-NativeFixture
    $state.Resources.Clear()
    $state.AfterCreate = { param($createdPath) if ($createdPath -ceq $path) { $state.Resources.Remove($createdPath) } }.GetNewClosure()
    Assert-NativeBlocked "missing readback: $path" -ExpectedWrites (1 + [array]::IndexOf($paths, $path)) -ExpectedPath "GET $path (HTTP 404)"
}
foreach ($token in @($null, '', ' ', 123, "bad`ntoken")) {
    Reset-NativeFixture
    $state.Token = $token
    Assert-NativeBlocked 'unusable token' -ExpectedPath 'no usable Search token'
    Assert-Check ($state.Calls.Count -eq 1) 'No Search call with unusable token.'
}
Reset-NativeFixture
$state.MissingTokenProperty = $true
Assert-NativeBlocked 'missing token property' -ExpectedPath 'no usable Search token'
Reset-NativeFixture
$state.Resources[$paths[1]] = '<malformed>'
Assert-NativeBlocked 'malformed read' -ExpectedPath 'empty-or-malformed-readback'
Reset-NativeFixture
$state.Resources[$paths[4]].kind = 'azureBlob'
$state.Resources.Remove($paths[0])
Assert-NativeBlocked 'legacy source with missing datasource' -ExpectedPath 'knowledgesources/kind'
Assert-Check ($state.Calls.Count -eq 2) 'Wrong-kind source must stop immediately after its pre-read.'
Reset-NativeFixture
$state.Resources[$paths[1]].fields += [pscustomobject]@{ name = 'originalURL'; type = 'Edm.String'; retrievable = $true }
$state.Resources[$paths[3]] | Add-Member fieldMappings @()
$state.Resources[$paths[3]] | Add-Member outputFieldMappings @()
$state.Resources[$paths[2]].skills[0].inputs[0] | Add-Member inputs @()
$state.Resources[$paths[2]].skills[0].chunkingProperties.overlapLength = [double]0
$state.Resources[$paths[1]].fields[2].dimensions = [double]3072
$state.Resources[$paths[0]] | Add-Member dataDeletionDetectionPolicy $null
$null = & $initializer @parameters
Assert-Check (@($state.Calls | Where-Object Method -eq 'PUT').Count -eq 0) 'Benign provider extras must be read-only.'

$invalidInputs = @(
    @('SearchEndpoint', 'https://other.example'), @('SearchEndpoint', 'https://test-search.search.windows.net/path'),
    @('SearchEndpoint', "https://test-search.search.windows.net`n"), @('FoundryOpenAIEndpoint', 'https://primary.cognitiveservices.azure.com'),
    @('FoundryOpenAIEndpoint', 'https://secondary.openai.azure.com'), @('IngestionFoundryEndpoint', 'https://wrong.services.ai.azure.com'),
    @('IngestionOpenAIEndpoint', 'https://user@secondary.openai.azure.com'), @('IngestionChatModel', 'gpt-4o'),
    @('EmbeddingModel', 'text-embedding-3-small'), @('StorageResourceId', 'AccountKey=not-a-resource-id'),
    @('IngestionIdentityResourceId', '/wrong/identity'), @('StagingContainer', 'other--container'),
    @('FolderPath', '../'), @('PlannerDeployment', '-Command')
)
foreach ($invalid in $invalidInputs) {
    Reset-NativeFixture
    $invalidParameters = $parameters.Clone()
    $invalidParameters[$invalid[0]] = $invalid[1]
    $blocked = $false
    try { $null = & $initializer @invalidParameters } catch { $blocked = $true }
    Assert-Check ($blocked -and $state.Calls.Count -eq 0) "Invalid input not rejected before authentication: $($invalid[0])"
}
Reset-NativeFixture
. $initializer @parameters -WhatIf
foreach ($address in $paths) {
    $collection, $resourceName = $address.Split('/')
    foreach ($invalidName in @('other-resource', '../index', "$resourceName/run", "${resourceName}`n", 'https://foreign.example')) {
        $failure = ''
        try { $null = Invoke-NativeSearch PUT $collection $invalidName @{ name = $invalidName } } catch { $failure = $_.Exception.Message }
        Assert-Check ($failure.Contains('resource-address')) 'HTTP helper must reject noncanonical names itself.'
    }
    $failure = ''
    try { $null = Invoke-NativeSearch PUT $collection $resourceName @{ name = 'wrong' } } catch { $failure = $_.Exception.Message }
    Assert-Check ($failure.Contains('resource-body-name')) 'HTTP helper must reject mismatched body names itself.'
}
foreach ($collection in @('documents', 'indexes/spo-native-index/docs', 'Indexes', 'aliases')) {
    $failure = ''
    try { $null = Invoke-NativeSearch PUT $collection 'spo-native-index' @{ name = 'spo-native-index' } } catch { $failure = $_.Exception.Message }
    Assert-Check ($failure.Contains('resource-address')) 'HTTP helper must reject noncanonical collections itself.'
}
Assert-Check ($state.Calls.Count -eq 0) 'Address validation must not call HTTP.'
Reset-NativeFixture
$state.Resources.Clear()
$state.RedactDataSource = $true
$result = & $initializer @parameters
Assert-Check (@($state.Calls | Where-Object Method -eq 'PUT').Count -eq 6) 'Null credential readback after a fresh create must succeed.'
$savedReceipt = Get-Content -LiteralPath $receiptPath -Raw
Assert-Check ($result.datasource_receipt_path -ceq $receiptPath -and $result.datasource_etag -ceq '"datasource-created"') 'Result returns receipt path and ETag.'
$state.Calls.Clear()
$result = & $initializer @parameters
Assert-Check ($result.datasource_action -ceq 'reused-receipt' -and $result.datasource_receipt_status -ceq 'matched') 'Null GET may reuse its exact receipt.'
Assert-Check (@($state.Calls | Where-Object Method -eq 'PUT').Count -eq 0) 'Receipt reuse never writes Search.'
Assert-Check ((Get-Content -LiteralPath $receiptPath -Raw) -ceq $savedReceipt) 'Receipt reuse is read-only locally.'

Reset-NativeFixture
$state.RedactDataSource = $true
Assert-NativeBlocked 'unbound existing null credentials' -ExpectedPath 'ACTION: rerun with -RebindDataSource'
Assert-Check ($state.Calls.Count -eq 7 -and -not (Test-Path -LiteralPath $receiptPath)) 'All pre-reads complete without receipt creation.'
$parameters.RebindDataSource = $true
$state.ExpectRebind = $true
$state.Calls.Clear()
$result = & $initializer @parameters
$writes = @($state.Calls | Where-Object Method -eq 'PUT')
Assert-Check ($result.datasource_action -ceq 'rebound' -and $writes.Count -eq 1) 'Explicit null rebind changes only datasource.'
Assert-Check (@($state.Calls | Select-Object -Skip 1 -First 6 | Where-Object Method -ne 'GET').Count -eq 0) 'Rebind must follow all six pre-reads.'
$reboundBody = [Text.Encoding]::UTF8.GetString($writes[0].Body) | ConvertFrom-Json
Assert-Check ($reboundBody.credentials.connectionString -ceq "ResourceId=$($parameters.StorageResourceId)") 'Rebind sends exact desired keyless credentials.'
Assert-Check ($writes[0].Headers['If-Match'] -ceq '"datasource-existing"' -and -not $writes[0].Headers.ContainsKey('If-None-Match')) 'Explicit rebind is ETag-conditional only.'
Assert-Check ($result.datasource_etag -ceq '"datasource-rebound"') 'Rebind stores post-PUT ETag.'
$receiptBaseline = Get-Content -LiteralPath $receiptPath -Raw

function Reset-BoundNativeFixture {
    Reset-NativeFixture
    $state.RedactDataSource = $true
    $state.ExpectRebind = $true
    $parameters.RefreshDataSourceBinding = $true
    $null = New-Item -Path (Split-Path $receiptPath -Parent) -ItemType Directory -Force
    Set-Content -LiteralPath $receiptPath -Value $receiptBaseline
    $state.Resources[$paths[0]].'@odata.etag' = '"indexer-updated"'
}
Reset-BoundNativeFixture
$result = & $initializer @parameters
$writes = @($state.Calls | Where-Object Method -eq 'PUT')
Assert-Check ($result.datasource_action -ceq 'refreshed' -and $writes.Count -eq 1) 'Stale bound credentials require exactly one refresh PUT.'
Assert-Check ($writes[0].Headers['If-Match'] -ceq '"indexer-updated"') 'Refresh uses the current GET ETag, not the old receipt ETag.'
$refreshBody = [Text.Encoding]::UTF8.GetString($writes[0].Body) | ConvertFrom-Json
Assert-Check ((Get-NativeDataSourceHash $refreshBody) -ceq ($receiptBaseline | ConvertFrom-Json).desired_config_sha256) 'Refresh sends every exact desired datasource binding field.'
Assert-Check (($refreshBody.PSObject.Properties.Name | Sort-Object) -join ',' -ceq 'container,credentials,identity,name,type') 'Refresh does not copy server metadata or extra fields into the PUT.'
Assert-Check (($refreshBody.credentials.PSObject.Properties.Name -join ',') -ceq 'connectionString' -and
    (($refreshBody.container.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'name,query' -and
    (($refreshBody.identity.PSObject.Properties.Name | Sort-Object) -join ',') -ceq '@odata.type,userAssignedIdentity') 'Refresh payload has only the exact desired nested fields.'
Assert-Check ($state.Calls.Count -eq 9 -and @($state.Calls | Select-Object -Skip 1 -First 6 | Where-Object Method -ne 'GET').Count -eq 0) 'Refresh follows all six pre-reads and reads back once.'
Assert-Check ((@($state.Calls | Select-Object -Skip 1 -First 6 | ForEach-Object { ([uri]$_.Uri).AbsolutePath.TrimStart('/') } | Sort-Object) -join ',') -ceq (($paths | Sort-Object) -join ',')) 'Refresh validates each of the six distinct resource definitions before writing.'
$refreshedReceipt = Get-Content -LiteralPath $receiptPath -Raw
Assert-Check (($refreshedReceipt | ConvertFrom-Json).server_etag -ceq $result.datasource_etag -and $result.datasource_receipt_status -ceq 'saved') 'Refresh saves the verified readback ETag.'
$state.Calls.Clear()
$result = & $initializer @parameters
Assert-Check ($result.datasource_action -ceq 'reused-receipt' -and $state.Calls.Count -eq 7) 'Matching refresh receipt performs only authentication and six reads.'
Assert-Check ((Get-Content -LiteralPath $receiptPath -Raw) -ceq $refreshedReceipt) 'Matching refresh receipt is not rewritten.'

foreach ($label in $mutations.Keys) {
    Reset-BoundNativeFixture
    $state.RedactDataSource = -not $label.StartsWith('datasource-')
    & $mutations[$label]
    Assert-NativeBlocked "refresh must not overwrite drift: $label" -ExpectedPath 'Native knowledge source blocked:'
}
foreach ($field in @('receipt_version', 'search_endpoint', 'datasource', 'storage_resource_id', 'staging_container', 'folder_path', 'ingestion_identity_resource_id', 'desired_config_sha256', 'server_etag')) {
    foreach ($mode in @('wrong', 'missing')) {
        Reset-BoundNativeFixture
        $receipt = $receiptBaseline | ConvertFrom-Json
        if ($mode -eq 'wrong') { $receipt.$field = 'wrong' } else { $receipt.PSObject.Properties.Remove($field) }
        $receipt | ConvertTo-Json -Compress | Set-Content -LiteralPath $receiptPath
        Assert-NativeBlocked "refresh receipt $mode $field" -ExpectedPath 'ACTION:'
    }
}
foreach ($mode in @('missing', 'malformed', 'empty', 'array', 'extra-field', 'renamed-field', 'oversize', 'directory')) {
    Reset-BoundNativeFixture
    switch ($mode) {
        'missing' { Remove-Item -LiteralPath $receiptPath -Force }
        'malformed' { Set-Content -LiteralPath $receiptPath -Value '{DO-NOT-LEAK' }
        'empty' { Set-Content -LiteralPath $receiptPath -Value '' }
        'array' { Set-Content -LiteralPath $receiptPath -Value "[$receiptBaseline]" }
        'extra-field' { $receipt = $receiptBaseline | ConvertFrom-Json; $receipt | Add-Member untrusted 'value'; $receipt | ConvertTo-Json | Set-Content -LiteralPath $receiptPath }
        'renamed-field' { Set-Content -LiteralPath $receiptPath -Value $receiptBaseline.Replace('server_etag', 'SERVER_ETAG') }
        'oversize' { Set-Content -LiteralPath $receiptPath -Value ($receiptBaseline + (' ' * 16385)) }
        'directory' { Remove-Item -LiteralPath $receiptPath -Force; $null = New-Item -Path $receiptPath -ItemType Directory }
    }
    Assert-NativeBlocked "refresh receipt $mode"
    if ($mode -notin @('oversize', 'directory')) {
        $parameters.RebindDataSource = $true
        $state.Calls.Clear()
        $result = & $initializer @parameters
        Assert-Check ($result.datasource_action -ceq 'rebound') 'Explicit rebind remains the recovery gate for missing or malformed receipts.'
    }
}
foreach ($etag in @($null, '', '*', 'W/"weak"', 'unquoted', '""', '"with space"', "`"bad`netag`"", @('"array"'))) {
    Reset-BoundNativeFixture
    $receipt = $receiptBaseline | ConvertFrom-Json
    $receipt.server_etag = $etag
    $receipt | ConvertTo-Json -Compress | Set-Content -LiteralPath $receiptPath
    Assert-NativeBlocked 'refresh invalid prior ETag' -ExpectedPath 'ACTION:'
    Reset-BoundNativeFixture
    $state.Resources[$paths[0]].'@odata.etag' = $etag
    Assert-NativeBlocked 'refresh invalid current ETag' -ExpectedPath 'etag'
}
foreach ($mode in @('412', '413', '429', '500', '404-readback', 'etag-race', 'storage-readback', 'identity-readback', 'wrong-response', 'write-failure')) {
    Reset-BoundNativeFixture
    $oldReceipt = Get-Content -LiteralPath $receiptPath -Raw
    switch ($mode) {
        { $_ -in @('412', '413', '429', '500') } { $state.FailPath = $paths[0]; $state.FailMethod = 'PUT'; $state.FailureStatus = [int]$mode }
        '404-readback' { $state.AfterCreate = { param($path) $state.Resources.Remove($path) } }
        'etag-race' { $state.AfterCreate = { param($path) $state.Resources[$path].'@odata.etag' = '"raced"' } }
        'storage-readback' { $state.AfterCreate = { param($path) $state.RedactDataSource = $false; $state.Resources[$path].credentials.connectionString = 'ResourceId=/wrong' } }
        'identity-readback' { $state.AfterCreate = { param($path) $state.Resources[$path].identity.userAssignedIdentity = '/wrong' } }
        'wrong-response' { $state.PutResponseMode = 'wrong' }
        'write-failure' { $state.ReceiptWriteFailure = $true }
    }
    Assert-NativeBlocked "failed refresh $mode" -ExpectedWrites 1
    Assert-Check ((Get-Content -LiteralPath $receiptPath -Raw) -ceq $oldReceipt) "Failed refresh $mode must not update or claim a verified receipt."
}
foreach ($path in $paths) {
    Reset-BoundNativeFixture
    $state.FailPath = $path; $state.FailMethod = 'GET'; $state.FailureStatus = 403
    Assert-NativeBlocked "refresh pre-read failed: $path" -ExpectedPath "GET $path (HTTP 403)"
}
Reset-BoundNativeFixture
$parameters.Remove('RefreshDataSourceBinding')
Assert-NativeBlocked 'standalone stale receipt stays strict' -ExpectedPath 'ACTION:'
Reset-BoundNativeFixture
$state.RedactDataSource = $false
$result = & $initializer @parameters
Assert-Check ($result.datasource_action -ceq 'reused-visible' -and $state.Calls.Count -eq 7) 'Refresh never rewrites already visible correct credentials.'
Reset-BoundNativeFixture
$null = & $initializer @parameters -WhatIf
Assert-Check ($state.Calls.Count -eq 0) 'Refresh WhatIf never calls HTTP.'

Reset-NativeFixture
$state.ExpectRebind = $true
$parameters.RebindDataSource = $true
$result = & $initializer @parameters
Assert-Check ($result.datasource_action -ceq 'rebound' -and @($state.Calls | Where-Object Method -eq 'PUT').Count -eq 1) 'Explicit rebind also accepts exact visible ResourceId credentials.'
$state.Calls.Clear()
$state.RedactDataSource = $true
$previousReceipt = Get-Content -LiteralPath $receiptPath -Raw
Remove-Item -LiteralPath $receiptPath -Force
Set-Content -LiteralPath $receiptPath -Value $previousReceipt
$result = & $initializer @parameters
Assert-Check ((Get-Acl -LiteralPath $receiptPath).AreAccessRulesProtected) 'Atomic replacement must not retain a permissive destination ACL.'

Reset-NativeFixture
$state.RedactDataSource = $true
$state.Resources[$paths[0]].'@odata.etag' = '"datasource-rebound"'
$null = New-Item -Path (Split-Path $receiptPath -Parent) -ItemType Directory -Force
Set-Content -LiteralPath $receiptPath -Value $receiptBaseline
$originalStorageId = $parameters.StorageResourceId
try {
    $parameters.StorageResourceId += 'other'
    Assert-NativeBlocked 'desired storage changed but receipt unchanged' -ExpectedPath 'ACTION:'
    $parameters.RebindDataSource = $true
    $state.ExpectRebind = $true
    $state.Calls.Clear()
    $result = & $initializer @parameters
    $newReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Assert-Check ($newReceipt.storage_resource_id -ceq $parameters.StorageResourceId -and $result.datasource_action -ceq 'rebound') 'Explicit rebind writes and receipts the newly intended storage ID.'
    Assert-Check ($newReceipt.desired_config_sha256 -cne ($receiptBaseline | ConvertFrom-Json).desired_config_sha256) 'Desired storage change must change the config hash.'
}
finally { $parameters.StorageResourceId = $originalStorageId }

foreach ($field in @('receipt_version', 'search_endpoint', 'datasource', 'storage_resource_id', 'staging_container', 'folder_path', 'ingestion_identity_resource_id', 'desired_config_sha256', 'server_etag')) {
    Reset-NativeFixture
    $state.RedactDataSource = $true
    $state.Resources[$paths[0]].'@odata.etag' = '"datasource-rebound"'
    $null = New-Item -Path (Split-Path $receiptPath -Parent) -ItemType Directory -Force
    $receipt = $receiptBaseline | ConvertFrom-Json
    $receipt.$field = 'wrong'
    $receipt | ConvertTo-Json -Compress | Set-Content -LiteralPath $receiptPath
    Assert-NativeBlocked "receipt mismatch $field" -ExpectedPath 'ACTION:'
}
foreach ($mode in @('malformed', 'etag-changed', 'missing-etag', 'wildcard-etag', 'empty-etag', 'array-etag')) {
    Reset-NativeFixture
    $state.RedactDataSource = $true
    $state.Resources[$paths[0]].'@odata.etag' = '"datasource-rebound"'
    $null = New-Item -Path (Split-Path $receiptPath -Parent) -ItemType Directory -Force
    Set-Content -LiteralPath $receiptPath -Value $receiptBaseline
    switch ($mode) {
        'malformed' { Set-Content -LiteralPath $receiptPath -Value '{DO-NOT-LEAK' }
        'etag-changed' { $state.Resources[$paths[0]].'@odata.etag' = '"new-version"' }
        'missing-etag' { $state.Resources[$paths[0]].PSObject.Properties.Remove('@odata.etag') }
        'wildcard-etag' { $state.Resources[$paths[0]].'@odata.etag' = '*' }
        'empty-etag' { $state.Resources[$paths[0]].'@odata.etag' = '' }
        'array-etag' { $state.Resources[$paths[0]].'@odata.etag' = @('"datasource-rebound"') }
    }
    Assert-NativeBlocked $mode -ExpectedPath $(if ($mode -in @('malformed', 'etag-changed')) { 'ACTION:' } else { 'etag' })
}
foreach ($mode in @('redacted', 'noetag', 'empty')) {
    Reset-NativeFixture
    $state.Resources.Clear()
    $state.RedactDataSource = $true
    $state.PutResponseMode = $mode
    $parameters.RebindDataSource = $true
    $result = & $initializer @parameters
    Assert-Check ($result.datasource_action -ceq 'created' -and $result.datasource_receipt_status -ceq 'saved') "Fresh create accepts $mode PUT representation with verified GET."
}
foreach ($mode in @('412', '404-readback', 'etag-race', 'storage-readback', 'identity-readback', 'wrong-response', 'write-failure')) {
    Reset-NativeFixture
    $state.RedactDataSource = $true
    $parameters.RebindDataSource = $true
    $state.ExpectRebind = $true
    switch ($mode) {
        '412' { $state.FailPath = $paths[0]; $state.FailMethod = 'PUT'; $state.FailureStatus = 412 }
        '404-readback' { $state.AfterCreate = { param($path) $state.Resources.Remove($path) } }
        'etag-race' { $state.AfterCreate = { param($path) $state.Resources[$path].'@odata.etag' = '"raced"' } }
        'storage-readback' { $state.AfterCreate = { param($path) $state.RedactDataSource = $false; $state.Resources[$path].credentials.connectionString = 'ResourceId=/wrong' } }
        'identity-readback' { $state.AfterCreate = { param($path) $state.Resources[$path].identity.userAssignedIdentity = '/wrong' } }
        'wrong-response' { $state.PutResponseMode = 'wrong' }
        'write-failure' { $state.ReceiptWriteFailure = $true }
    }
    Assert-NativeBlocked "failed rebind $mode" -ExpectedWrites 1
    Assert-Check (-not (Test-Path -LiteralPath $receiptPath)) "Failed rebind $mode must not issue a receipt."
}
Reset-NativeFixture
$state.RedactDataSource = $true
$parameters.RebindDataSource = $true
$null = & $initializer @parameters -WhatIf
Assert-Check ($state.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $receiptDirectory)) 'Declined rebind creates neither requests nor local state.'
Reset-NativeFixture
$targetDirectory = Join-Path $receiptDirectory 'target'
$linkDirectory = Join-Path $receiptDirectory 'link'
$null = New-Item -Path $targetDirectory -ItemType Directory -Force
$null = New-Item -Path $linkDirectory -ItemType Junction -Target $targetDirectory
$parameters.DataSourceReceiptPath = Join-Path $linkDirectory 'receipt.json'
$parameters.RebindDataSource = $true
Assert-NativeBlocked 'linked receipt parent' -ExpectedPath 'links or reparse points'
Assert-Check ($state.Calls.Count -eq 0) 'Linked receipt path blocked before HTTP.'
$parameters.Remove('RebindDataSource')
$parameters.RefreshDataSourceBinding = $true
Assert-NativeBlocked 'refresh linked receipt parent' -ExpectedPath 'links or reparse points'
Assert-Check ($state.Calls.Count -eq 0) 'Refresh rejects linked paths before HTTP.'
[IO.Directory]::Delete($linkDirectory)
$initializerAst = [Management.Automation.Language.Parser]::ParseFile($initializer, [ref]$null, [ref]$null)
$defaultPathExpression = @($initializerAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'DataSourceReceiptPath' })[0].DefaultValue.Extent.Text
$defaultReceiptPath = & ([scriptblock]::Create("param([string]`$PSScriptRoot) $defaultPathExpression")) (Split-Path $initializer -Parent)
Assert-Check ([IO.Path]::GetFullPath($defaultReceiptPath) -ieq (Join-Path $root '.azure\native-datasource-receipt.json')) 'Initializer receipt default stays under source .azure.'
'PASS: {0} assertions; six-resource create/reuse/partial-resume/WhatIf/JSON; {1} contract mutations; {2} invalid inputs.' -f $state.Checks, $mutations.Count, $invalidInputs.Count
'PASS: all six pre-read/mismatch gates, per-resource read failures and create conflicts, strict readbacks, missing tokens; cloud-free.'
}
finally {
    if (Test-Path -LiteralPath $receiptDirectory) { Remove-Item -LiteralPath $receiptDirectory -Recurse -Force }
}