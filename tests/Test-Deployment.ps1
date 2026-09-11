[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("fwf-deployment-test-$([guid]::NewGuid().ToString('N'))")
$null = New-Item -ItemType Directory -Path $temporary -Force
$originalProgramData = $env:ProgramData
$originalPath = $env:PATH
$originalSubscription = $env:AZURE_SUBSCRIPTION_ID
$originalTenant = $env:AZURE_TENANT_ID
$global:DeploymentTest = @{ checks = 0; sync = 0; publish = 0; build = 'success'; envelope = 'succeeded'; nativeCalls = 0; calls = [Collections.Generic.List[object]]::new() }

function Assert-Deployment {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $global:DeploymentTest.checks++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $failed = $false
    try { $null = & $Action } catch { $failed = $true }
    Assert-Deployment $failed $Message
}

function Start-Sleep { throw 'Real waits are forbidden in the cloud-free suite.' }

function terraform {
    $global:LASTEXITCODE = 0
    $global:DeploymentTest.calls.Add(@($args))
    $command = $args -join ' '
    if ($command -eq 'output -json ingest_function') { return '{"name":"mock-function"}' }
    if ($command -like '* plan *') {
        $planArgument = @($args | Where-Object { $_ -like '-out=*' })[0]
        [IO.File]::WriteAllText($planArgument.Substring(5), 'reviewable-mock-plan')
        return
    }
    if ($command -like '* show -json *') { return '{"variables":{"subscription_id":{"value":"11111111-1111-4111-8111-111111111111"}}}' }
    if ($command -like '* show -no-color *' -or $command -like '* apply *') { return }
    if ($global:DeploymentTest.outputs) { return ($global:DeploymentTest.outputs | ConvertTo-Json -Depth 20) }
    @{ subscription_id = @{ value = '11111111-1111-4111-8111-111111111111' }
        foundry_primary_account_id = @{ value = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/mock-primary/providers/Microsoft.CognitiveServices/accounts/mock-foundry' }
        resource_groups = @{ value = @{ primary = 'mock-primary'; secondary = 'mock-secondary' } }
        foundry_primary = @{ value = @{} }; foundry_secondary = @{ value = @{} }
        jumpbox = @{ value = @{ name = 'mock-jump' } }; sharepoint = @{ value = @{} }
        ingest_function = @{ value = @{ name = 'mock-function' } }
    } | ConvertTo-Json -Depth 10
}

function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -like 'account show *') { return '11111111-1111-4111-8111-111111111111' }
    if ($command -like 'functionapp config *' -or $command -like 'functionapp restart *') { $global:DeploymentTest.functionChanges++; return }
    if ($command -like '*syncfunctiontriggers*') { $global:DeploymentTest.sync++; return }
    if ($command -like '*functions?api-version*') {
        if ($global:DeploymentTest.triggerMissing) { return '{"value":[]}' }
        return '{"value":[{"name":"mock-function/ingest","properties":{"config":{"bindings":[{"type":"httpTrigger","route":"ingest","methods":["POST"]}]}}}]}'
    }
    if ($command -like 'vm run-command invoke *') {
        $path = $args[[array]::IndexOf($args, '--scripts') + 1].Substring(1)
        $source = Get-Content -LiteralPath $path -Raw
        if ($source -match 'FWF_FUNCTION_') {
            $message = (& ([scriptblock]::Create($source))) -join "`n"
        }
        else {
            $marker = [regex]::Match($source, 'FWF_ACCELERATOR_[0-9a-f]+=').Value
            $message = $marker + (@{ status = $global:DeploymentTest.envelope; output = 'verified' } | ConvertTo-Json -Compress)
        }
        if ($global:DeploymentTest.envelope -eq 'missing') { $message = 'incomplete output' }
        $entries = @(@{ code = 'ComponentStatus/StdOut/succeeded'; level = 'Info'; message = $message })
        if ($global:DeploymentTest.envelope -eq 'stderr') { $entries += @{ code = 'ComponentStatus/StdErr/succeeded'; message = 'remote failure' } }
        return (@{ value = $entries } | ConvertTo-Json -Depth 8)
    }
    throw "Unexpected Azure command in mock: $command"
}

function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $InFile, $TimeoutSec, $MaximumRedirection, $Body, [switch]$UseBasicParsing)
    if ($Uri -like '*scm.azurewebsites.net/api/publish*') {
        $global:DeploymentTest.publish++
        $global:DeploymentTest.publishUri = [string]$Uri
        $archive = [IO.Compression.ZipFile]::OpenRead($InFile)
        try {
            $global:DeploymentTest.packageEntries = @($archive.Entries.FullName)
            $reader = [IO.StreamReader]::new($archive.GetEntry('requirements.txt').Open())
            try { $global:DeploymentTest.packagedRequirements = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
            $lockStream = $archive.GetEntry('requirements.lock').Open()
            try { $global:DeploymentTest.packagedLockHash = (Get-FileHash -InputStream $lockStream -Algorithm SHA256).Hash }
            finally { $lockStream.Dispose() }
        }
        finally { $archive.Dispose() }
        if ($global:DeploymentTest.build -eq 'publish-error') { throw 'Mock upload failure' }
        return [pscustomobject]@{ StatusCode = 202; Content = ''; Headers = @{ Location = '/api/deployments/mock-build' } }
    }
    throw "Unexpected HTTP request: $Uri"
}

function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $ContentType, $TimeoutSec, $MaximumRedirection, $Body)
    if ($Uri -like 'http://169.254.*') { return [pscustomobject]@{ access_token = 'mock-token' } }
    if ($Uri -like '*scm.azurewebsites.net/api/deployments/*') {
        $global:DeploymentTest.buildReads++
        return [pscustomobject]@{
            id = $(if ($global:DeploymentTest.build -eq 'wrong-id') { 'another-build' } else { 'mock-build' })
            status = $(if ($global:DeploymentTest.build -eq 'failed') { 3 } elseif ($global:DeploymentTest.build -eq 'running') { 1 } else { 4 })
            complete = ($global:DeploymentTest.build -ne 'incomplete')
        }
    }
    throw "Unexpected HTTP request: $Uri"
}

function uv {
    $global:DeploymentTest.uvArguments = @($args)
    throw 'Mock stops before installing verification dependencies.'
}

function azd {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -like 'auth login *' -or $command -like 'env set *' -or $command -like 'env select *') { return }
    if ($command -like 'env new *') { $null = New-Item -ItemType Directory -Path (Join-Path $PWD ".azure\$($args[2])") -Force; return }
    throw "Unexpected azd command: $command"
}

try {
    $env:ProgramData = $temporary
    foreach ($relative in @('scripts\Invoke-Accelerator.ps1', 'scripts\Deploy-IngestFunction.ps1', 'scripts\Initialize-KnowledgeBase.ps1',
        'scripts\jumpbox\Invoke-EndToEnd.ps1', 'scripts\jumpbox\Invoke-IngestFunction.ps1')) {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative), [ref]$tokens, [ref]$parseErrors)
        Assert-Deployment ($parseErrors.Count -eq 0) "$relative parses"
    }
    $stages = & (Join-Path $root 'scripts\Invoke-Accelerator.ps1') -ListStages
    Assert-Deployment (($stages -join ',') -eq 'Preflight,Infrastructure,Workload,Verify') 'Supported stage contract'
    & (Join-Path $root 'scripts\Invoke-Accelerator.ps1') -Stage $stages -WhatIf
    . (Join-Path $root 'scripts\Invoke-Accelerator.ps1') -ListStages | Out-Null
    $root = Split-Path $PSScriptRoot -Parent
    $SubscriptionId = [guid]'11111111-1111-4111-8111-111111111111'
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/mock-primary/providers"
    $nativeIngestion = @{
        storage_resource_id = "$scope/Microsoft.Storage/storageAccounts/mockstorage"
        storage_endpoint = 'https://mockstorage.blob.core.windows.net'
        container_name = 'spo-staging'; folder_path = 'native/'
        identity_resource_id = "$scope/Microsoft.ManagedIdentity/userAssignedIdentities/mock-ingestion"
        ai_services_endpoint = 'https://mock-ingestion.services.ai.azure.com'
        openai_endpoint = 'https://mock-ingestion.openai.azure.com'
        chat_deployment = 'ingestion-chat'; chat_model = 'gpt-5.2'
        embedding_deployment = 'embedding'; embedding_model = 'text-embedding-3-large'
        shared_private_links = @{}
    }
    foreach ($link in @(@('spl-native-staging-blob', 'blob', $nativeIngestion.storage_resource_id),
        @('spl-native-foundry', 'foundry_account', "$scope/Microsoft.CognitiveServices/accounts/mock-ingestion"),
        @('spl-native-openai', 'openai_account', "$scope/Microsoft.CognitiveServices/accounts/mock-ingestion"))) {
        $nativeIngestion.shared_private_links[$link[0]] = @{
            id = "$scope/Microsoft.Search/searchServices/mock-search/sharedPrivateLinkResources/$($link[0])"
            target_resource_id = $link[2]; group_id = $link[1]
        }
    }
    $global:DeploymentTest.outputs = @{
        subscription_id = @{ value = [string]$SubscriptionId }; tenant_id = @{ value = 'mock-tenant' }
        resource_groups = @{ value = @{ primary = 'mock-primary' } }; jumpbox = @{ value = @{ name = 'mock-jump' } }
        foundry_primary_account_id = @{ value = "$scope/Microsoft.CognitiveServices/accounts/mock-foundry" }
        foundry_primary_project_id = @{ value = "$scope/Microsoft.CognitiveServices/accounts/mock-foundry/projects/mock-project" }
        foundry_primary = @{ value = @{
            project_endpoint = 'https://mock.services.ai.azure.com/api/projects/mock'; location = 'centralus'
            agent_tool_model = 'gpt-test'; search_endpoint = 'https://mock.search.windows.net'; search = 'mock-search'
            account = 'mock'; planner_deployment = 'planner'; planner_model = 'gpt-test'
        } }
        ingest_function = @{ value = @{ hostname = 'mock.azurewebsites.net'; api_client_id = [string]$SubscriptionId } }
        native_ingestion = @{ value = $nativeIngestion }
    }
    $deploymentManifest = Get-DeploymentManifest
    Assert-Deployment ($null -ne $deploymentManifest.native_ingestion) 'Deployment manifest carries native ingestion bindings'
    foreach ($field in @('storage_resource_id', 'storage_endpoint', 'container_name', 'folder_path', 'identity_resource_id',
        'ai_services_endpoint', 'openai_endpoint', 'chat_deployment', 'chat_model', 'embedding_deployment', 'embedding_model')) {
        Assert-Deployment ($deploymentManifest.native_ingestion.$field -ceq $nativeIngestion[$field]) "Native manifest preserves $field"
        $original = $nativeIngestion[$field]
        foreach ($invalid in @($null, '', '   ')) {
            $nativeIngestion[$field] = $invalid
            Assert-Throws { Get-DeploymentManifest } "Reject missing or blank native binding $field"
        }
        $nativeIngestion[$field] = $original
    }
    foreach ($field in @('storage_resource_id', 'identity_resource_id')) {
        $original = $nativeIngestion[$field]
        $nativeIngestion[$field] = $original.Replace([string]$SubscriptionId, '22222222-2222-4222-8222-222222222222')
        Assert-Throws { Get-DeploymentManifest } "Reject foreign subscription in $field"
        $nativeIngestion[$field] = $original
    }
    foreach ($case in @(@('storage_endpoint', 'https://other.blob.core.windows.net'), @('openai_endpoint', 'https://mock.cognitiveservices.azure.com'),
        @('ai_services_endpoint', 'https://mock.openai.azure.com'), @('folder_path', '../native/'), @('container_name', 'bad--container'), @('chat_deployment', 'bad deployment'))) {
        $original = $nativeIngestion[$case[0]]
        $nativeIngestion[$case[0]] = $case[1]
        Assert-Throws { Get-DeploymentManifest } "Reject invalid $($case[0])"
        $nativeIngestion[$case[0]] = $original
    }
    $links = $nativeIngestion.shared_private_links
    $nativeIngestion.shared_private_links = @{}
    Assert-Throws { Get-DeploymentManifest } 'Reject missing native link bindings'
    $nativeIngestion.shared_private_links = $links
    $originalLinkId = $links.'spl-native-openai'.id
    $links.'spl-native-openai'.id = $originalLinkId.Replace([string]$SubscriptionId, '22222222-2222-4222-8222-222222222222')
    Assert-Throws { Get-DeploymentManifest } 'Reject foreign subscription in native link bindings'
    $links.'spl-native-openai'.id = $originalLinkId
    $global:DeploymentTest.outputs = $null
    $manifest = @{ primary_resource_group = 'mock-rg'; jumpbox_name = 'mock-vm' }
    $SubscriptionId = [guid]'11111111-1111-4111-8111-111111111111'
    foreach ($case in @('succeeded', 'failed', 'missing', 'stderr')) {
        $global:DeploymentTest.envelope = $case
        if ($case -eq 'succeeded') {
            Assert-Deployment ((Invoke-PrivateCommand { throw 'Must not execute unmocked payload' } @{}) -eq 'verified') 'Valid remote completion marker'
        }
        else { Assert-Throws { Invoke-PrivateCommand { throw 'Must not execute payload' } @{} } "Reject $case Run Command envelope" }
    }
    $global:DeploymentTest.envelope = 'succeeded'
    $Resume = $true
    $state = @{ steps = @{ 'Workload.Tools' = @{ status = 'succeeded'; output = 'cached' } } }
    Assert-Deployment ((Invoke-StageStep 'Workload.Tools' { throw 'Completed step reran' }) -eq 'cached') 'Resume returns prior completed output'
    $Resume = $false
    $statePath = Join-Path $temporary 'state.json'
    $stateDirectory = $temporary
    $nativeVariablesPath = Join-Path $temporary 'native-agent.auto.tfvars.json'
    Assert-Throws { Invoke-StageStep 'Workload.Bad' { throw 'simulated failure' } } 'Stage failure propagates'
    Assert-Deployment ((Get-Content $statePath -Raw | ConvertFrom-Json).steps.'Workload.Bad'.status -eq 'failed') 'Failure is durably recorded'
    $Resume = $true
    $state.steps['Infrastructure.NativePrivateLinks'] = @{ status = 'succeeded'; output = 'stale approval' }
    Assert-Throws { Invoke-StageStep 'Infrastructure.NativePrivateLinks' { throw 'Approval revoked' } -Always } 'Native link gate revalidates even on resume'
    Assert-Deployment ((Get-Content $statePath -Raw | ConvertFrom-Json).steps.'Infrastructure.NativePrivateLinks'.status -eq 'failed') 'Revoked native approval replaces cached success with failure'
    $Resume = $false
    $TerraformDir = Join-Path $root 'terraform'
    Assert-Throws { Invoke-ReviewedApply 'mock-plan' -WhatIf } 'Declined Terraform apply fails the step'
    Assert-Deployment (@($global:DeploymentTest.calls | Where-Object { $_ -contains 'apply' }).Count -eq 0) 'Terraform never applies a declined plan'
    $result = Invoke-ReviewedApply 'mock-plan' -Confirm:$false
    $apply = @($global:DeploymentTest.calls | Where-Object { $_ -contains 'apply' })
    Assert-Deployment ($result.status -eq 'applied' -and $apply.Count -eq 1) 'Reviewed saved plan is applied once'
    Assert-Deployment ($apply[0] -notcontains '-auto-approve') 'No automatic Terraform approval flag'
    Assert-Deployment ($apply[0] -contains '-parallelism=1') 'Reviewed Terraform apply serializes Search control-plane writes'

    $functionSource = Join-Path $root 'src\ingest_func'
    foreach ($component in @('ingest_func', 'foundry_native_agent', 'hello_world')) {
        $lockedRequirements = Get-Content -LiteralPath (Join-Path $root "src\$component\requirements.lock") -Raw
        Assert-Deployment ($lockedRequirements -match '(?im)^pyjwt\[crypto\]==[0-9.]+\s+\\$') "$component preserves the crypto extra for pip 23 hash enforcement"
    }
    $sourceRequirementsHash = (Get-FileHash -LiteralPath (Join-Path $functionSource 'requirements.txt') -Algorithm SHA256).Hash
    $sourceLockHash = (Get-FileHash -LiteralPath (Join-Path $functionSource 'requirements.lock') -Algorithm SHA256).Hash
    $withoutLock = Join-Path $temporary 'without-lock'
    $null = New-Item -ItemType Directory -Path $withoutLock -Force
    Get-ChildItem -LiteralPath $functionSource -File | Where-Object { $_.Extension -eq '.py' -or $_.Name -in @('host.json', 'requirements.txt') } | Copy-Item -Destination $withoutLock
    $global:DeploymentTest.functionChanges = 0
    $missingLockMessage = ''
    try { & (Join-Path $root 'scripts\Deploy-IngestFunction.ps1') -SourceDir $withoutLock -Confirm:$false }
    catch { $missingLockMessage = $_.Exception.Message }
    Assert-Deployment ($missingLockMessage -eq 'Function package is missing requirements.lock.') 'Function packaging fails closed when the resolved lock is missing'
    Assert-Deployment ($global:DeploymentTest.functionChanges -eq 0 -and $global:DeploymentTest.publish -eq 0) 'Missing lock cannot modify Function settings, restart or publish'
    $global:DeploymentTest.build = 'failed'
    Assert-Throws { & (Join-Path $root 'scripts\Deploy-IngestFunction.ps1') -Confirm:$false } 'Real generated remote build wrapper rejects status 3'
    Assert-Deployment ($global:DeploymentTest.sync -eq 0) 'Failed remote build never syncs triggers'
    $expectedEntries = @(Get-ChildItem -LiteralPath $functionSource -File | Where-Object { $_.Extension -eq '.py' }).Name + @('host.json', 'requirements.txt', 'requirements.lock')
    Assert-Deployment (@(Compare-Object $expectedEntries $global:DeploymentTest.packageEntries).Count -eq 0) 'Function ZIP includes Python modules, host configuration, requirements wrapper and lock at its root'
    Assert-Deployment ($global:DeploymentTest.packagedRequirements -ceq (Get-Content -LiteralPath (Join-Path $functionSource 'requirements.lock') -Raw)) 'Packaged requirements expose every pin and hash directly to the remote builder'
    Assert-Deployment ($global:DeploymentTest.packagedLockHash -eq $sourceLockHash) 'Packaged lock is byte-for-byte identical to the resolved source lock'
    Assert-Deployment ($global:DeploymentTest.publishUri -like '*?RemoteBuild=true') 'Function publish requests a remote Oryx build'
    foreach ($buildState in @('running', 'incomplete', 'wrong-id')) {
        $global:DeploymentTest.build = $buildState
        $buildReads = $global:DeploymentTest.buildReads
        Assert-Throws { & (Join-Path $root 'scripts\Deploy-IngestFunction.ps1') -Confirm:$false } "Build state $buildState cannot report readiness"
        Assert-Deployment ($global:DeploymentTest.buildReads -gt $buildReads -and $global:DeploymentTest.sync -eq 0) "Build state $buildState is polled without synchronizing triggers"
    }
    $global:DeploymentTest.build = 'success'
    $deployment = & (Join-Path $root 'scripts\Deploy-IngestFunction.ps1') -Confirm:$false
    Assert-Deployment ($deployment.build -eq 'completed' -and $deployment.trigger -eq 'ingest') 'Completed build requires an actual HTTP trigger manifest'
    Assert-Deployment ($global:DeploymentTest.publish -eq 1) 'Function resume reads original deployment rather than republishing'
    Assert-Deployment ($global:DeploymentTest.sync -eq 1) 'Only completed deployment syncs triggers'
    Assert-Deployment ((Get-FileHash -LiteralPath (Join-Path $functionSource 'requirements.txt') -Algorithm SHA256).Hash -eq $sourceRequirementsHash) 'Packaging preserves the source dependency inputs'
    Assert-Deployment ((Get-FileHash -LiteralPath (Join-Path $functionSource 'requirements.lock') -Algorithm SHA256).Hash -eq $sourceLockHash) 'Packaging preserves the finalized source lock'
    $global:DeploymentTest.triggerMissing = $true
    Assert-Throws { & (Join-Path $root 'scripts\Deploy-IngestFunction.ps1') -Confirm:$false } 'Completed build without the ingest HTTP trigger cannot report readiness'
    Assert-Deployment ($global:DeploymentTest.sync -eq 2) 'Missing trigger is checked after synchronizing the completed build'
    $global:DeploymentTest.triggerMissing = $false

    $runner = @{ root = $temporary; source = (Join-Path $temporary 'source') }
    $null = New-Item -ItemType Directory -Path (Join-Path $runner.source 'scripts') -Force
    @{ environment = 'mock-env'; subscription_id = [string]$SubscriptionId; tenant_id = 'mock-tenant'; project_id = 'mock-project'
        project_endpoint = 'https://mock.services.ai.azure.com/api/projects/mock'; location = 'centralus'; agent_model = 'gpt-test'
        search_endpoint = 'https://mock.search.windows.net'; search_connection = 'mock-search'
        openai_endpoint = $deploymentManifest.openai_endpoint; planner_deployment = $deploymentManifest.planner_deployment; planner_model = $deploymentManifest.planner_model
        function_hostname = $deploymentManifest.function_hostname; function_api_client_id = $deploymentManifest.function_api_client_id
        native_ingestion = $deploymentManifest.native_ingestion
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runner.source 'deployment-manifest.json') -Encoding UTF8
    @{ azd = @{ version = '1.2.3' }; uv = @{ version = '1.2.3' }; python = @{ version = '3.13.7' } } | ConvertTo-Json | Set-Content (Join-Path $runner.source 'tool-manifest.json') -Encoding UTF8
    @'
param($EnvironmentName, $ProjectId, $Location, $ProjectEndpoint, $ModelDeployment, $SearchEndpoint, $SearchConnectionName, [switch]$ReadOnly, [switch]$AzdDebug)
Assert-Deployment $AzdDebug.IsPresent 'Native helper calls enable debug diagnostics'
$global:LASTEXITCODE = 0
if ($ReadOnly) {
    Assert-Deployment ($EnvironmentName -eq 'mock-env' -and $ProjectEndpoint -eq 'https://mock.services.ai.azure.com/api/projects/mock') 'Native read-only helper receives endpoint and environment'
    $global:DeploymentTest.nativeReads++
    if ($global:DeploymentTest.nativeCalls -eq 0) { throw 'Fresh azd environment has no deployed version to show.' }
    if ($global:DeploymentTest.nativeReadError) { throw $global:DeploymentTest.nativeReadError }
    if ($global:DeploymentTest.nativeMetadata) { return $global:DeploymentTest.nativeMetadata }
    return [pscustomobject]@{
        agent = @{ name = 'funwithfoundry-rag-agent'; status = 'active'; version = $global:DeploymentTest.nativeVersion; instance_identity = @{ principal_id = '22222222-2222-4222-8222-222222222222' } }
        toolbox = @{ version = @{ version = '7' } }
    }
}
$global:DeploymentTest.nativeCalls++
$global:DeploymentTest.nativePreviousVersion = (Get-Content .azure\native-attempt.json -Raw | ConvertFrom-Json).previous_version
$global:DeploymentTest.nativeVersion = [string]([int]$global:DeploymentTest.nativeVersion + 1)
'mock native deployment output'
if ($global:DeploymentTest.nativeCreateError) { throw $global:DeploymentTest.nativeCreateError }
if ($global:DeploymentTest.nativeCreateExit) { $global:LASTEXITCODE = 1 }
'@ | Set-Content (Join-Path $runner.source 'scripts\Deploy-NativeFoundryAgent.ps1') -Encoding UTF8
    function Invoke-PrivateCommand { param([scriptblock]$Script, $Payload); & $Script ($Payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }
    @'
[CmdletBinding(SupportsShouldProcess = $true)]
param($SearchEndpoint, $FoundryOpenAIEndpoint, $PlannerDeployment, $PlannerModel, $StorageResourceId,
    $IngestionIdentityResourceId, $IngestionFoundryEndpoint, $IngestionOpenAIEndpoint, $IngestionChatDeployment,
    $IngestionChatModel, $EmbeddingDeployment, $EmbeddingModel, $StagingContainer, $FolderPath, [switch]$RefreshDataSourceBinding)
$global:DeploymentTest.knowledgeParameters = @{} + $PSBoundParameters
if ($null -ne $global:DeploymentTest.workflow) { $global:DeploymentTest.workflow.Add('Knowledge') }
$global:LASTEXITCODE = 0
if ($global:DeploymentTest.knowledgeFailure) { throw 'Explicit native pipeline configuration mismatch' }
if ($global:DeploymentTest.knowledgeExit) { $global:LASTEXITCODE = 1 }
$global:DeploymentTest.knowledgeResult
'@ | Set-Content (Join-Path $runner.source 'scripts\Initialize-KnowledgeBase.ps1') -Encoding UTF8
    $null = New-Item -ItemType Directory -Path (Join-Path $runner.source 'scripts\jumpbox') -Force
    @'
[CmdletBinding(SupportsShouldProcess = $true)]
param($FunctionHostname, $ApiClientId, $Mode)
$global:DeploymentTest.fixtureParameters = @{} + $PSBoundParameters
$global:LASTEXITCODE = 0
if ($global:DeploymentTest.fixtureFailure) { throw 'Authorized staging failed' }
if ($global:DeploymentTest.fixtureExit) { $global:LASTEXITCODE = 1 }
$global:DeploymentTest.fixtureResult
'@ | Set-Content (Join-Path $runner.source 'scripts\jumpbox\Invoke-IngestFunction.ps1') -Encoding UTF8
    $blobName = 'native/' + ('a' * 64) + '/source.txt'
    $global:DeploymentTest.fixtureResult = @{ status = 'staged'; mode = 'fixture'; blob_name = $blobName; blob_url = "https://mockstorage.blob.core.windows.net/spo-staging/$blobName" }
    Assert-Deployment ((Invoke-RunnerWorkload 'StageFixture').status -eq 'staged') 'Fixture is staged through the private runner'
    Assert-Deployment ($global:DeploymentTest.fixtureParameters.Count -eq 4 -and
        $global:DeploymentTest.fixtureParameters.FunctionHostname -eq $deploymentManifest.function_hostname -and
        $global:DeploymentTest.fixtureParameters.ApiClientId -eq $deploymentManifest.function_api_client_id -and
        $global:DeploymentTest.fixtureParameters.Mode -eq 'fixture' -and -not $global:DeploymentTest.fixtureParameters.Confirm) 'Fixture uses only the assigned Function API and fixed fixture mode'
    foreach ($case in @(@('status', 'indexed'), @('mode', 'sharepoint'), @('blob_name', 'other/source.txt'), @('blob_url', 'https://other.blob.core.windows.net/spo-staging/source.txt'))) {
        $original = $global:DeploymentTest.fixtureResult[$case[0]]
        $global:DeploymentTest.fixtureResult[$case[0]] = $case[1]
        Assert-Throws { Invoke-RunnerWorkload 'StageFixture' } "Reject mismatched fixture $($case[0])"
        $global:DeploymentTest.fixtureResult[$case[0]] = $original
    }
    $global:DeploymentTest.fixtureFailure = $true
    Assert-Throws { Invoke-RunnerWorkload 'StageFixture' } 'Unauthorized or failed staging propagates'
    $global:DeploymentTest.fixtureFailure = $false
    $global:DeploymentTest.fixtureExit = $true
    Assert-Throws { Invoke-RunnerWorkload 'StageFixture' } 'Nonzero staging exit blocks Knowledge'
    $global:DeploymentTest.fixtureExit = $false
    $global:LASTEXITCODE = 0
    $global:DeploymentTest.knowledgeResult = @{ status = 'succeeded'; knowledge_source = 'spo-native'; index = 'spo-native-index'; knowledge_base = 'spo-native-knowledge-base'; datasource_action = 'refreshed'; datasource_receipt_status = 'saved' }
    $knowledge = Invoke-RunnerWorkload 'Knowledge'
    $expectedKnowledge = @{
        SearchEndpoint = $deploymentManifest.search_endpoint; FoundryOpenAIEndpoint = $deploymentManifest.openai_endpoint
        PlannerDeployment = $deploymentManifest.planner_deployment; PlannerModel = $deploymentManifest.planner_model
        StorageResourceId = $nativeIngestion.storage_resource_id; IngestionIdentityResourceId = $nativeIngestion.identity_resource_id
        IngestionFoundryEndpoint = $nativeIngestion.ai_services_endpoint; IngestionOpenAIEndpoint = $nativeIngestion.openai_endpoint
        IngestionChatDeployment = $nativeIngestion.chat_deployment; IngestionChatModel = $nativeIngestion.chat_model
        EmbeddingDeployment = $nativeIngestion.embedding_deployment; EmbeddingModel = $nativeIngestion.embedding_model
        StagingContainer = $nativeIngestion.container_name; FolderPath = $nativeIngestion.folder_path; RefreshDataSourceBinding = $true; Confirm = $false
    }
    Assert-Deployment ($global:DeploymentTest.knowledgeParameters.Count -eq $expectedKnowledge.Count) 'Knowledge receives exactly the new native parameter contract'
    foreach ($key in $expectedKnowledge.Keys) {
        Assert-Deployment ($global:DeploymentTest.knowledgeParameters[$key] -ceq $expectedKnowledge[$key]) "Knowledge payload propagates $key"
    }
    Assert-Deployment ($knowledge.knowledge_source -eq 'spo-native' -and $knowledge.index -eq 'spo-native-index' -and $knowledge.knowledge_base -eq 'spo-native-knowledge-base') 'Native knowledge names pass through unchanged'
    $global:DeploymentTest.knowledgeFailure = $true
    Assert-Throws { Invoke-RunnerWorkload 'Knowledge' } 'Native KS configuration failure cannot become success'
    Assert-Deployment ($global:DeploymentTest.nativeCalls -eq 0) 'Knowledge and fixture failures do not create a native deployment'
    $global:DeploymentTest.knowledgeFailure = $false
    foreach ($field in @('status', 'knowledge_source', 'index', 'knowledge_base')) {
        $original = $global:DeploymentTest.knowledgeResult[$field]
        foreach ($invalid in @($null, '', 'wrong')) {
            $global:DeploymentTest.knowledgeResult[$field] = $invalid
            Assert-Throws { Invoke-RunnerWorkload 'Knowledge' } "Reject incomplete or mismatched knowledge $field"
            Assert-Deployment ($global:DeploymentTest.nativeCalls -eq 0) "Invalid knowledge $field cannot deploy an agent"
        }
        $global:DeploymentTest.knowledgeResult[$field] = $original
    }
    $validKnowledge = $global:DeploymentTest.knowledgeResult
    foreach ($invalid in @($null, @{}, @($validKnowledge, $validKnowledge))) {
        $global:DeploymentTest.knowledgeResult = $invalid
        Assert-Throws { Invoke-RunnerWorkload 'Knowledge' } 'Missing or ambiguous knowledge output blocks native deployment'
    }
    $global:DeploymentTest.knowledgeResult = $validKnowledge
    $global:DeploymentTest.knowledgeExit = $true
    Assert-Throws { Invoke-RunnerWorkload 'Knowledge' } 'Nonzero knowledge exit cannot be masked by a success summary'
    $global:DeploymentTest.knowledgeExit = $false
    $global:LASTEXITCODE = 19
    Assert-Deployment ((Invoke-RunnerWorkload 'Knowledge').status -eq 'succeeded') 'Knowledge invocation clears stale native exit codes'
    $global:DeploymentTest.nativeVersion = '1'
    $native = Invoke-RunnerWorkload 'Native'
    Assert-Deployment ($native.principal_id -eq '22222222-2222-4222-8222-222222222222' -and $native.toolbox_version -eq '7') 'Native identity and immutable toolbox version are returned to root'
    $again = Invoke-RunnerWorkload 'Native'
    Assert-Deployment ($again.agent_version -eq $native.agent_version -and $global:DeploymentTest.nativeCalls -eq 1) 'Native rerun reconciles without another deployment'
    Assert-Deployment ($global:DeploymentTest.nativeReads -eq 2) 'Native creation and rerun use the helper for both metadata reads'
    Assert-Deployment ((Get-Content (Join-Path $runner.source '.azure\native-deploy.log') -Raw).Trim() -eq 'mock native deployment output') 'Native deployment stdout is retained on the runner'
    & {
        $fixtureSource = $runner.source
        $secretError = 'unexpected helper problem: Bearer fake-bearer; {"access_token":"fake-access","refresh_token":"fake-refresh"}; client_secret=fake-secret; https://example.invalid/?sig=fake-signature&other=ok; eyJfake.fake.fake'
        foreach ($scenario in @('existing', 'create-throw', 'create-exit')) {
            $runner = @{ root = $temporary; source = (Join-Path $temporary "native-$scenario") }
            $null = New-Item -ItemType Directory -Path (Join-Path $runner.source 'scripts') -Force
            foreach ($relative in @('deployment-manifest.json', 'tool-manifest.json', 'scripts\Deploy-NativeFoundryAgent.ps1')) {
                Copy-Item -LiteralPath (Join-Path $fixtureSource $relative) -Destination (Join-Path $runner.source $relative)
            }
            if ($scenario -eq 'existing') { $null = New-Item -ItemType Directory -Path (Join-Path $runner.source '.azure\mock-env') -Force }
            $attemptPath = Join-Path $runner.source '.azure\native-attempt.json'
            $callsBefore = $global:DeploymentTest.nativeCalls
            $readsBefore = $global:DeploymentTest.nativeReads
            $versionBefore = $global:DeploymentTest.nativeVersion
            $global:DeploymentTest.nativeCreateError = if ($scenario -eq 'create-throw') { $secretError } else { $null }
            $global:DeploymentTest.nativeCreateExit = $scenario -eq 'create-exit'
            $failure = $null
            try { $result = Invoke-RunnerWorkload 'Native' }
            catch { $failure = $_ }
            Assert-Deployment ($global:DeploymentTest.nativeCalls -eq $callsBefore + 1) "$scenario invokes native creation exactly once"
            if ($scenario -eq 'existing') {
                if ($failure) { throw $failure }
                Assert-Deployment ($global:DeploymentTest.nativePreviousVersion -eq $versionBefore -and $result.agent_version -ne $versionBefore) 'Existing environment captures the prior version through the helper before creation'
                Assert-Deployment ($global:DeploymentTest.nativeReads -eq $readsBefore + 2) 'Existing environment uses helper metadata before and after creation'
                $recorded = Get-Content $attemptPath -Raw
                foreach ($guard in @('missing-agent', 'wrong-name', 'missing-version', 'invalid-principal', 'version-drift', 'principal-drift', 'missing-toolbox', 'same-attempt-version')) {
                    $metadata = @{
                        agent = @{ name = 'funwithfoundry-rag-agent'; status = 'active'; version = $result.agent_version; instance_identity = @{ principal_id = $result.principal_id } }
                        toolbox = @{ version = @{ version = '7' } }
                    }
                    $expected = switch ($guard) {
                        'missing-agent' { $metadata.agent = $null; 'Native agent read-back failed' }
                        'wrong-name' { $metadata.agent.name = 'wrong-agent'; 'expected name, a new immutable version' }
                        'missing-version' { $metadata.agent.version = ''; 'expected name, a new immutable version' }
                        'invalid-principal' { $metadata.agent.instance_identity.principal_id = 'invalid'; 'instance_identity.principal_id' }
                        'version-drift' { $metadata.agent.version = '999'; 'identity/version drifted' }
                        'principal-drift' { $metadata.agent.instance_identity.principal_id = '33333333-3333-4333-8333-333333333333'; 'identity/version drifted' }
                        'missing-toolbox' { $metadata.toolbox = @{}; 'Toolbox immutable version read-back missing' }
                        'same-attempt-version' {
                            @{ status = 'attempting'; previous_version = $result.agent_version } | ConvertTo-Json | Set-Content $attemptPath -Encoding UTF8
                            'expected name, a new immutable version'
                        }
                    }
                    $global:DeploymentTest.nativeMetadata = $metadata
                    $attemptHash = (Get-FileHash -LiteralPath $attemptPath).Hash
                    $failure = $null
                    try { $null = Invoke-RunnerWorkload 'Native' }
                    catch { $failure = $_ }
                    Assert-Deployment ($null -ne $failure -and $failure.Exception.Message -like "ACTION:*$expected*") "$guard fails closed with a useful native summary"
                    Assert-Deployment ((Get-FileHash -LiteralPath $attemptPath).Hash -eq $attemptHash -and $global:DeploymentTest.nativeCalls -eq $callsBefore + 1) "$guard preserves the checkpoint and never redeploys"
                }
                $global:DeploymentTest.nativeMetadata = $null
                $global:DeploymentTest.nativeReadError = $secretError
                $failure = $null
                try { $null = Invoke-RunnerWorkload 'Native' }
                catch { $failure = $_ }
                Assert-Deployment ($null -ne $failure -and $failure.Exception.Message -like 'ACTION:*unexpected helper problem*' -and
                    $failure.Exception.Message -notmatch 'fake-bearer|fake-access|fake-refresh|fake-secret|fake-signature|eyJfake') 'Readback errors retain arbitrary messages but redact token material'
                $global:DeploymentTest.nativeReadError = $null
                Set-Content $attemptPath -Value $recorded -Encoding UTF8
            }
            else {
                Assert-Deployment ($null -ne $failure -and $failure.Exception.Message -like 'ACTION:*Resume reads the existing attempt*') "$scenario keeps native failure actionable"
                if ($scenario -eq 'create-throw') {
                    Assert-Deployment ($failure.Exception.Message -like '*unexpected helper problem*' -and $failure.Exception.Message -notmatch 'fake-bearer|fake-access|fake-refresh|fake-secret|fake-signature|eyJfake') 'Creation errors preserve arbitrary messages but redact token material'
                }
                Assert-Deployment ((Get-Content $attemptPath -Raw | ConvertFrom-Json).status -eq 'attempting') "$scenario retains the unknown-attempt marker"
                Assert-Deployment ((Get-Content (Join-Path $runner.source '.azure\native-deploy.log') -Raw) -like '*mock native deployment output*') "$scenario retains stdout before failure"
                $attemptHash = (Get-FileHash -LiteralPath $attemptPath).Hash
                $global:DeploymentTest.nativeReadError = 'Readback remains unavailable.'
                Assert-Throws { Invoke-RunnerWorkload 'Native' } "$scenario failed resume only reads the existing attempt"
                Assert-Deployment ((Get-FileHash -LiteralPath $attemptPath).Hash -eq $attemptHash -and $global:DeploymentTest.nativeCalls -eq $callsBefore + 1) "$scenario failed resume preserves the unknown attempt without redeploying"
                $global:DeploymentTest.nativeReadError = $null
                $resumed = Invoke-RunnerWorkload 'Native'
                Assert-Deployment ($resumed.status -eq 'succeeded' -and $global:DeploymentTest.nativeCalls -eq $callsBefore + 1) "$scenario successful resume reconciles without duplicate creation"
            }
            $global:DeploymentTest.nativeCreateError = $null
            $global:DeploymentTest.nativeCreateExit = $false
        }
    }
    $runtimePython = Join-Path $runner.root 'tools\python3.13.7\python.exe'
    $global:DeploymentTest.uvArguments = @()
    Assert-Throws { Invoke-RunnerWorkload 'Verify' } 'Missing runner Python cannot fall back to global or downloaded Python'
    Assert-Deployment ($global:DeploymentTest.uvArguments.Count -eq 0) 'Missing runner Python fails before uv can download anything'
    $null = New-Item -ItemType File -Path $runtimePython -Force
    Assert-Throws { Invoke-RunnerWorkload 'Verify' } 'Fresh Verify reaches the mocked venv builder without installing Python'
    Assert-Deployment (($global:DeploymentTest.uvArguments -join '|') -eq "venv|$(Join-Path $runner.root 'verification-venv')|--no-python-downloads|--python|$runtimePython") 'Fresh Verify explicitly selects pinned runner Python with downloads disabled'
    $verificationPython = Join-Path $runner.root 'verification-venv\Scripts\python.exe'
    $null = New-Item -ItemType File -Path $verificationPython -Force
    Assert-Throws { Invoke-RunnerWorkload 'Verify' } 'Verification reaches the mocked installer without installing packages'
    Assert-Deployment (($global:DeploymentTest.uvArguments -join '|') -eq "pip|install|--python|$verificationPython|--require-hashes|-r|.\src\hello_world\requirements.lock") 'Verification client installs the resolved lock with hash enforcement'
    & {
        function uv { $global:LASTEXITCODE = 0 }
        @'
[CmdletBinding(SupportsShouldProcess = $true)]
param($FunctionHostname, $ApiClientId)
$global:DeploymentTest.workflow.Add('Probes')
$global:LASTEXITCODE = 0
if ($global:DeploymentTest.probeFailure) { throw 'Mock ingestion probe failed' }
if ($global:DeploymentTest.probeExit) { $global:LASTEXITCODE = 1 }
$global:DeploymentTest.probeResult
'@ | Set-Content (Join-Path $runner.source 'scripts\jumpbox\Test-Ingestion.ps1') -Encoding UTF8
        @'
[CmdletBinding(SupportsShouldProcess = $true)]
param($FunctionHostname, $ApiClientId, $SearchEndpoint, $ProjectEndpoint, $SearchToolName, $ModelDeployment,
    $PythonExecutable, $StorageResourceId, $IngestionIdentityResourceId, $StagingContainer = 'spo-staging', $TimeoutSeconds = 1500,
    [ValidateSet('fixture', 'sharepoint')][string]$Mode = 'fixture')
$global:DeploymentTest.workflow.Add('E2E')
$global:DeploymentTest.e2eParameters = @{} + $PSBoundParameters
@{ status = 'passed' }
'@ | Set-Content (Join-Path $runner.source 'scripts\jumpbox\Invoke-EndToEnd.ps1') -Encoding UTF8
    $global:DeploymentTest.workflow = [Collections.Generic.List[string]]::new()
    $global:DeploymentTest.probeResult = '{"status":"passed"}'
    $verify = Invoke-RunnerWorkload 'Verify'
    Assert-Deployment ($verify.end_to_end.status -eq 'passed') 'Verify propagates the private native E2E result'
    Assert-Deployment (($global:DeploymentTest.workflow -join ',') -ceq 'Probes,Knowledge,E2E') 'Verify refreshes after successful ingestion probes and immediately before E2E'
    Assert-Deployment ($verify.knowledge.datasource_action -ceq 'refreshed' -and $verify.knowledge.datasource_receipt_status -ceq 'saved') 'Verify retains the current datasource refresh evidence'
    Assert-Deployment ($global:DeploymentTest.knowledgeParameters.Count -eq $expectedKnowledge.Count) 'Verify shares the full Knowledge manifest mapping without a receipt path override'
    foreach ($key in $expectedKnowledge.Keys) {
        Assert-Deployment ($global:DeploymentTest.knowledgeParameters[$key] -ceq $expectedKnowledge[$key]) "Verify initializer propagates $key"
    }
        $expectedE2e = @{
            FunctionHostname = $deploymentManifest.function_hostname; ApiClientId = $deploymentManifest.function_api_client_id
            SearchEndpoint = $deploymentManifest.search_endpoint; ProjectEndpoint = 'https://mock.services.ai.azure.com/api/projects/mock'
            SearchToolName = 'mock-search'; ModelDeployment = 'gpt-test'; PythonExecutable = $verificationPython
            StorageResourceId = $nativeIngestion.storage_resource_id; StagingContainer = $nativeIngestion.container_name; Confirm = $false
            IngestionIdentityResourceId = $nativeIngestion.identity_resource_id
        }
        Assert-Deployment ($global:DeploymentTest.e2eParameters.Count -eq $expectedE2e.Count) 'E2E uses native storage binding and retains the helper timeout default'
        foreach ($key in $expectedE2e.Keys) {
            Assert-Deployment ($global:DeploymentTest.e2eParameters[$key] -ceq $expectedE2e[$key]) "E2E payload propagates $key"
        }
        $callsBefore = $global:DeploymentTest.nativeCalls
        $Resume = $true
        $state = @{ steps = @{
            'Workload.Knowledge' = @{ status = 'succeeded'; output = $validKnowledge }
            'Verify.PrivateWorkflow' = @{ status = 'succeeded'; output = @{ status = 'cached' } }
        } }
        foreach ($attempt in @(1, 2)) {
            $global:DeploymentTest.workflow.Clear()
            $verify = Invoke-StageStep 'Verify.PrivateWorkflow' { Invoke-RunnerWorkload 'Verify' } -Always
            Assert-Deployment (($global:DeploymentTest.workflow -join ',') -ceq 'Probes,Knowledge,E2E') "Verify resume $attempt reruns initialization despite completed Knowledge and Verify checkpoints"
            Assert-Deployment ($verify.knowledge.datasource_action -ceq 'refreshed') 'Resume returns fresh binding evidence, not the cached proof'
        }
        foreach ($mode in @('throw', 'nonzero-exit', 'null', 'array', 'empty', 'status', 'knowledge_source', 'index', 'knowledge_base')) {
            $global:DeploymentTest.workflow.Clear()
            $global:DeploymentTest.knowledgeFailure = $mode -eq 'throw'
            $global:DeploymentTest.knowledgeExit = $mode -eq 'nonzero-exit'
            $global:DeploymentTest.knowledgeResult = $validKnowledge.Clone()
            switch ($mode) {
                'null' { $global:DeploymentTest.knowledgeResult = $null }
                'array' { $global:DeploymentTest.knowledgeResult = @($validKnowledge, $validKnowledge) }
                'empty' { $global:DeploymentTest.knowledgeResult = @{} }
                { $_ -in @('status', 'knowledge_source', 'index', 'knowledge_base') } { $global:DeploymentTest.knowledgeResult[$mode] = 'wrong' }
            }
            $state.steps['Verify.PrivateWorkflow'] = @{ status = 'succeeded'; output = 'old proof' }
            Assert-Throws { Invoke-StageStep 'Verify.PrivateWorkflow' { Invoke-RunnerWorkload 'Verify' } -Always } "Verify initializer $mode blocks E2E on resume"
            Assert-Deployment (($global:DeploymentTest.workflow -join ',') -ceq 'Probes,Knowledge') "Verify initializer $mode never reaches E2E"
            Assert-Deployment ($state.steps['Verify.PrivateWorkflow'].status -eq 'failed' -and
                (Get-Content $statePath -Raw | ConvertFrom-Json).steps.'Verify.PrivateWorkflow'.status -eq 'failed') "Verify initializer $mode durably replaces cached success"
        }
        $global:DeploymentTest.knowledgeFailure = $false
        $global:DeploymentTest.knowledgeExit = $false
        $global:DeploymentTest.knowledgeResult = $validKnowledge
        foreach ($mode in @('throw', 'nonzero-exit', 'failed', 'malformed', 'null', 'array', 'empty', 'case')) {
            $global:DeploymentTest.workflow.Clear()
            $global:DeploymentTest.probeFailure = $mode -eq 'throw'
            $global:DeploymentTest.probeExit = $mode -eq 'nonzero-exit'
            $global:DeploymentTest.probeResult = switch ($mode) {
                'failed' { '{"status":"failed"}' }
                'malformed' { '{invalid' }
                'null' { 'null' }
                'array' { '[{"status":"passed"},{"status":"passed"}]' }
                'empty' { '{}' }
                'case' { '{"status":"PASSED"}' }
                default { '{"status":"passed"}' }
            }
            Assert-Throws { Invoke-RunnerWorkload 'Verify' } "Verify probe $mode blocks initialization and E2E"
            Assert-Deployment (($global:DeploymentTest.workflow -join ',') -ceq 'Probes') "Verify probe $mode makes no binding or E2E calls"
        }
        Assert-Deployment ($global:DeploymentTest.nativeCalls -eq $callsBefore) 'Verify refresh successes and failures never redeploy the agent'
        $global:DeploymentTest.workflow = $null
        $global:DeploymentTest.probeFailure = $false
        $global:DeploymentTest.probeExit = $false
        $global:DeploymentTest.probeResult = '{"status":"passed"}'
        $global:LASTEXITCODE = 0
    }

    $acceleratorSyntax = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-Accelerator.ps1'), [ref]$tokens, [ref]$parseErrors)
    $stageStepImplementation = ${function:Invoke-StageStep}
    & {
        $gateCalls = @($acceleratorSyntax.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-StageStep' -and
            $node.CommandElements[1].Extent.Text -eq "'Infrastructure.NativePrivateLinks'"
        }, $true))
        Assert-Deployment ($gateCalls.Count -eq 2) 'Native gate runs after Infrastructure and at entry to Workload/Verify'
        foreach ($gate in $gateCalls) {
            Assert-Deployment (@($gate.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Always' }).Count -eq 1) 'Every native gate invocation uses Always'
            $helper = $gate.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.Extent.Text -like '*Test-NativePrivateLinks.ps1*' -and $node.GetCommandName() -ne 'Invoke-StageStep' }, $true)
            Assert-Deployment ($null -ne $helper -and $helper.Extent.Text -like '*-TerraformDir $TerraformDir -SubscriptionId $SubscriptionId*') 'Gate passes the explicit Terraform and subscription binding'
            Assert-Deployment ($gate.Extent.Text -notlike '*Approve-SharedPrivateLink*') 'Native gate never delegates broad approval'
        }
        $hashAssignment = @($acceleratorSyntax.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$hashInputs' -and
            $node.Right.Extent.Text -like '*Test-NativePrivateLinks.ps1*'
        }, $true))
        Assert-Deployment ($hashAssignment.Count -eq 1 -and $hashAssignment[0].Right.Extent.Text -like '*Get-FileHash*') 'Verifier implementation participates in source fingerprint hashing'
        $mainSwitch = $acceleratorSyntax.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$selected' }, $true)
        foreach ($selection in @('Infrastructure', 'Workload', 'Verify')) {
            $selected = $selection
            $clause = if ($selection -eq 'Infrastructure') { $mainSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -eq "'Infrastructure'" } }
                else { $mainSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -like '*Workload*Verify*' } }
            $body = [scriptblock]::Create(($clause.Item2.Statements.Extent.Text -join "`n"))
            $state = @{ steps = @{ 'Preflight.Checks' = @{ status = 'succeeded' } } }
            if ($selection -ne 'Infrastructure') { $state.steps['Infrastructure.SharedLink'] = @{ status = 'succeeded' } }
            $seen = [Collections.Generic.List[string]]::new()
            function Invoke-StageStep {
                param([string]$Name, [scriptblock]$Action, [switch]$Always)
                $seen.Add($Name)
                if ($Name -eq 'Infrastructure.NativePrivateLinks') {
                    Assert-Deployment $Always.IsPresent 'Readiness cannot be skipped by the stage dispatcher'
                    throw 'Mock native private link pending'
                }
                if ($Name -like 'Workload.*' -or $Name -like 'Verify.*') { throw 'Work ran before the readiness gate' }
            }
            $failure = $null
            try { & $body } catch { $failure = $_ }
            Assert-Deployment ($null -ne $failure -and $failure.Exception.Message -eq 'Mock native private link pending') "$selection stops at a blocked native gate"
            $expected = if ($selection -eq 'Infrastructure') { 'Infrastructure.Init,Infrastructure.Account,Infrastructure.AccountHost,Infrastructure.FullGraph,Infrastructure.SharedLink,Infrastructure.NativePrivateLinks' }
                else { 'Infrastructure.NativePrivateLinks' }
            Assert-Deployment (($seen -join ',') -eq $expected) "$selection gates before workload side effects, after the existing planner stage"
        }
        $workloadBranch = $acceleratorSyntax.Find({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$selected -eq ''Workload'''
        }, $true)
        $verifyGate = $workloadBranch.ElseClause.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-StageStep' -and
            $node.CommandElements[1].Extent.Text -eq "'Verify.PrivateWorkflow'"
        }, $true)
        Assert-Deployment ($null -ne $verifyGate -and @($verifyGate.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Always'
        }).Count -eq 1) 'Verify dispatcher always runs the private workflow even with completed checkpoints'
        $body = [scriptblock]::Create(($workloadBranch.Clauses[0].Item2.Statements.Extent.Text -join "`n"))
        $order = @('Workload.Function', 'Workload.StageFixture', 'Workload.Knowledge', 'Workload.Native', 'Workload.RuntimeRbac')
        foreach ($failedStep in @('none') + $order) {
            $seen = [Collections.Generic.List[string]]::new()
            function Invoke-StageStep {
                param([string]$Name, [scriptblock]$Action, [switch]$Always)
                $seen.Add($Name)
                if ($Name -eq 'Workload.Knowledge') { Assert-Deployment $Always.IsPresent 'Knowledge configuration is revalidated before native deployment even on resume' }
                if ($Name -eq $failedStep) { throw "Mock $Name failed" }
                if ($Name -eq 'Workload.Native') { return @{ principal_id = '22222222-2222-4222-8222-222222222222' } }
            }
            $failure = $null
            try { & $body } catch { $failure = $_ }
            $expected = if ($failedStep -eq 'none') { $order } else { $order[0..([array]::IndexOf($order, $failedStep))] }
            Assert-Deployment (($seen -join ',') -eq ($expected -join ',')) "Workload order and stop boundary for $failedStep"
            Assert-Deployment (($null -ne $failure) -eq ($failedStep -ne 'none')) "Workload failure propagates for $failedStep"
        }
        foreach ($mode in @('throw', 'nonzero-exit', 'failed-result', 'missing-result')) {
            $Resume = $true
            $state = @{ steps = @{ 'Workload.Knowledge' = @{ status = 'succeeded'; output = $validKnowledge } } }
            $seen = [Collections.Generic.List[string]]::new()
            $callsBefore = $global:DeploymentTest.nativeCalls
            $global:DeploymentTest.knowledgeFailure = $mode -eq 'throw'
            $global:DeploymentTest.knowledgeExit = $mode -eq 'nonzero-exit'
            $global:DeploymentTest.knowledgeResult = if ($mode -eq 'failed-result') { @{ status = 'failed' } }
                elseif ($mode -eq 'missing-result') { $null } else { $validKnowledge }
            function Invoke-StageStep {
                param([string]$Name, [scriptblock]$Action, [switch]$Always)
                $seen.Add($Name)
                if ($Name -eq 'Workload.Function') { return }
                & $stageStepImplementation @PSBoundParameters
            }
            Assert-Throws { & $body } "Knowledge $mode blocks the real workload dispatcher on resume"
            Assert-Deployment (($seen -join ',') -eq 'Workload.Function,Workload.StageFixture,Workload.Knowledge') "Knowledge $mode stops before native publication"
            Assert-Deployment ($state.steps['Workload.Knowledge'].status -eq 'failed' -and
                (Get-Content $statePath -Raw | ConvertFrom-Json).steps.'Workload.Knowledge'.status -eq 'failed') "Knowledge $mode replaces cached success with a durable failure"
            Assert-Deployment ($global:DeploymentTest.nativeCalls -eq $callsBefore) "Knowledge $mode leaves native attempt and version untouched"
        }
        $global:DeploymentTest.knowledgeFailure = $false
        $global:DeploymentTest.knowledgeExit = $false
        $global:DeploymentTest.knowledgeResult = $validKnowledge
        $global:LASTEXITCODE = 0
        $bindingGuard = $acceleratorSyntax.Find({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$state.workload_fingerprint -and $state.workload_fingerprint -ne $workloadFingerprint'
        }, $true)
        foreach ($status in @('running', 'failed')) {
            $state = @{ workload_fingerprint = 'old'; steps = @{ 'Workload.Native' = @{ status = $status } } }
            $workloadFingerprint = 'changed-native-binding'
            $Resume = $false
            $failure = $null
            try { & ([scriptblock]::Create($bindingGuard.Extent.Text)) } catch { $failure = $_ }
            Assert-Deployment ($null -ne $failure -and $failure.Exception.Message -like '*outcome is unresolved*') "$status attempt blocks new output/tool binding even without Resume"
            Assert-Deployment ($state.steps['Workload.Native'].status -eq $status) "$status attempt is preserved before changing the runner source directory"
        }
    }
    & {
        $stateDirectory = Join-Path $temporary 'handoff'
        $manifest = $deploymentManifest
        $sourceAssignment = $acceleratorSyntax.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$sourceFiles' }, $true)
        . ([scriptblock]::Create($sourceAssignment.Extent.Text))
        $tools = @{ python = @{ version = '3.13.7'; sha256 = ('a' * 64); fileName = 'python-3.13.7-amd64.exe' } }
        $workloadFingerprint = 'stable-receipt-test'
        $handoffRoot = Join-Path $temporary 'transferred-runner'
        function Invoke-PrivateCommand {
            param([scriptblock]$Script, $Payload)
            $Payload.root = $handoffRoot
            & $Script ($Payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        }
        $nativeRequirements = Join-Path $root 'src\foundry_native_agent\requirements.txt'
        $originalHash = (Get-FileHash -LiteralPath $nativeRequirements).Hash
        $firstTransfer = Send-RunnerSource
        $runnerReceipt = Join-Path $firstTransfer.source '.azure\native-datasource-receipt.json'
        $null = New-Item -ItemType Directory -Path (Split-Path $runnerReceipt -Parent) -Force
        Set-Content -LiteralPath $runnerReceipt -Value '{"runner-owned-receipt":"preserve"}'
        $receiptHash = (Get-FileHash -LiteralPath $runnerReceipt).Hash
        $secondTransfer = Send-RunnerSource
        Assert-Deployment ($firstTransfer.source -ceq $secondTransfer.source) 'Unchanged workload reuses the same fingerprinted runner source directory'
        Assert-Deployment ((Get-FileHash -LiteralPath $runnerReceipt).Hash -ceq $receiptHash) 'Repeated source transfer preserves the runner-owned default datasource receipt'
        $Resume = $true
        $state = @{ steps = @{ 'Workload.Transfer' = @{ status = 'succeeded'; output = $secondTransfer } } }
        $resumedTransfer = Invoke-StageStep 'Workload.Transfer' { throw 'Normal resume must not transfer source again' }
        Assert-Deployment ($resumedTransfer.source -ceq $firstTransfer.source -and (Get-FileHash -LiteralPath $runnerReceipt).Hash -ceq $receiptHash) 'Normal runner resume retains its source path and datasource receipt'
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $stateDirectory 'source.zip'))
        try {
            Assert-Deployment (@($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq '.azure/native-datasource-receipt.json' }).Count -eq 0) 'Source archive cannot overwrite the runner-owned datasource receipt'
            foreach ($relative in @('src/foundry_native_agent/requirements.lock', 'src/hello_world/requirements.lock', 'src/shared/native-ingestion.json')) {
                $entry = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq $relative })
                Assert-Deployment ($entry.Count -eq 1) "Source handoff includes $relative"
                $stream = $entry[0].Open()
                try { Assert-Deployment ((Get-FileHash -InputStream $stream).Hash -eq (Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash) "Source handoff preserves $relative bytes" }
                finally { $stream.Dispose() }
            }
            $entry = $archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq 'src/foundry_native_agent/requirements.txt' }
            $reader = [IO.StreamReader]::new($entry.Open())
            try { Assert-Deployment ($reader.ReadToEnd() -ceq "--require-hashes`n-r requirements.lock`n") 'Native source handoff installs only the lock with hash enforcement' }
            finally { $reader.Dispose() }
            $reader = [IO.StreamReader]::new($archive.GetEntry('tool-manifest.json').Open())
            try { Assert-Deployment (($reader.ReadToEnd() | ConvertFrom-Json).python.sha256 -eq $tools.python.sha256) 'Source handoff propagates the pinned Python artifact' }
            finally { $reader.Dispose() }
            $reader = [IO.StreamReader]::new($archive.GetEntry('deployment-manifest.json').Open())
            try {
                $stagedManifest = $reader.ReadToEnd() | ConvertFrom-Json
                Assert-Deployment ($stagedManifest.native_ingestion.storage_resource_id -eq $nativeIngestion.storage_resource_id -and
                    @($stagedManifest.native_ingestion.shared_private_links.PSObject.Properties).Count -eq 3) 'Source handoff preserves the native storage and all link bindings'
            }
            finally { $reader.Dispose() }
        }
        finally { $archive.Dispose() }
        Assert-Deployment ((Get-FileHash -LiteralPath $nativeRequirements).Hash -eq $originalHash) 'Source handoff leaves native dependency inputs unchanged'
    }

    & {
        $bootstrapState = @{}
        $toolRoot = Join-Path $temporary 'bootstrap tools'
        $artifactRoot = Join-Path $temporary 'bootstrap artifacts'
        $null = New-Item -ItemType Directory -Path $artifactRoot -Force
        $tools = @{}
        foreach ($tool in @('azd', 'uv', 'python')) {
            $version = if ($tool -eq 'python') { '3.13.7' } else { '1.2.3' }
            $directory = Join-Path $toolRoot $(if ($tool -eq 'python') { "python$version" } else { "$tool-$version" })
            $executable = Join-Path $directory "$tool.exe"
            $null = New-Item -ItemType File -Path $executable -Force
            $tools[$tool] = @{ version = $version; binarySha256 = (Get-FileHash -LiteralPath $executable).Hash
                fileName = "$tool-fixture"; authenticode = @{ thumbprint = ('a' * 40) } }
            Set-Item -LiteralPath "Function:$executable" -Value {
                $global:LASTEXITCODE = 0
                if ($MyInvocation.MyCommand.Name -like '*azd.exe') { 'azd version 1.2.3'; return }
                if ($MyInvocation.MyCommand.Name -like '*uv.exe') { 'uv 1.2.3'; return }
                $bootstrapState.pythonCalls++
                Assert-Deployment ($args[0] -eq '-I' -and $args[1] -eq '-c' -and $args[2] -match 'sys.version_info\[:3\]') 'Runtime check uses isolated Python and the complete version tuple'
                if ($bootstrapState.scenario -eq 'python-error') { $global:LASTEXITCODE = 1 }
                if ($bootstrapState.scenario -eq 'wrong-patch') { '3.13.6' } else { '3.13.7' }
                if ($bootstrapState.scenario -eq 'wrong-arch') { '32' } else { '64' }
            }
        }
        $bootstrapPython = Join-Path $toolRoot 'python3.13.7\python.exe'
        $bootstrapDefinition = $acceleratorSyntax.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-RunnerTools' }, $true)
        $loop = $bootstrapDefinition.Find({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.Extent.Text -eq '$tool' }, $true)
        $bootstrapLoop = [scriptblock]::Create($loop.Extent.Text)
        function Get-AuthenticodeSignature {
            param($LiteralPath)
            $subject = if ($LiteralPath -like '*azd-fixture') { 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } else { 'CN=Python Software Foundation, O=Python Software Foundation, C=US' }
            $status = 'Valid'
            $thumbprint = 'a' * 40
            if ($LiteralPath -like '*python-fixture') {
                if ($bootstrapState.scenario -eq 'bad-signature') { $status = 'HashMismatch' }
                if ($bootstrapState.scenario -eq 'wrong-organization') { $subject = 'CN=Python Software Foundation, OU=Python Software Foundation, O=Other Publisher, C=US' }
                if ($bootstrapState.scenario -eq 'organization-suffix') { $subject = 'CN=Other Publisher, O=Python Software Foundation Other, C=US' }
                if ($bootstrapState.scenario -eq 'wrong-thumbprint') { $thumbprint = 'b' * 40 }
            }
            if ($LiteralPath -eq $bootstrapPython -and $bootstrapState.scenario -eq 'runtime-signer') { $subject = 'CN=Python Software Foundation, O=Other Publisher, C=US' }
            [pscustomobject]@{ Status = $status; SignerCertificate = @{ Subject = $subject; Thumbprint = $thumbprint } }
        }
        function New-Object {
            param($TypeName, $ArgumentList)
            if ($TypeName -ne 'Security.Principal.WindowsPrincipal') { throw "Unexpected COM or native object: $TypeName" }
            $principal = [pscustomobject]@{}
            $principal | Add-Member -MemberType ScriptMethod -Name IsInRole -Value { param($Role) $bootstrapState.scenario -ne 'not-admin' }
            $principal
        }
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$PassThru, [switch]$Wait)
            Assert-Deployment ($FilePath -eq (Join-Path $artifactRoot $tools.python.fileName)) 'Only the staged Python installer can be launched'
            $bootstrapState.installCalls++
            $bootstrapState.arguments = @($ArgumentList)
            Assert-Deployment ($PassThru -and $Wait) 'Bootstrap waits for the installer exit code'
            if ($bootstrapState.scenario -ne 'missing-executable') { $null = New-Item -ItemType File -Path $bootstrapPython -Force }
            $exitCode = switch ($bootstrapState.scenario) { 'restart' { 3010 }; 'install-failure' { 1603 }; default { 0 } }
            [pscustomobject]@{ ExitCode = $exitCode }
        }
        function Expand-Archive { throw 'No archive expansion expected with pre-staged fixture azd and uv binaries.' }
        foreach ($scenario in @('fresh', 'existing', 'wrong-patch', 'wrong-arch', 'python-error', 'bad-signature', 'wrong-organization', 'organization-suffix', 'wrong-thumbprint', 'runtime-signer', 'restart', 'install-failure', 'missing-executable', 'not-admin')) {
            $bootstrapState.Clear()
            $bootstrapState.scenario = $scenario
            $env:PATH = $originalPath
            if ($scenario -eq 'existing') { $null = New-Item -ItemType File -Path $bootstrapPython -Force }
            elseif (Test-Path -LiteralPath $bootstrapPython) { Remove-Item -LiteralPath $bootstrapPython }
            $failure = $null
            try { & $bootstrapLoop } catch { $failure = $_ }
            Assert-Deployment (($null -ne $failure) -eq ($scenario -notin @('fresh', 'existing'))) "Bootstrap outcome for $scenario ($failure)"
            Assert-Deployment ($env:PATH -notlike '*python3.13.7*') 'Bootstrap does not put Python on PATH'
            if ($scenario -eq 'fresh') {
                Assert-Deployment ($bootstrapState.installCalls -eq 1 -and $bootstrapState.pythonCalls -eq 1) 'Fresh runner installs Python once and validates the runtime'
                foreach ($argument in @('/quiet', '/norestart', 'InstallAllUsers=1', "TargetDir=`"$(Split-Path $bootstrapPython -Parent)`"", 'Include_launcher=0', 'InstallLauncherAllUsers=0', 'PrependPath=0', 'AppendPath=0', 'Include_test=0', 'Include_pip=0', 'AssociateFiles=0', 'Shortcuts=0')) {
                    Assert-Deployment ($bootstrapState.arguments -contains $argument) "Installer enforces $argument"
                }
            }
            if ($scenario -eq 'existing') { Assert-Deployment (-not $bootstrapState.installCalls -and $bootstrapState.pythonCalls -eq 1) 'Existing explicit runtime is validated without reinstalling or global discovery' }
            if ($scenario -eq 'restart') { Assert-Deployment ($failure.Exception.Message -like '*requires a restart*' -and -not $bootstrapState.pythonCalls) 'Exit 3010 requires restart and never reports a validated runtime' }
            if ($scenario -in @('bad-signature', 'wrong-organization', 'organization-suffix', 'wrong-thumbprint', 'not-admin')) {
                Assert-Deployment (-not $bootstrapState.installCalls -and -not $bootstrapState.pythonCalls) 'Invalid trust or privileges fail before install or runtime execution'
            }
        }
    }
    $global:LASTEXITCODE = 0
    Write-Output "PASS: $($global:DeploymentTest.checks) cloud-free deployment assertions; no Azure, installs, or real waits."
}
finally {
    $env:ProgramData = $originalProgramData
    $env:PATH = $originalPath
    $env:AZURE_SUBSCRIPTION_ID = $originalSubscription
    $env:AZURE_TENANT_ID = $originalTenant
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable DeploymentTest -Scope Global -ErrorAction SilentlyContinue
}
