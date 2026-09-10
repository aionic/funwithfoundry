[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'scripts\Send-RunnerArtifacts.ps1'
$tokens = $null
$parseErrors = $null
$syntax = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors -join "`n") }
foreach ($definition in $syntax.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$nativeArtifactCommand = ${function:Invoke-ArtifactCommand}
$script:checks = 0
function Assert-Transfer {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-Transfer ($null -ne $failure) $Message
}
function az { throw 'Live Azure calls prohibited.' }
function terraform { throw 'Live Terraform calls prohibited.' }

$userCommand = $syntax.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-LocalUser' }, $true)
$descriptionExpression = $userCommand.CommandElements[-1].Extent.Text
$payload = @{ id = '0123456789abcdef0123456789abcdef' }
$accountDescription = & ([scriptblock]::Create($descriptionExpression))
Assert-Transfer ($accountDescription.Length -le 48 -and $accountDescription.EndsWith($payload.id)) 'Windows account description fits 48 characters and preserves ownership ID'

$boundary = Get-ArtifactNetworkBoundary '10.42.8.0/26'
Assert-Transfer ($boundary.last - $boundary.first -eq 63) 'Exact Bastion subnet boundary'
foreach ($cidr in @('0.0.0.0/0', '8.8.0.0/16', '10.0.0.1/26', '10.0.0.0/8', '::/0', '10.0.0.0/26;cmd')) {
    Assert-Rejected { Get-ArtifactNetworkBoundary $cidr } "Reject unbounded or invalid CIDR $cidr"
}
$marker = 'FWF_ARTIFACT_test='
$message = $marker + '{"status":"succeeded","output":{"hostKey":"public-only"}}'
$response = @{ value = @(@{ code = 'ProvisioningState/succeeded'; level = 'Info'; message = $message }) }
$result = Read-ArtifactEnvelope ($response | ConvertTo-Json -Depth 8) $marker
Assert-Transfer ($result.hostKey -eq 'public-only') 'Read only the successful completion envelope'
foreach ($badMessage in @('truncated', "$message`n$message", "$message`n[stderr]failure", ($marker + '{"status":"failed"}'))) {
    $response.value[0].message = $badMessage
    Assert-Rejected { Read-ArtifactEnvelope ($response | ConvertTo-Json -Depth 8) $marker } 'Reject ambiguous or failed ARM result'
}
$response.value[0].message = $message
$response.value[0].code = 'ProvisioningState/failed'
Assert-Rejected { Read-ArtifactEnvelope ($response | ConvertTo-Json -Depth 8) $marker } 'Reject ARM failure even with successful script marker'

$subscription = '11111111-1111-1111-1111-111111111111'
$prefix = "/subscriptions/$subscription/resourceGroups/rg-test/providers"
$subnetId = "$prefix/Microsoft.Network/virtualNetworks/test/subnets/AzureBastionSubnet"
$scopeState = @{ scenario = 'success'; calls = [Collections.Generic.List[object]]::new() }
function Invoke-ArtifactCommand {
    param([string]$Command, [string[]]$Arguments)
    $scopeState.calls.Add(@{ command = $Command; arguments = $Arguments })
    if ($Command -eq 'terraform') {
        Assert-Transfer ($Arguments[1] -eq 'output' -and $Arguments.Count -eq 4) 'Only named nonsecret Terraform outputs are read'
        switch ($Arguments[3]) {
            'subscription_id' { if ($scopeState.scenario -eq 'subscription') { return '"22222222-2222-2222-2222-222222222222"' }; return "`"$subscription`"" }
            'resource_groups' { return '{"primary":"rg-test"}' }
            'jumpbox' { if ($scopeState.scenario -eq 'missing-name') { return '{"name":"vm-test"}' }; return '{"name":"vm-test","bastion":"bas-test"}' }
            'spoke_primary_subnets' { return (@{ AzureBastionSubnet = $subnetId } | ConvertTo-Json) }
            default { throw 'Forbidden Terraform output.' }
        }
    }
    Assert-Transfer ($Arguments -contains '--subscription' -and $Arguments -contains $subscription) 'Every ARM read has explicit subscription'
    if ($Arguments[0] -eq 'vm') {
        $identifier = if ($scopeState.scenario -eq 'wrong-vm') { 'other-vm' } else { "$prefix/Microsoft.Compute/virtualMachines/vm-test" }
        return (@{ id = $identifier; storageProfile = @{ osDisk = @{ osType = 'Windows' } } } | ConvertTo-Json -Depth 6)
    }
    if ($Arguments[1] -eq 'bastion') {
        $tier = if ($scopeState.scenario -eq 'basic') { 'Basic' } else { 'Standard' }
        $subnet = if ($scopeState.scenario -eq 'wrong-subnet') { 'other-subnet' } else { $subnetId }
        return (@{ id = "$prefix/Microsoft.Network/bastionHosts/bas-test"; sku = @{ name = $tier }; enableTunneling = ($scopeState.scenario -ne 'disabled'); ipConfigurations = @(@{ subnet = @{ id = $subnet } }) } | ConvertTo-Json -Depth 7)
    }
    return (@{ id = $subnetId; addressPrefix = '10.42.8.0/26' } | ConvertTo-Json)
}
$scope = Get-ArtifactTransferScope $subscription 'D:\unused'
Assert-Transfer ($scope.vm -eq 'vm-test' -and $scope.bastion -eq 'bas-test' -and $scope.cidr -eq '10.42.8.0/26') 'Resolve exact Terraform identities and live Bastion CIDR'
foreach ($scenario in @('subscription', 'missing-name', 'wrong-vm', 'basic', 'disabled', 'wrong-subnet')) {
    $scopeState.scenario = $scenario
    Assert-Rejected { Get-ArtifactTransferScope $subscription 'D:\unused' } "Reject unsafe scope: $scenario"
}
$options = Get-ArtifactClientOptions 'C:\fixture with spaces' 'fwf-test'
foreach ($required in @('StrictHostKeyChecking=yes', 'IdentityAgent=none', 'IdentitiesOnly=yes', 'BatchMode=yes', 'UpdateHostKeys=no', 'PasswordAuthentication=no', 'ClearAllForwardings=yes', 'ConnectTimeout=5', 'ConnectionAttempts=1')) {
    Assert-Transfer ($options -contains $required) "Enforce SSH $required"
}
Assert-Transfer ($options -contains 'UserKnownHostsFile="C:\fixture with spaces\known_hosts"') 'Pin only the private known_hosts file, preserving spaces'
Assert-Transfer ((ConvertTo-ArtifactSftpPath "C:\fixture with spaces\it's-safe.zip") -ceq '"C:/fixture with spaces/it''s-safe.zip"') 'SFTP quotes absolute local paths and normalizes backslashes'
foreach ($unsupported in @('C:\bad*\file.zip', 'C:\bad?\file.zip', 'C:\bad[\file.zip', 'C:\bad]\file.zip', 'C:\bad"\file.zip', "C:\bad`n\file.zip", "C:\bad`r\file.zip", 'relative.zip', 'C:\file.zip:stream')) {
    Assert-Rejected { ConvertTo-ArtifactSftpPath $unsupported } 'Reject paths that could change SFTP batch/glob interpretation'
}
$prepareText = (Get-ArtifactPrepareScript).ToString()
Assert-Transfer ($prepareText.Contains('Subsystem sftp C:/Windows/System32/OpenSSH/sftp-server.exe') -and $prepareText.Contains("@('ssh-keygen.exe', 'sftp-server.exe')")) 'Guest verifies the explicitly configured Windows SFTP subsystem executable'
Assert-Transfer (-not (Get-Command Wait-ArtifactTunnel).ScriptBlock.ToString().Contains('ssh.exe')) 'TCP readiness never authenticates an extra SSH session'
Assert-Transfer ((ConvertTo-ArtifactDiagnosticLine "`e[31mConnection closed`e[0m`t") -ceq 'Connection closed ') 'Diagnostics remove terminal escapes and control characters'
Assert-Transfer ((ConvertTo-ArtifactDiagnosticLine ('failure ' * 100)).Length -eq 240) 'Each diagnostic line is bounded'
foreach ($sensitive in @('Authorization: Bearer fake-value', 'token=fixture-value', 'password: fixture-value', '-----BEGIN OPENSSH PRIVATE KEY-----', 'ssh-ed25519 AAAATEST', 'https://example.invalid/?sig=fixture', ('x' * 80))) {
    Assert-Transfer ((ConvertTo-ArtifactDiagnosticLine $sensitive) -ceq '[redacted sensitive diagnostic line]') 'Sensitive diagnostic lines are redacted in full'
}
$scopeState.calls.Clear()
& $scriptPath -SubscriptionId $subscription -ToolManifestPath 'does-not-exist.json' -WhatIf 6>$null
Assert-Transfer ($scopeState.calls.Count -eq 0) 'WhatIf makes no native/cloud calls or manifest reads'
$savedTlsSetting = $env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION
try {
    $env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = '1'
    Assert-Rejected { & $scriptPath -SubscriptionId $subscription -ToolManifestPath 'does-not-exist.json' -Confirm:$false } 'Reject disabled Azure CLI TLS before any native command or manifest access'
    Assert-Transfer ($scopeState.calls.Count -eq 0) 'TLS rejection makes no native/cloud calls'
}
finally { $env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = $savedTlsSetting }
$orchestrator = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-Accelerator.ps1') -Raw
$sourceIndex = $orchestrator.IndexOf("Invoke-StageStep 'Workload.Transfer'")
$artifactIndex = $orchestrator.IndexOf("Invoke-StageStep 'Workload.Artifacts'")
$toolsIndex = $orchestrator.IndexOf("Invoke-StageStep 'Workload.Tools'")
Assert-Transfer ($sourceIndex -ge 0 -and $artifactIndex -gt $sourceIndex -and $toolsIndex -gt $artifactIndex) 'Artifact transport runs between source staging and tool initialization'
Assert-Transfer ($orchestrator -match "(?s)\`$hashInputs \+= @\('Invoke-Accelerator.ps1'.*?'Send-RunnerArtifacts.ps1'\) \| ForEach-Object") 'Transport script participates in accelerator fingerprint'
$null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-Accelerator.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-Transfer ($parseErrors.Count -eq 0) 'Integrated orchestrator parses'

$temporary = Join-Path ([IO.Path]::GetTempPath()) "fwf artifact tests-$([guid]::NewGuid().ToString('N'))"
$artifactFixture = Join-Path $temporary "client's files"
$null = New-Item -ItemType Directory -Path (Join-Path $artifactFixture 'runner-tool-cache')
try {
    $pins = @{ schemaVersion = 1; platform = 'windows/amd64'; artifactDirectory = 'runner-tool-cache' }
    foreach ($kind in @('azd', 'uv', 'python', 'extensionBundle')) {
        $name = switch ($kind) { 'azd' { 'azd-1.2.3.msi' }; 'uv' { 'uv-1.2.3.zip' }; 'python' { 'python-3.13.7-amd64.exe' }; 'extensionBundle' { 'foundry-extensions.zip' } }
        $path = Join-Path $artifactFixture "runner-tool-cache\$name"
        Set-Content -LiteralPath $path -Value "fixture-$kind" -Encoding ASCII
        $pins[$kind] = @{ fileName = $name; version = $(if ($kind -eq 'python') { '3.13.7' } else { '1.2.3' }); bytes = (Get-Item $path).Length; sha256 = (Get-FileHash $path).Hash }
    }
    $manifestPath = Join-Path $artifactFixture 'runner-tools.json'
    $pins | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
    $plan = @(Get-RunnerArtifactPlan $manifestPath)
    Assert-Transfer ($plan.Count -eq 4) 'Exactly the four verified artifacts are selected'
    foreach ($badName in @('../escape.zip', 'C:\escape.zip', 'uv-1.2.3.zip:stream', 'uv-1.2.3.zip;cmd')) {
        $pins.uv.fileName = $badName
        $pins | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
        Assert-Rejected { Get-RunnerArtifactPlan $manifestPath } "Reject unsafe filename $badName"
    }
    $pins.uv.fileName = 'uv-1.2.3.zip'
    $pins | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
    Add-Content -LiteralPath $plan[1].path -Value 'tampered'
    Assert-Rejected { Get-RunnerArtifactPlan $manifestPath } 'Reject changed artifact before transfer'

    Set-Content -LiteralPath $plan[1].path -Value 'fixture-uv' -Encoding ASCII
    $clientSmoke = New-ArtifactLocalDirectory
    try {
        Set-Content -LiteralPath (Join-Path $clientSmoke 'client_config') -Value '' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $clientSmoke 'known_hosts') -Value '' -Encoding ASCII
        & ssh-keygen.exe -q -t ed25519 -N '' -f (Join-Path $clientSmoke 'identity')
        Assert-Transfer ($LASTEXITCODE -eq 0) 'Installed Windows ssh-keygen accepts the ephemeral Ed25519 command'
        $clientOptions = Get-ArtifactClientOptions $clientSmoke 'fwf-local-config-test'
        $configuration = & ssh.exe @clientOptions -G 127.0.0.1 2>$null
        Assert-Transfer ($LASTEXITCODE -eq 0) 'Installed SSH accepts the entire client configuration without connecting'
        Assert-Transfer ([bool]($configuration -match '^stricthostkeychecking true$')) 'Installed SSH resolves strict host key checking'
        Assert-Transfer ([bool]($configuration -match '^identityagent none$')) 'Installed SSH will not use an authentication agent'
        $helpOutput = & sftp.exe -b (Join-Path $clientSmoke 'client_config') @clientOptions -P 22222 '-?' 2>&1
        Assert-Transfer ($LASTEXITCODE -ne 0 -and ($helpOutput -join "`n") -match 'usage: sftp' -and ($helpOutput -join "`n") -match '-b batchfile') 'Installed native SFTP parses the configured options and exits through help without connecting'
        $nativeErrors = [Collections.Generic.List[string]]::new()
        Assert-Rejected { & $nativeArtifactCommand 'sftp.exe' @('-?') -StandardError $nativeErrors } 'Native SFTP nonzero help exit is reported by the actual command wrapper without connecting'
        Assert-Transfer ($nativeErrors.Count -gt 0 -and $nativeErrors.Count -le 6 -and @($nativeErrors | Where-Object { $_.Length -gt 240 }).Count -eq 0) 'Actual native stderr capture is retained as a bounded diagnostic tail'
    }
    finally { Remove-Item -LiteralPath $clientSmoke -Recurse -Force }

    $guestRoot = Join-Path $temporary 'guest'
    $guestId = '1234567890abcdef1234567890abcdef'
    $incoming = Join-Path $guestRoot ".artifact-transfer\$guestId\incoming"
    $null = New-Item -ItemType Directory -Path $incoming -Force
    foreach ($file in $plan) { Copy-Item -LiteralPath $file.path -Destination (Join-Path $incoming $file.fileName) }
    $guestVerify = [scriptblock]::Create((Get-ArtifactVerifyScript).ToString().Replace('C:\ProgramData\FunWithFoundry', $guestRoot))
    $guestPayload = @{ id = $guestId; environment = 'test'; files = @($plan | Select-Object fileName, bytes, sha256); publish = $true }
    Add-Content -LiteralPath (Join-Path $incoming $plan[1].fileName) -Value 'bad upload'
    Assert-Rejected { & $guestVerify $guestPayload } 'Guest rejects corrupt upload'
    $artifactRoot = Join-Path $guestRoot 'test\tool-artifacts'
    Assert-Transfer (-not (Test-Path -LiteralPath $artifactRoot)) 'All uploaded hashes are checked before creating final files'
    Copy-Item -LiteralPath $plan[1].path -Destination (Join-Path $incoming $plan[1].fileName) -Force
    $published = & $guestVerify $guestPayload
    Assert-Transfer (@($published.verified).Count -eq 4) 'Actual guest body publishes all four verified artifacts'
    $guestPayload.publish = $false
    $inspection = & $guestVerify $guestPayload
    Assert-Transfer (@($inspection.verified).Count -eq 4) 'Actual guest body revalidates retained files on resume'
    $activeLock = Join-Path $guestRoot '.artifact-transfer\active'
    Set-Content -LiteralPath $activeLock -Value ('f' * 32)
    Assert-Rejected { & $guestVerify $guestPayload } 'Valid retained hashes never bypass unresolved cleanup from a previous transfer'
    Set-Content -LiteralPath $activeLock -Value $guestId
    Assert-Transfer (@((& $guestVerify $guestPayload).verified).Count -eq 4) 'The current owned transfer may verify its own artifacts'
    Remove-Item -LiteralPath $activeLock
    $conflicting = Join-Path $artifactRoot $plan[0].fileName
    Set-Content -LiteralPath $conflicting -Value 'preexisting conflicting file'
    Assert-Rejected { & $guestVerify $guestPayload } 'Guest refuses to overwrite a conflicting retained file'
    Assert-Transfer ((Get-Content -LiteralPath $conflicting -Raw).Trim() -eq 'preexisting conflicting file') 'Conflict is preserved for approved quarantine'

    $diagnosticJob = Join-Path $guestRoot ".artifact-transfer\$guestId"
    Set-Content -LiteralPath (Join-Path $diagnosticJob 'state.json') -Value (@{ id = $guestId } | ConvertTo-Json)
    Set-Content -LiteralPath (Join-Path $guestRoot '.artifact-transfer\active') -Value $guestId
    $guestDiagnostics = [scriptblock]::Create((Get-ArtifactDiagnosticsScript).ToString().Replace('C:\ProgramData\FunWithFoundry', $guestRoot))
    $logFixture = @(('old log line' * 1000), 'subsystem request for sftp failed', 'Connection closed', 'token=fixture-value', '-----BEGIN OPENSSH PRIVATE KEY-----', 'Permission denied', 'sftp-server.exe: failed')
    Set-Content -LiteralPath (Join-Path $diagnosticJob 'sshd.log') -Value $logFixture
    $diagnosticResult = & $guestDiagnostics @{ id = $guestId }
    Assert-Transfer ($diagnosticResult.recordType -ceq 'artifact-transfer-diagnostics' -and $diagnosticResult.source -ceq 'guest-sshd' -and $diagnosticResult.lines.Count -eq 6) 'Actual guest diagnostics return only a typed bounded log tail'
    Assert-Transfer (($diagnosticResult.lines -join ' ') -notmatch 'old log|fixture-value|PRIVATE KEY' -and $diagnosticResult.lines[-1] -ceq 'sftp-server.exe: failed') 'Guest diagnostics redact sensitive text before it crosses ARM'
    Set-Content -LiteralPath (Join-Path $guestRoot '.artifact-transfer\active') -Value ('f' * 32)
    Assert-Rejected { & $guestDiagnostics @{ id = $guestId } } 'Guest diagnostics refuse logs without matching transfer ownership'
    Assert-Rejected { & $guestDiagnostics @{ id = '../other' } } 'Guest diagnostics reject path traversal'

    $guestState = @{}
    function Get-LocalUser {
        param($Name, $ErrorAction)
        $description = if ($guestState.scenario -eq 'collision') { 'Existing unrelated account' } else { "FWF transfer $guestId" }
        [pscustomobject]@{ Name = $Name; Description = $description; SID = @{ Value = 'S-1-5-21-1-2-3-1001' } }
    }
    function Disable-LocalUser { param($Name) $guestState.disabled++ }
    function Remove-LocalUser { param($Name) $guestState.removed++ }
    function Get-CimInstance {
        param($ClassName, $Filter)
        if ($ClassName -eq 'Win32_Process') {
            [pscustomobject]@{ ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'; CommandLine = 'sshd.exe -f "C:\ProgramData\ssh\sshd_config"'; ProcessId = 999999 }
        }
        if ($ClassName -eq 'Win32_UserProfile' -and $guestState.scenario -eq 'loaded-profile') { [pscustomobject]@{ Loaded = $true } }
    }
    function Remove-CimInstance { throw 'Loaded profiles must never be force-unloaded or removed.' }
    function Get-NetFirewallRule { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name } }
    function Remove-NetFirewallRule {
        param([Parameter(ValueFromPipeline)]$InputObject)
        process { $guestState.rules.Add($InputObject.Name) }
    }
    function Get-ScheduledTask { param($TaskName, $ErrorAction) [pscustomobject]@{ TaskName = $TaskName } }
    function Stop-ScheduledTask { param($TaskName) $guestState.tasks.Add($TaskName) }
    function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) $guestState.unregistered.Add($TaskName) }
    function Get-Service { param($Name, $ErrorAction) @{ Status = 'Stopped' } }
    function Get-WindowsCapability { param([switch]$Online, $Name) @{ Name = $Name; State = $guestState.capability } }
    function Remove-WindowsCapability {
        param([switch]$Online, $Name)
        $guestState.capabilityCalls++
        if ($guestState.scenario -in @('capability-failure', 'scheduled-failure')) { throw 'Mock capability restoration failure.' }
        $guestState.capability = 'NotPresent'
        @{ RestartNeeded = $false }
    }
    $guestCleanup = [scriptblock]::Create((Get-ArtifactCleanupScript).ToString().Replace('C:\ProgramData\FunWithFoundry', $guestRoot))
    foreach ($scenario in @('existing-install', 'added-install', 'existing-rule', 'collision', 'loaded-profile', 'capability-failure', 'scheduled', 'scheduled-failure')) {
        $guestState.Clear()
        $guestState.scenario = $scenario
        $guestState.capability = 'Installed'
        $guestState.rules = [Collections.Generic.List[string]]::new()
        $guestState.tasks = [Collections.Generic.List[string]]::new()
        $guestState.unregistered = [Collections.Generic.List[string]]::new()
        $job = Join-Path $guestRoot ".artifact-transfer\$guestId"
        $null = New-Item -ItemType Directory -Path $job -Force
        Set-Content -LiteralPath (Join-Path $guestRoot '.artifact-transfer\active') -Value $guestId
        $installedHere = $scenario -in @('added-install', 'existing-rule', 'capability-failure', 'scheduled', 'scheduled-failure')
        @{ id = $guestId; user = 'fwf1234567890abcdef'; sshd = 'C:\Windows\System32\OpenSSH\sshd.exe'; installAttempted = $installedHere; defaultRuleExisted = ($scenario -eq 'existing-rule') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $job 'state.json')
        foreach ($key in @('authorized_keys', 'host_key', 'host_key.pub')) { Set-Content -LiteralPath (Join-Path $job $key) -Value 'fake guest test key' }
        $cleanupPayload = @{ id = $guestId; scheduled = ($scenario -like 'scheduled*') }
        if ($scenario -in @('collision', 'loaded-profile', 'capability-failure', 'scheduled-failure')) {
            $cleanupFailure = $null
            try { & $guestCleanup $cleanupPayload | Out-Null } catch { $cleanupFailure = $_.Exception.Message }
            Assert-Transfer ($null -ne $cleanupFailure) "Guest reports incomplete cleanup: $scenario"
            Assert-Transfer (Test-Path -LiteralPath (Join-Path $job 'state.json')) 'Unresolved cleanup retains owned recovery state'
            if ($scenario -eq 'loaded-profile') {
                Assert-Transfer ($cleanupFailure -match 'Loaded profile S-1-5-21-1-2-3-1001 requires an explicitly approved VM restart' -and -not $guestState.removed) 'Loaded profile requires explicit restart approval, names the SID and preserves the account'
            }
        }
        else {
            $cleaned = & $guestCleanup $cleanupPayload
            Assert-Transfer ($cleaned.cleaned -eq $true -and -not (Test-Path -LiteralPath $job)) 'Guest removes only the owned completed transfer directory'
        }
        Assert-Transfer (Test-Path -LiteralPath $conflicting) 'Guest cleanup retains published artifacts outside its temporary directory'
        Assert-Transfer (-not (Test-Path -LiteralPath (Join-Path $job 'host_key'))) 'Guest destroys temporary host credentials even when cleanup is incomplete'
        if ($cleanupPayload.scheduled) {
            Assert-Transfer ($guestState.tasks.Count -eq 1 -and $guestState.tasks[0] -eq "FWF-$guestId-sshd") 'Scheduled cleanup never calls Stop-ScheduledTask on itself'
            if ($scenario -eq 'scheduled') {
                Assert-Transfer ($guestState.unregistered.Count -eq 2 -and $guestState.unregistered[-1] -eq "FWF-$guestId-cleanup" -and $guestState.capability -eq 'NotPresent') 'Scheduled cleanup unregisters itself only after successful resource cleanup'
            }
            else { Assert-Transfer ($guestState.unregistered -notcontains "FWF-$guestId-cleanup") 'Failed scheduled cleanup retains its task and recovery state'
            }
        }
        else { Assert-Transfer ($guestState.tasks.Count -eq 2) 'Interactive cleanup stops only its two named tasks' }
        if ($scenario -eq 'collision') { Assert-Transfer (-not $guestState.disabled -and -not $guestState.removed) 'A colliding unrelated OS account is never disabled or removed' }
        if (-not $installedHere) { Assert-Transfer (-not $guestState.capabilityCalls) 'Existing OpenSSH installation is never removed' }
        if ($scenario -eq 'existing-rule') { Assert-Transfer ($guestState.rules -notcontains 'OpenSSH-Server-In-TCP') 'Preexisting default firewall rule is never removed' }
        if ($scenario -eq 'added-install') { Assert-Transfer ($guestState.capability -eq 'NotPresent' -and $guestState.rules -contains 'OpenSSH-Server-In-TCP') 'Remove only the newly added capability and generated default firewall rule' }
    }
    & {
        $prepareRoot = Join-Path $temporary 'registration'
        $null = New-Item -ItemType Directory -Path $prepareRoot
        $guestPrepare = [scriptblock]::Create((Get-ArtifactPrepareScript).ToString().Replace('C:\ProgramData\FunWithFoundry', $prepareRoot).Replace("'C:\ProgramData'", "'$temporary'"))
        function Get-LocalUser { param($Name, $ErrorAction) }
        function Set-Acl { param($LiteralPath, $AclObject) }
        function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) @{ UserId = $UserId } }
        function New-ScheduledTaskAction { param($Execute, $Argument) @{ Execute = $Execute; Argument = $Argument } }
        function New-ScheduledTaskTrigger { param([switch]$Once, $At) @{ At = $At } }
        function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable, $ExecutionTimeLimit) @{} }
        function Register-ScheduledTask {
            param($TaskName, $Action, $Principal, $Trigger, $Settings)
            $guestState.registration = @{ name = $TaskName; action = $Action; principal = $Principal }
            throw 'Stop after capturing registration; no real task, firewall, account, or capability changes.'
        }
        Assert-Rejected { & $guestPrepare @{ id = $guestId; publicKey = 'ssh-ed25519 AAAATEST fixture'; cidr = '10.42.8.0/26'; pathGuard = 'param($Path)'; cleanup = 'param($payload) $payload' } } 'Preparation stops at mocked cleanup registration'
        $cleanupPath = Join-Path $prepareRoot ".artifact-transfer\$guestId\cleanup.ps1"
        Assert-Transfer ($guestState.registration.name -eq "FWF-$guestId-cleanup" -and $guestState.registration.principal.UserId -eq 'SYSTEM') 'Preparation registers the owned SYSTEM cleanup task'
        Assert-Transfer ($guestState.registration.action.Argument -like "*-File `"$cleanupPath`"") 'Registered task invokes the generated cleanup file'
        $registeredPayload = & $cleanupPath
        Assert-Transfer ($registeredPayload.id -ceq $guestId -and $registeredPayload.scheduled -eq $true) 'Generated cleanup registration propagates scheduled=true and the exact transfer ID'
    }
    $transferState = @{}
    function Write-Warning {
        param([string]$Message, [string]$WarningAction)
        $record = $Message | ConvertFrom-Json
        Assert-Transfer ($record.recordType -ceq 'artifact-transfer-diagnostics' -and $record.transferId -ceq $transferState.id) 'Failure emits only the diagnostic record for this transfer'
        Assert-Transfer (-not $transferState.cleaned -and -not $transferState.stopped) 'Diagnostics are emitted before tunnel and guest cleanup'
        Assert-Transfer ($Message -notmatch 'fixture-value|PRIVATE KEY' -and $Message.Length -lt 4096) 'Emitted diagnostics are sanitized and bounded'
        $transferState.diagnosticRecord = $record
    }
    $realLocalDirectory = ${function:New-ArtifactLocalDirectory}
    function New-ArtifactLocalDirectory {
        $transferState.local = & $realLocalDirectory
        $acl = Get-Acl -LiteralPath $transferState.local
        Assert-Transfer $acl.AreAccessRulesProtected 'Credential directory disables inherited ACLs before creating keys'
        $transferState.local
    }
    function Invoke-ArtifactCommand {
        param([string]$Command, [string[]]$Arguments, [Collections.Generic.List[string]]$StandardError)
        if ($Command -eq 'ssh-keygen.exe') {
            $null = & $nativeArtifactCommand $Command $Arguments -StandardError $StandardError
            return
        }
        if ($Command -ne 'sftp.exe') { throw "Unexpected native command $Command" }
        $transferState.sessions++
        Assert-Transfer ($null -ne $StandardError) 'SFTP stderr is captured for failure diagnostics'
        $StandardError.Add('Connection closed')
        $StandardError.Add('token=fixture-value')
        Assert-Transfer ($Arguments[0] -ceq '-b' -and $Arguments -cnotcontains '-O' -and $Arguments -contains 'StrictHostKeyChecking=yes' -and $Arguments -contains 'ClearAllForwardings=yes') 'One native SFTP batch uses the pinned host and disables forwarding'
        Assert-Transfer ($Arguments[-1] -ceq "fwf$($transferState.id.Substring(0, 16))@127.0.0.1") 'SFTP authenticates only the owned user over loopback'
        $batchCommands = @(Get-Content -LiteralPath $Arguments[1])
        $canary = Join-Path $transferState.local 'canary.bin'
        $readback = Join-Path $transferState.local 'canary-readback.bin'
        Assert-Transfer ($batchCommands.Count -eq 9 -and $batchCommands[0] -ceq 'pwd' -and $batchCommands[1] -ceq "cd /C:/ProgramData/FunWithFoundry/.artifact-transfer/$($transferState.id)/incoming") 'Batch begins with pwd and the exact private incoming directory'
        Assert-Transfer ($batchCommands[2] -ceq ('put ' + (ConvertTo-ArtifactSftpPath $canary) + ' canary.bin') -and $batchCommands[3] -ceq ('get canary.bin ' + (ConvertTo-ArtifactSftpPath $readback)) -and $batchCommands[4] -ceq 'rm canary.bin') 'Canary put/get/rm precedes every artifact in the same abort-on-error batch'
        foreach ($index in 0..3) {
            Assert-Transfer ($batchCommands[$index + 5] -ceq ('put ' + (ConvertTo-ArtifactSftpPath $plan[$index].path) + ' ' + $plan[$index].fileName)) 'Only quoted allowlisted absolute files and destination basenames enter SFTP'
        }
        if ($transferState.scenario -eq 'auth') { throw 'Mock host authentication failure.' }
        if ($transferState.scenario -in @('copy', 'diagnostics-failure', 'diagnostics-type')) { throw 'Mock SFTP batch failure.' }
        if ($transferState.scenario -ne 'canary-missing') { Copy-Item -LiteralPath $canary -Destination $readback }
        if ($transferState.scenario -eq 'canary-size') { Add-Content -LiteralPath $readback -Value 'bad' }
        if ($transferState.scenario -eq 'canary-hash') { [IO.File]::WriteAllBytes($readback, [byte[]]::new((Get-Item -LiteralPath $canary).Length)) }
    }
    function Invoke-ArtifactRemote {
        param($Scope, [scriptblock]$Operation, $Payload, [string]$LocalDirectory)
        if ($Operation.ToString() -eq (Get-ArtifactCleanupScript).ToString()) {
            $transferState.cleaned++
            Assert-Transfer ($Payload.id -eq $transferState.id) 'Cleanup targets only this transfer ID'
            if ($transferState.scenario -eq 'cleanup') { throw 'Mock cleanup failure.' }
            if ($transferState.scenario -eq 'cleanup-loaded') { throw 'ACTION: Loaded profile S-1-5-21-1-2-3-1001 requires an explicitly approved VM restart before retrying cleanup.' }
            return @{ cleaned = $true }
        }
        if ($Operation.ToString() -eq (Get-ArtifactDiagnosticsScript).ToString()) {
            $transferState.diagnostics++
            Assert-Transfer ($Payload.id -ceq $transferState.id -and -not $transferState.cleaned) 'Read only the owned guest diagnostics before cleanup'
            if ($transferState.scenario -eq 'diagnostics-failure') { throw 'Mock diagnostic read failure.' }
            $recordType = if ($transferState.scenario -eq 'diagnostics-type') { 'unexpected-token-record' } else { 'artifact-transfer-diagnostics' }
            return @{ recordType = $recordType; source = 'guest-sshd'; lines = @('sftp subsystem failed', 'token=fixture-value'); unrelatedSecret = 'fixture-value' }
        }
        if ($Operation.ToString() -eq (Get-ArtifactPrepareScript).ToString()) {
            $transferState.prepared++
            $transferState.id = $Payload.id
            $acl = Get-Acl -LiteralPath (Join-Path $LocalDirectory 'identity')
            $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $untrusted = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @($owner, 'S-1-5-18', 'S-1-5-32-544')
            })
            Assert-Transfer ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $owner -and $untrusted.Count -eq 0) 'Private key grants access only to its owner and trusted Windows administrators'
            Assert-Transfer ($Payload.publicKey -like 'ssh-ed25519 *' -and $Payload.PSObject.Properties.Name -notcontains 'privateKey') 'ARM receives only public user key'
            if ($transferState.scenario -eq 'prepare') { throw 'Mock truncated preparation envelope.' }
            $key = if ($transferState.scenario -eq 'hostkey') { 'ssh-rsa NOT-ACCEPTED' } else { 'ssh-ed25519 AAAAHOST fixture' }
            return @{ user = 'fwf' + $Payload.id.Substring(0, 16); port = 22222; incoming = "C:\ProgramData\FunWithFoundry\.artifact-transfer\$($Payload.id)\incoming"; hostKey = $key }
        }
        if ($Payload.publish) {
            $transferState.verified++
            if ($transferState.scenario -eq 'hash') { throw 'Mock uploaded hash mismatch.' }
            if ($transferState.scenario -eq 'incomplete') { return @{ verified = @('one-file') } }
        }
        $names = if ($Payload.publish -or $transferState.scenario -eq 'already') { @($Payload.files.fileName) } else { @() }
        @{ verified = $names; root = 'C:\ProgramData\FunWithFoundry\test\tool-artifacts' }
    }
    function Start-ArtifactTunnel {
        param($Scope, [int]$RemotePort, [int]$LocalPort)
        $transferState.started++
        $known = Get-Content -LiteralPath (Join-Path $transferState.local 'known_hosts') -Raw
        Assert-Transfer ($known.Trim() -eq "fwf-$($transferState.id) ssh-ed25519 AAAAHOST") 'Host pin is precisely the ARM-returned public key'
        if ($transferState.scenario -eq 'tunnel') { throw 'Mock tunnel start failure.' }
        @{ mocked = $true }
    }
    function Stop-ArtifactTunnel { param($Tunnel) $transferState.stopped++ }
    function Wait-ArtifactTunnel {
        param($Tunnel, [int]$Port)
        if ($transferState.scenario -eq 'readiness') { throw 'Mock TCP readiness failure.' }
    }
    foreach ($scenario in @('success', 'already', 'prepare', 'hostkey', 'tunnel', 'readiness', 'auth', 'copy', 'diagnostics-failure', 'diagnostics-type', 'canary-missing', 'canary-size', 'canary-hash', 'hash', 'incomplete', 'cleanup', 'cleanup-loaded')) {
        $transferState.Clear()
        $transferState.scenario = $scenario
        $failure = $null
        $result = $null
        try { $result = Invoke-RunnerArtifactTransfer $scope $plan 'test' } catch { $failure = $_ }
        Assert-Transfer (($null -ne $failure) -eq ($scenario -notin @('success', 'already'))) "Expected lifecycle outcome: $scenario ($failure)"
        Assert-Transfer (-not (Test-Path -LiteralPath $transferState.local)) "Always delete temporary credentials: $scenario"
        if ($scenario -eq 'already') {
            Assert-Transfer (-not $transferState.prepared -and -not $transferState.started -and -not $transferState.sessions) 'Verified rerun creates no SSH account/key/tunnel'
        }
        else {
            Assert-Transfer ($transferState.cleaned -eq 1) "Attempt remote cleanup even after failure: $scenario"
            if ($scenario -in @('success', 'readiness', 'auth', 'copy', 'diagnostics-failure', 'diagnostics-type', 'canary-missing', 'canary-size', 'canary-hash', 'hash', 'incomplete', 'cleanup', 'cleanup-loaded')) {
                Assert-Transfer ($transferState.stopped -eq 1) "Stop owned tunnel on exit: $scenario"
            }
        }
        Assert-Transfer ($transferState.sessions -le 1) 'No second authenticated session is attempted'
        if ($scenario -notin @('success', 'already', 'cleanup', 'cleanup-loaded')) { Assert-Transfer ($transferState.diagnostics -eq 1 -and $null -ne $transferState.diagnosticRecord) 'Transport/verification failure collects diagnostics even if diagnostic retrieval fails' }
        if ($scenario -in @('readiness', 'auth', 'copy', 'diagnostics-failure', 'diagnostics-type', 'canary-missing', 'canary-size', 'canary-hash')) { Assert-Transfer (-not $transferState.verified) 'Failed transport or canary prevents publication' }
        if ($scenario -eq 'diagnostics-type') { Assert-Transfer (($transferState.diagnosticRecord.guestSshd -join ' ') -notmatch 'subsystem failed') 'Unexpected record types are never emitted as diagnostics' }
        if ($scenario -eq 'cleanup-loaded') { Assert-Transfer ($failure.Exception.Message -match 'S-1-5-21-1-2-3-1001.*explicitly approved VM restart') 'Cleanup preserves actionable SID/restart guidance for the caller' }
        if ($scenario -eq 'success') { Assert-Transfer ($result.status -eq 'verified' -and $transferState.sessions -eq 1 -and $transferState.verified -eq 1) 'Success requires one batch session, a matching canary and final ARM verification' }
    }
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
Write-Host "Artifact transfer guards passed ($script:checks checks). No cloud calls."
