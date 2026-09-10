[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$parameters = @{
    EnvironmentName = 'bootstrap-test'
    ProjectId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.CognitiveServices/accounts/test/projects/test'
    Location = 'centralus'
    ProjectEndpoint = 'https://example.invalid/api/projects/test'
    ModelDeployment = 'test-model'
    SearchEndpoint = 'https://example.invalid'
    SearchConnectionName = 'test-search'
}
$desired = @{
    endpoint = 'https://example.invalid/toolboxes/foundry-rag'
    version = @{
        version = '7'
        tools = @(@{
            type = 'azure_ai_search'; name = 'test-search'
            azure_ai_search = @{ indexes = @(@{
                project_connection_id = "$($parameters.ProjectId)/connections/test-search"
                index_name = 'spo-docs'; query_type = 'simple'; top_k = 5
            }) }
        })
    }
}
$mockState = @{ Calls = [System.Collections.Generic.List[string]]::new() }

function az { throw 'Live Azure commands are prohibited in this test.' }
function terraform { throw 'Terraform is not needed when deployment values are supplied.' }
function azd {
    $command = $args -join ' '
    $mockState.Calls.Add($command)
    $global:LASTEXITCODE = 0
    switch -Wildcard ($command) {
        'env list --output json' {
            if ($mockState.Scenario -eq 'env-failure') { $global:LASTEXITCODE = 9; return '[]' }
            return '[{"name":"bootstrap-test"}]'
        }
        'env select bootstrap-test --no-prompt' { return }
        'env set *' { return }
        'ai connection list *' {
            $mockState.ConnectionReads++
            if ($mockState.Scenario -eq 'transient-read' -and $mockState.ConnectionReads -eq 1) {
                $global:LASTEXITCODE = 1
                return 'ERROR: AzureDeveloperCLICredential: exit status 1'
            }
            return '[{"name":"test-search"}]'
        }
        'ai toolbox list *' {
            if ($mockState.Scenario -eq 'absent') { return '{"toolboxes":[]}' }
            return '{"toolboxes":[{"name":"foundry-rag"}]}'
        }
        'ai toolbox show foundry-rag *' {
            if ($mockState.Scenario -eq 'read-only-toolbox-empty') { return }
            if ($mockState.Scenario -eq 'read-only-toolbox-null') { return 'null' }
            if ($mockState.Scenario -eq 'read-only-toolbox-malformed') { return '{broken-json' }
            if ($mockState.Scenario -eq 'read-only-transient-toolbox' -and @($mockState.Calls | Where-Object { $_ -like 'ai toolbox show *' }).Count -eq 1) {
                $global:LASTEXITCODE = 1
                return 'ERROR: connection reset'
            }
            $toolbox = $desired | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            if ($mockState.Scenario -eq 'mismatch' -and -not $mockState.Published) {
                $toolbox.version.tools[0].azure_ai_search.indexes[0].top_k = 1
            }
            return ($toolbox | ConvertTo-Json -Depth 12)
        }
        'ai toolbox create foundry-rag --from-file *' { return }
        'ai toolbox deploy *' { return '{"version":{"version":"7"}}' }
        'ai toolbox publish foundry-rag 7 *' { $mockState.Published = $true; return }
        'deploy funwithfoundry-rag-agent *' {
            if ($mockState.Scenario -eq 'deploy-failure') {
                $global:LASTEXITCODE = 1
                return 'ERROR: AzureDeveloperCLICredential: exit status 1'
            }
            return
        }
        'ai agent show funwithfoundry-rag-agent *' {
            if ($mockState.Scenario -eq 'read-only-agent-empty') { return }
            if ($mockState.Scenario -eq 'read-only-agent-null') { return 'null' }
            if ($mockState.Scenario -eq 'read-only-agent-malformed') { return '{broken-json' }
            if ($mockState.Scenario -eq 'read-only-exhausted' -or
                ($mockState.Scenario -eq 'read-only-transient-agent' -and @($mockState.Calls | Where-Object { $_ -like 'ai agent show *' }).Count -eq 1)) {
                $global:LASTEXITCODE = 1
                return 'ERROR: AzureDeveloperCLICredential: exit status 1'
            }
            return '{"version":{"version":"1"}}'
        }
        default { throw "Unmocked azd command: $command" }
    }
}

$originalTemp = $env:TEMP
$testTemp = Join-Path ([System.IO.Path]::GetTempPath()) "fwf-bootstrap-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testTemp
$env:TEMP = $testTemp
try {
    foreach ($scenario in @('absent', 'correct', 'mismatch', 'env-failure', 'transient-read', 'deploy-failure')) {
        $mockState.Scenario = $scenario
        $mockState.ConnectionReads = 0
        $mockState.Published = $false
        $mockState.Calls.Clear()
        $failure = $null
        try { & (Join-Path $root 'scripts/Deploy-NativeFoundryAgent.ps1') @parameters | Out-Null }
        catch { $failure = $_ }
        if ($scenario -eq 'env-failure') {
            if (-not $failure -or $failure.Exception.Message -notmatch 'azd env list --output failed \(exit 9\)' -or $mockState.Calls.Count -ne 1) {
                throw 'Environment failure must stop deployment at the failed command.'
            }
        }
        elseif ($scenario -eq 'deploy-failure') {
            if (-not $failure -or $failure.Exception.Message -notmatch 'azd deploy funwithfoundry-rag-agent --environment failed' -or
                @($mockState.Calls | Where-Object { $_ -like 'deploy *' }).Count -ne 1 -or $mockState.Calls[-1] -notlike 'deploy *') {
                throw 'A transient-looking native deployment failure must never be retried.'
            }
        }
        else {
            if ($failure) { throw $failure }
            $mutations = @($mockState.Calls | Where-Object { $_ -match '^ai toolbox (create|deploy|publish) ' } | ForEach-Object { ($_ -split ' ')[2] }) -join ','
            $expected = switch ($scenario) { 'absent' { 'create' }; 'correct' { '' }; 'mismatch' { 'deploy,publish' }; 'transient-read' { '' } }
            if ($mutations -ne $expected) { throw "${scenario}: expected '$expected', observed '$mutations'." }
            if ($mockState.Calls[-1] -notlike 'ai agent show *') { throw "${scenario}: agent verification was not reached." }
            if ($scenario -eq 'transient-read' -and ($mockState.ConnectionReads -ne 2 -or @($mockState.Calls | Where-Object { $_ -like 'deploy *' }).Count -ne 1)) {
                throw 'Only the transient read may be retried; native deployment runs once.'
            }
        }
        if (@(Get-ChildItem -LiteralPath $testTemp).Count) { throw "${scenario}: toolbox temporary file leaked." }
        Write-Host "PASS native bootstrap: $scenario"
    }
    $readParameters = @{ ReadOnly = $true; ProjectEndpoint = $parameters.ProjectEndpoint; EnvironmentName = $parameters.EnvironmentName; AzdDebug = $true }
    foreach ($scenario in @('read-only', 'read-only-transient-agent', 'read-only-transient-toolbox', 'read-only-exhausted')) {
        $mockState.Scenario = $scenario
        $mockState.Calls.Clear()
        $failure = $null
        try { $metadata = & (Join-Path $root 'scripts/Deploy-NativeFoundryAgent.ps1') @readParameters }
        catch { $failure = $_ }
        $agentReads = if ($scenario -eq 'read-only-exhausted') { 3 } elseif ($scenario -eq 'read-only-transient-agent') { 2 } else { 1 }
        $toolboxReads = if ($scenario -eq 'read-only-exhausted') { 0 } elseif ($scenario -eq 'read-only-transient-toolbox') { 2 } else { 1 }
        $expectedCalls = @('ai agent show funwithfoundry-rag-agent --environment bootstrap-test --output json --debug') * $agentReads
        $expectedCalls += @("ai toolbox show foundry-rag --project-endpoint $($parameters.ProjectEndpoint) --output json --debug") * $toolboxReads
        if (($mockState.Calls -join "`n") -ne ($expectedCalls -join "`n")) { throw "${scenario}: read-only metadata must issue only the bounded JSON show calls." }
        if ($scenario -eq 'read-only-exhausted') {
            if (-not $failure -or $failure.Exception.Message -notmatch 'azd ai agent show failed') { throw 'Exhausted read retries must fail closed.' }
        }
        else {
            if ($failure) { throw $failure }
            if ($metadata -isnot [pscustomobject] -or $metadata.agent.version.version -ne '1' -or $metadata.toolbox.version.version -ne '7') {
                throw 'Read-only metadata must return the parsed agent and toolbox together.'
            }
        }
        Write-Host "PASS native bootstrap: $scenario"
    }
    foreach ($target in @('agent', 'toolbox')) {
        foreach ($response in @('empty', 'null', 'malformed')) {
            $mockState.Scenario = "read-only-$target-$response"
            $mockState.Calls.Clear()
            $failure = $null
            try { $null = & (Join-Path $root 'scripts/Deploy-NativeFoundryAgent.ps1') @readParameters }
            catch { $failure = $_ }
            $expectedCount = if ($target -eq 'agent') { 1 } else { 2 }
            if (-not $failure -or $mockState.Calls.Count -ne $expectedCount -or @($mockState.Calls | Where-Object { $_ -notmatch '^ai (agent|toolbox) show ' }).Count) {
                throw "$($mockState.Scenario): invalid metadata must fail without retries or writes."
            }
            Write-Host "PASS native bootstrap: $($mockState.Scenario)"
        }
    }
    foreach ($missing in @('ProjectEndpoint', 'EnvironmentName')) {
        $invalidParameters = $readParameters.Clone()
        $invalidParameters[$missing] = ''
        $mockState.Calls.Clear()
        $failure = $null
        try { $null = & (Join-Path $root 'scripts/Deploy-NativeFoundryAgent.ps1') @invalidParameters }
        catch { $failure = $_ }
        if (-not $failure -or $failure.Exception.Message -notmatch 'requires ProjectEndpoint and EnvironmentName' -or $mockState.Calls.Count) {
            throw "Read-only missing $missing must fail before any CLI calls."
        }
        Write-Host "PASS native bootstrap: read-only missing $missing"
    }
}
finally {
    $env:TEMP = $originalTemp
    Remove-Item -LiteralPath $testTemp -Recurse -Force
}
