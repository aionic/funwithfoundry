[CmdletBinding()]
param([ValidateSet('All', 'Probes', 'Consent', 'Teardown', 'Jumpbox', 'Verifier')][string]$Suite = 'All')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
$global:OperationalGuardState = @{}
$script:subscription = '11111111-1111-1111-1111-111111111111'
$script:outputs = @{
    foundry_primary_account_id = @{ value = "/subscriptions/$script:subscription/resourceGroups/rg-test-cus/providers/Microsoft.CognitiveServices/accounts/test-primary" }
    resource_groups = @{ value = @{ network = 'rg-test-net'; primary = 'rg-test-cus'; secondary = 'rg-test-scus' } }
    foundry_primary = @{ value = @{ account = 'test-primary'; project = 'test-project'; search = 'test-search'; cosmos = 'test-cosmos'; key_vault = 'test-kv'; storage = 'test-storage' } }
    foundry_secondary = @{ value = @{ account = 'test-secondary'; project = 'test-secondary-project'; staging_storage = 'test-staging' } }
    jumpbox = @{ value = @{ name = 'test-jump'; id = "/subscriptions/$script:subscription/resourceGroups/rg-test-cus/providers/Microsoft.Compute/virtualMachines/test-jump" } }
    sharepoint = @{ value = @{ hostname = 'test.sharepoint.com'; site_path = '/sites/test'; file_path = '/docs/test.txt' } }
    ingest_function = @{ value = @{ name = 'test-function'; hostname = 'test-function.azurewebsites.net'; identity_client = 'test-client'; identity_object = 'test-principal' } }
}
$global:OperationalGuardState.Subscription = $script:subscription
$global:OperationalGuardState.Outputs = $script:outputs
$global:OperationalGuardState.AzCalls = [System.Collections.Generic.List[object]]::new()
$global:OperationalGuardState.TfCalls = [System.Collections.Generic.List[object]]::new()

function Assert-Guard {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}

function az {
    $global:OperationalGuardState.AzCalls.Add(@($args))
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -eq 'account show --query id -o tsv') { return $global:OperationalGuardState.Subscription }
    if (-not $global:OperationalGuardState.AzHandler) { throw "Unmocked az command: $($args -join ' ')" }
    & $global:OperationalGuardState.AzHandler $args
}

function terraform {
    $global:OperationalGuardState.TfCalls.Add(@($args))
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -eq 'output -json') { return ($global:OperationalGuardState.Outputs | ConvertTo-Json -Depth 20) }
    if (($args -join ' ') -eq 'output -json ingest_function') { return ($global:OperationalGuardState.Outputs.ingest_function.value | ConvertTo-Json) }
    if (-not $global:OperationalGuardState.TfHandler) { throw "Unmocked terraform command: $($args -join ' ')" }
    & $global:OperationalGuardState.TfHandler $args
}

function Invoke-WebRequest {
    param($Uri, $Headers, $TimeoutSec, [switch]$UseBasicParsing, $ErrorAction)
    $global:OperationalGuardState.WebCalls++
    if ($global:OperationalGuardState.HttpStatus -eq 200) { return [pscustomobject]@{ StatusCode = 200 } }
    $exception = [System.Exception]::new('Mock HTTP error')
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $global:OperationalGuardState.HttpStatus })
    $record = [System.Management.Automation.ErrorRecord]::new($exception, 'MockHttp', 'InvalidOperation', $Uri)
    $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($global:OperationalGuardState.HttpBody)
    throw $record
}

function Invoke-GuardedScript {
    param([string]$Name, [hashtable]$Parameters = @{})
    $script:observed = [System.Collections.Generic.List[object]]::new()
    $script:failure = $null
    try {
        & (Join-Path $root "scripts\$Name") @Parameters 6>$null | ForEach-Object { $script:observed.Add($_) }
    }
    catch { $script:failure = $_ }
}

$allowedScripts = @('Grant-SharePointAccess.ps1', 'Stop-Lab.ps1', 'Test-PublicDataPlaneRefused.ps1', 'Verify-Deployment.ps1', 'Invoke-JumpboxScript.ps1')
foreach ($name in $allowedScripts) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root "scripts\$name"), [ref]$tokens, [ref]$parseErrors)
    Assert-Guard ($parseErrors.Count -eq 0) "$name parses: $parseErrors"
}
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
Assert-Guard ($parseErrors.Count -eq 0) 'Operational test script parses'

if ($Suite -in @('All', 'Probes')) {
    $global:OperationalGuardState.AzHandler = {
        param($command)
        if (($command -join ' ') -notlike 'account get-access-token *') { throw 'Unexpected probe command' }
        if ($global:OperationalGuardState.TokenMissing) { $global:LASTEXITCODE = 1; return }
        'mock-token'
    }
    foreach ($case in @(
        @{ Code = 200; Body = ''; Outcome = 'Reachable'; Fails = $true },
        @{ Code = 403; Body = '{"error":{"message":"Forbidden: authorization denied"}}'; Outcome = 'UnauthorizedOrInconclusive'; Fails = $true },
        @{ Code = 403; Body = '{"error":{"message":"Public network access is disabled"}}'; Outcome = 'NetworkDenied'; Fails = $false },
        @{ Code = 403; Body = '{"error":{"message":"Request is denied as the source is not allowed by applicable rules. The service is set publicNetworkAccess: Disabled."}}'; Outcome = 'NetworkDenied'; Fails = $false },
        @{ Code = 0; Body = 'DNS lookup failed'; Outcome = 'Inconclusive'; Fails = $true }
    )) {
        $global:OperationalGuardState.HttpStatus = $case.Code
        $global:OperationalGuardState.HttpBody = $case.Body
        $global:OperationalGuardState.TokenMissing = $false
        Invoke-GuardedScript 'Test-PublicDataPlaneRefused.ps1'
        Assert-Guard (($null -ne $script:failure) -eq $case.Fails) "HTTP $($case.Code) must have expected failure verdict"
        Assert-Guard ($script:observed.Count -eq 3) 'Every endpoint returns a structured result'
        Assert-Guard (@($script:observed | Where-Object Outcome -ne $case.Outcome).Count -eq 0) "HTTP $($case.Code) classified as $($case.Outcome)"
        if ($case.Fails) { Assert-Guard (@($script:observed | Where-Object Status -eq 'PASS').Count -eq 0) 'Inconclusive/reachable is never PASS' }
    }
    $global:OperationalGuardState.TokenMissing = $true
    $global:OperationalGuardState.WebCalls = 0
    Invoke-GuardedScript 'Test-PublicDataPlaneRefused.ps1'
    Assert-Guard ($null -ne $script:failure) 'Missing token fails the run'
    Assert-Guard ($global:OperationalGuardState.WebCalls -eq 0) 'Missing token never attempts an unauthenticated probe'
    Assert-Guard (@($script:observed | Where-Object Outcome -ne 'TokenUnavailable').Count -eq 0) 'Missing token is explicit'
}

if ($Suite -in @('All', 'Teardown')) {
    $stateResources = @(
        foreach ($pair in @(@('net', 'rg-test-net'), @('primary', 'rg-test-cus'), @('secondary', 'rg-test-scus'))) {
            @{ mode = 'managed'; address = "azurerm_resource_group.$($pair[0])"; values = @{ id = "/subscriptions/$subscription/resourceGroups/$($pair[1])" } }
        }
        foreach ($pair in @(@('primary', 'cus'), @('secondary', 'scus'))) {
            @{ mode = 'managed'; address = "module.foundry_$($pair[0]).azapi_resource.foundry"; values = @{ id = "/subscriptions/$subscription/resourceGroups/rg-test-$($pair[1])/providers/Microsoft.CognitiveServices/accounts/test-$($pair[0])"; location = 'test-region' } }
        }
    )
    $global:OperationalGuardState.TerraformState = @{ values = @{ root_module = @{ resources = $stateResources } } }
    function Read-Host { param($Prompt) $global:OperationalGuardState.Confirmation }
    function Get-Date { $global:OperationalGuardState.Now }
    function Start-Sleep { param($Seconds) $global:OperationalGuardState.Now = $global:OperationalGuardState.Now.AddSeconds(61) }
    $global:OperationalGuardState.TfHandler = {
        param($command)
        if (($command -join ' ') -eq 'show -json') { return ($global:OperationalGuardState.TerraformState | ConvertTo-Json -Depth 20) }
        if ($command[0] -ne 'destroy') { throw 'Unexpected Terraform command' }
        $global:OperationalGuardState.DestroyCount++
        if ($global:OperationalGuardState.DestroyCount -eq $global:OperationalGuardState.FailDestroy) { $global:LASTEXITCODE = 1 }
    }
    $global:OperationalGuardState.AzHandler = {
        param($command)
        $joined = $command -join ' '
        if ($joined -like 'cognitiveservices account list-deleted *') {
            $entries = @(
                foreach ($pair in @(@('primary', 'cus'), @('secondary', 'scus'))) {
                    if ($global:OperationalGuardState.Purged -notcontains "test-$($pair[0])") {
                        @{ id = "/subscriptions/$($global:OperationalGuardState.Subscription)/providers/Microsoft.CognitiveServices/locations/test-region/resourceGroups/rg-test-$($pair[1])/deletedAccounts/test-$($pair[0])"; name = "test-$($pair[0])"; location = 'test-region' }
                    }
                }
                @{ id = '/subscriptions/other/providers/Microsoft.CognitiveServices/locations/test-region/resourceGroups/rg-test-cus/deletedAccounts/test-primary'; name = 'test-primary'; location = 'test-region' }
                @{ id = "/subscriptions/$($global:OperationalGuardState.Subscription)/providers/Microsoft.CognitiveServices/locations/test-region/resourceGroups/rg-other/deletedAccounts/test-primary"; name = 'test-primary'; location = 'test-region' }
                @{ id = "/subscriptions/$($global:OperationalGuardState.Subscription)/providers/Microsoft.CognitiveServices/locations/test-region/resourceGroups/rg-test-cus/deletedAccounts/fwf-unrelated"; name = 'fwf-unrelated'; location = 'test-region' }
            )
            return (ConvertTo-Json -InputObject $entries -Depth 10)
        }
        if ($joined -like 'cognitiveservices account list *') {
            if ($global:OperationalGuardState.PollError) { $global:LASTEXITCODE = 1; return }
            if ($global:OperationalGuardState.Timeout) { return '[{"name":"test-primary","properties":{"provisioningState":"Deleting"}}]' }
            return '[]'
        }
        if ($joined -like 'cognitiveservices account purge *') {
            if ($global:OperationalGuardState.PurgeError) { $global:LASTEXITCODE = 1; return }
            $global:OperationalGuardState.Purged += $command[[array]::IndexOf($command, '--name') + 1]
            return
        }
        if ($joined -like 'group exists *') { return 'false' }
        throw "Unexpected teardown command: $joined"
    }
    foreach ($scenario in @('success', 'abort', 'host-error', 'delete-error', 'poll-error', 'purge-error', 'timeout', 'wrong-subscription')) {
        $global:OperationalGuardState.AzCalls.Clear()
        $global:OperationalGuardState.TfCalls.Clear()
        $global:OperationalGuardState.Purged = @()
        $global:OperationalGuardState.DestroyCount = 0
        $global:OperationalGuardState.Confirmation = if ($scenario -eq 'abort') { 'NO' } else { 'DESTROY' }
        $global:OperationalGuardState.FailDestroy = switch ($scenario) { 'host-error' { 1 } 'delete-error' { 2 } default { 0 } }
        $global:OperationalGuardState.PollError = $scenario -eq 'poll-error'
        $global:OperationalGuardState.PurgeError = $scenario -eq 'purge-error'
        $global:OperationalGuardState.Timeout = $scenario -eq 'timeout'
        $global:OperationalGuardState.Now = [datetime]'2026-09-09T12:00:00Z'
        $global:OperationalGuardState.Subscription = if ($scenario -eq 'wrong-subscription') { 'wrong-subscription' } else { $subscription }
        Invoke-GuardedScript 'Stop-Lab.ps1' @{ Mode = 'Teardown'; TimeoutMinutes = 1 }
        Assert-Guard (($null -ne $failure) -eq ($scenario -notin @('success', 'abort'))) "Teardown $scenario verdict"
        $fullDestroy = @($global:OperationalGuardState.TfCalls | Where-Object { $_.Count -eq 1 -and $_[0] -eq 'destroy' })
        Assert-Guard ($fullDestroy.Count -eq [int]($scenario -eq 'success')) "Teardown $scenario gates final destruction"
        Assert-Guard (@($global:OperationalGuardState.TfCalls | Where-Object { ($_ -join ' ') -match 'auto-approve' }).Count -eq 0) 'Terraform confirmation is never bypassed'
        if ($scenario -eq 'success') {
            $accountDestroy = @($global:OperationalGuardState.TfCalls | Where-Object { $_ -contains '-target=module.foundry_primary.azapi_resource.foundry' })
            Assert-Guard ($accountDestroy.Count -eq 1 -and $accountDestroy[0] -contains '-parallelism=1') 'Account dependency deletes are serialized to prevent connection ETag conflicts'
            Assert-Guard (($global:OperationalGuardState.Purged -join ',') -eq 'test-primary,test-secondary') 'Only exact Terraform account names are purged'
            foreach ($call in @($global:OperationalGuardState.AzCalls | Where-Object { $_[0] -ne 'account' })) {
                Assert-Guard ($call[[array]::IndexOf($call, '--subscription') + 1] -eq $subscription) 'Every teardown Azure call is subscription scoped'
                if ($call[2] -eq 'purge') {
                    $name = $call[[array]::IndexOf($call, '--name') + 1]
                    $group = $call[[array]::IndexOf($call, '--resource-group') + 1]
                    Assert-Guard (($name -eq 'test-primary' -and $group -eq 'rg-test-cus') -or ($name -eq 'test-secondary' -and $group -eq 'rg-test-scus')) 'Purge uses the exact account/group pair'
                }
            }
        }
        if ($scenario -in @('abort', 'wrong-subscription')) { Assert-Guard ($global:OperationalGuardState.DestroyCount -eq 0) 'Confirmation/scope failure prevents every destroy' }
    }
    $global:OperationalGuardState.Subscription = $subscription
}

if ($Suite -in @('All', 'Jumpbox')) {
    function Get-Content {
        param([string]$LiteralPath, [switch]$Raw)
        if ($LiteralPath -like '*\Test-PrivatePath.ps1' -and $global:OperationalGuardState.RemoteBody) { return $global:OperationalGuardState.RemoteBody }
        Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw
    }
    $remoteBodies = @{
        'execute-success' = 'param(); "mock output"'
        'execute-throw' = 'throw "mock error"'
        'execute-failure-result' = '[pscustomobject]@{ Outcome = "Failed" }'
        'execute-caught-error' = 'try { throw "mock error" } catch {}; "still running"'
        'execute-native-error' = '$global:LASTEXITCODE = 3'
    }
    $global:OperationalGuardState.AzHandler = {
        param($command)
        if (($command -join ' ') -notlike 'vm run-command invoke *') { throw 'Unexpected jumpbox command' }
        $fileArg = $command[[array]::IndexOf($command, '--scripts') + 1]
        $global:OperationalGuardState.PayloadFile = $fileArg.Substring(1)
        $payload = Get-Content -LiteralPath $global:OperationalGuardState.PayloadFile -Raw
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'Generated Run Command payload does not parse' }
        $marker = [regex]::Match($payload, 'FWF_RUN_RESULT_[a-f0-9]+=')
        $global:OperationalGuardState.ValidPayload = $marker.Success
        $message = $marker.Value + '{"succeeded":true,"exitCode":0,"errorCount":0}'
        $code = 'ComponentStatus/StdOut/succeeded'
        $stderr = ''
        switch ($global:OperationalGuardState.RemoteCase) {
            'cli-error' { $global:LASTEXITCODE = 1; return }
            'remote-error' { $message = $marker.Value + '{"succeeded":false,"exitCode":1,"errorCount":1}' }
            'status-error' { $code = 'ComponentStatus/StdOut/failed' }
            'missing-marker' { $message = 'looks good' }
            'stderr' { $stderr = 'Unhandled exception' }
            'failure-text' { $message = "RESOLVE FAILED`n$message" }
            'wrapped' { $code = 'ProvisioningState/succeeded'; $message = "Enable succeeded:`n[stdout]`n$message`n[stderr]`n" }
        }
        if ($global:OperationalGuardState.RemoteBody) {
            $runner = [powershell]::Create()
            try { $message = ($runner.AddScript($payload).Invoke() | Out-String).TrimEnd() }
            finally { $runner.Dispose() }
        }
        @{ value = @(@{ code = $code; level = 'Info'; message = $message }, @{ code = 'ComponentStatus/StdErr/succeeded'; level = 'Info'; message = $stderr }) } | ConvertTo-Json -Depth 10
    }
    foreach ($scenario in (@('success', 'wrapped', 'cli-error', 'remote-error', 'status-error', 'missing-marker', 'stderr', 'failure-text') + @($remoteBodies.Keys))) {
        $global:OperationalGuardState.RemoteCase = $scenario
        $global:OperationalGuardState.RemoteBody = $remoteBodies[$scenario]
        $global:OperationalGuardState.ValidPayload = $false
        Invoke-GuardedScript 'Invoke-JumpboxScript.ps1' @{ Script = 'Test-PrivatePath.ps1' }
        Assert-Guard (($null -ne $failure) -eq ($scenario -notin @('success', 'wrapped', 'execute-success'))) "Jumpbox $scenario verdict"
        Assert-Guard $global:OperationalGuardState.ValidPayload 'Generated payload parses and carries a per-run marker'
        Assert-Guard (-not (Test-Path -LiteralPath $global:OperationalGuardState.PayloadFile)) 'Run Command temporary file is removed even on failure'
    }
}

if ($Suite -in @('All', 'Verifier')) {
    $global:OperationalGuardState.Outputs.foundry_primary_account_id = @{ value = "/subscriptions/$subscription/resourceGroups/rg-test-cus/providers/Microsoft.CognitiveServices/accounts/test-primary" }
    $global:OperationalGuardState.Outputs.foundry_agent_subnet_id = @{ value = "/subscriptions/$subscription/resourceGroups/rg-test-cus/providers/Microsoft.Network/virtualNetworks/test-vnet/subnets/test-agent" }
    $global:OperationalGuardState.Outputs.hub_ids = @{ value = @{ primary = "/subscriptions/$subscription/resourceGroups/rg-test-net/providers/Microsoft.Network/virtualHubs/test-hub-primary"; secondary = "/subscriptions/$subscription/resourceGroups/rg-test-net/providers/Microsoft.Network/virtualHubs/test-hub-secondary" } }
    $global:OperationalGuardState.Outputs.ingest_function.value.storage = 'test-function-storage'
    $global:OperationalGuardState.AzHandler = {
        param($command)
        $scenario = $global:OperationalGuardState.VerifyCase
        $joined = $command -join ' '
        if ($scenario -eq 'query-error') { $global:LASTEXITCODE = 1; return }
        if ($joined -like 'resource show *') {
            $id = $command[[array]::IndexOf($command, '--ids') + 1]
            if ($scenario -eq 'missing-resource') { return '{}' }
            return (@{ id = $id; properties = @{ publicNetworkAccess = 'Disabled'; disableLocalAuth = ($scenario -ne 'local-auth') } } | ConvertTo-Json)
        }
        if ($joined -like 'network private-endpoint list *') {
            if ($scenario -eq 'missing-pe') { return '[]' }
            $group = $command[[array]::IndexOf($command, '-g') + 1]
            $definitions = if ($group -eq 'rg-test-cus') {
                @(@('Microsoft.CognitiveServices/accounts', 'test-primary', 'account'), @('Microsoft.Search/searchServices', 'test-search', 'searchService'), @('Microsoft.Storage/storageAccounts', 'test-storage', 'blob'), @('Microsoft.DocumentDB/databaseAccounts', 'test-cosmos', 'Sql'), @('Microsoft.KeyVault/vaults', 'test-kv', 'vault'))
            }
            else {
                @(@('Microsoft.CognitiveServices/accounts', 'test-secondary', 'account'), @('Microsoft.Storage/storageAccounts', 'test-staging', 'blob'), @('Microsoft.Web/sites', 'test-function', 'sites'), @('Microsoft.Storage/storageAccounts', 'test-function-storage', 'blob'), @('Microsoft.Storage/storageAccounts', 'test-function-storage', 'queue'), @('Microsoft.Storage/storageAccounts', 'test-function-storage', 'table'))
            }
            $endpoints = @(foreach ($definition in $definitions) {
                if ($scenario -eq 'one-missing-pe' -and $definition[2] -eq 'queue') { continue }
                @{ name = "pe-$($definition[1])-$($definition[2])"; provisioningState = 'Succeeded'; privateLinkServiceConnections = @(@{ privateLinkServiceId = "/subscriptions/$($global:OperationalGuardState.Subscription)/resourceGroups/$group/providers/$($definition[0])/$($definition[1])"; groupIds = @($definition[2]); privateLinkServiceConnectionState = @{ status = 'Approved' } }) }
            })
            return (ConvertTo-Json -InputObject $endpoints -Depth 10)
        }
        if ($joined -like 'network vnet subnet show *') {
            if ($scenario -eq 'missing-subnet') { return '{}' }
            return (@{ id = $global:OperationalGuardState.Outputs.foundry_agent_subnet_id.value; delegations = @(@{ serviceName = 'Microsoft.App/environments' }); routeTable = @{ id = $(if ($scenario -eq 'route-table') { 'unexpected-table' } else { $null }) } } | ConvertTo-Json -Depth 10)
        }
        if ($joined -like 'rest --method get *') {
            $url = $command[[array]::IndexOf($command, '--url') + 1]
            if ($url -like '*/capabilityHosts?*') {
                if ($scenario -eq 'missing-host') { return '{"value":[]}' }
                return (@{ value = @(@{ name = 'test-host'; properties = @{ capabilityHostKind = 'Agents'; provisioningState = 'Succeeded'; vectorStoreConnections = @('test-search'); storageConnections = @('test-storage'); threadStorageConnections = @('test-cosmos') } }) } | ConvertTo-Json -Depth 10)
            }
            if ($url -like '*/routingIntent?*') {
                if ($scenario -eq 'missing-routing') { return '{"value":[]}' }
                return '{"value":[{"properties":{"routingPolicies":[{"destinations":["Internet"],"nextHop":"test-firewall"},{"destinations":["PrivateTraffic"],"nextHop":"test-firewall"}]}}]}'
            }
            if ($url -like '*/projects/*') {
                if ($scenario -eq 'missing-project') { return '{}' }
                return (@{ id = ($url -split '\?')[0].Replace('https://management.azure.com', '') } | ConvertTo-Json)
            }
        }
        throw "Unexpected verification command: $joined"
    }
    foreach ($scenario in @('success', 'query-error', 'missing-resource', 'missing-pe', 'one-missing-pe', 'missing-subnet', 'missing-host', 'missing-project', 'missing-routing', 'local-auth', 'route-table')) {
        $global:OperationalGuardState.VerifyCase = $scenario
        Invoke-GuardedScript 'Verify-Deployment.ps1'
        Assert-Guard (($null -ne $failure) -eq ($scenario -ne 'success')) "Verifier $scenario verdict"
        if ($scenario -ne 'success') { Assert-Guard (@($observed | Where-Object Status -eq 'FAIL').Count -gt 0) "Verifier $scenario emits a failing check" }
    }
}

if ($Suite -in @('All', 'Consent')) {
    $global:OperationalGuardState.AzHandler = {
        param($command)
        $scenario = $global:OperationalGuardState.ConsentCase
        $joined = $command -join ' '
        if ($joined -like 'ad sp show *') {
            return '{"id":"graph-resource","appRoles":[{"id":"selected-role","value":"Sites.Selected","isEnabled":true,"allowedMemberTypes":["Application"]},{"id":"broad-role","value":"Sites.Read.All","isEnabled":true,"allowedMemberTypes":["Application"]}]}'
        }
        if ($command[0] -ne 'rest') { throw 'Unexpected consent command' }
        $url = $command[[array]::IndexOf($command, '--url') + 1]
        $method = $command[[array]::IndexOf($command, '--method') + 1]
        if ($method -eq 'post') {
            $payloadPath = $command[[array]::IndexOf($command, '--body') + 1].Substring(1)
            $global:OperationalGuardState.ConsentFiles.Add($payloadPath)
            $payload = Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json
            $global:OperationalGuardState.ConsentWrites.Add(@{ Uri = $url; Body = $payload })
            if ($scenario -eq 'denied' -and $url -like '*/permissions') { $global:LASTEXITCODE = 1; return }
            return '{"id":"new-grant"}'
        }
        if ($url -like '*/appRoleAssignments*') {
            if ($scenario -eq 'lookup-error') { $global:LASTEXITCODE = 1; return }
            if ($scenario -eq 'wrong-resource') { return '{"value":[{"principalId":"test-principal","resourceId":"other-resource","appRoleId":"selected-role"}]}' }
            if ($scenario -eq 'wrong-principal') { return '{"value":[{"principalId":"other-principal","resourceId":"graph-resource","appRoleId":"selected-role"}]}' }
            if ($scenario -eq 'existing' -and $url -notmatch '\?') { return '{"value":[],"@odata.nextLink":"https://graph.microsoft.com/v1.0/servicePrincipals/test-principal/appRoleAssignments?page=2"}' }
            if ($scenario -eq 'existing') { return '{"value":[{"principalId":"test-principal","resourceId":"graph-resource","appRoleId":"selected-role"}]}' }
            return '{"value":[]}'
        }
        if ($url -like '*/permissions') {
            if ($scenario -eq 'site-read-error') { $global:LASTEXITCODE = 1; return }
            if ($scenario -eq 'mismatched-role') { return '{"value":[{"id":"site-grant","roles":["write"],"grantedToIdentitiesV2":[{"application":{"id":"test-client"}}]}]}' }
            if ($scenario -eq 'existing') { return '{"value":[{"id":"site-grant","roles":["read"],"grantedToIdentitiesV2":[{"application":{"id":"test-client"}}]}]}' }
            return '{"value":[]}'
        }
        if ($url -eq 'https://graph.microsoft.com/v1.0/sites/test.sharepoint.com:/sites/test') { return '{"id":"test-site","displayName":"Test site"}' }
        throw "Unexpected Graph URL: $url"
    }
    foreach ($scenario in @('new', 'existing', 'denied', 'lookup-error', 'site-read-error', 'mismatched-role', 'wrong-resource', 'wrong-principal')) {
        $global:OperationalGuardState.ConsentCase = $scenario
        $global:OperationalGuardState.ConsentFiles = [System.Collections.Generic.List[string]]::new()
        $global:OperationalGuardState.ConsentWrites = [System.Collections.Generic.List[object]]::new()
        Invoke-GuardedScript 'Grant-SharePointAccess.ps1'
        Assert-Guard (($null -ne $failure) -eq ($scenario -in @('denied', 'lookup-error', 'site-read-error', 'mismatched-role'))) "Consent $scenario verdict"
        foreach ($file in $global:OperationalGuardState.ConsentFiles) { Assert-Guard (-not (Test-Path -LiteralPath $file)) 'Consent payload is removed even on failure' }
        $writes = $global:OperationalGuardState.ConsentWrites
        if ($scenario -in @('existing', 'lookup-error', 'site-read-error', 'mismatched-role')) { Assert-Guard ($writes.Count -eq 0) 'Exact existing consent/errors do not produce duplicate or speculative grants' }
        else { Assert-Guard ($writes.Count -eq 2) 'Only one exact application role and one site grant are attempted' }
        foreach ($write in $writes) {
            if ($write.Uri -like '*/appRoleAssignments') {
                Assert-Guard ($write.Body.principalId -eq 'test-principal' -and $write.Body.resourceId -eq 'graph-resource' -and $write.Body.appRoleId -eq 'selected-role') 'Role grant uses the exact principal, Graph resource, and Sites.Selected role'
            }
            else {
                Assert-Guard ($write.Uri -eq 'https://graph.microsoft.com/v1.0/sites/test-site/permissions' -and @($write.Body.roles).Count -eq 1 -and $write.Body.roles[0] -eq 'read' -and $write.Body.grantedToIdentities[0].application.id -eq 'test-client') 'Site grant uses the configured site/client and requested read role'
            }
        }
    }
}

Write-Host "PASS: $script:checks operational guard checks ($Suite), mocked commands only."
