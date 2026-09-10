<#
.SYNOPSIS
    Transfer verified tool artifacts through an approved private Bastion SSH tunnel.
.DESCRIPTION
    Windows PowerShell 7.3+ and existing az/Bastion extension, Terraform, sftp and
    ssh-keygen are required on the workstation. WhatIf performs no reads or writes.
    Named nonsecret Terraform outputs bind the subscription, VM, Bastion and subnet.
    One ShouldProcess approval covers the complete temporary privileged lifecycle
    and mandatory cleanup, including installing/removing OpenSSH Server if absent.
    Existing SSH services, configuration, host keys and authorized keys are not used
    or changed. A separate SYSTEM task runs a private-subnet-only listener using an
    expiring local administrator, isolated keys/config and a one-hour cleanup task.
    ARM returns the host public key and bounded sanitized failure diagnostics.
    A private known_hosts file pins that key;
    no user SSH config, agent, SAS, token cache transfer or public exception is used.
    All four source files remain read-locked and are verified before publication.
    Verified artifacts are retained. Conflicting retained files require separately
    approved quarantine. Unconfirmed cleanup fails the run and retains guest state.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][string]$ToolManifestPath,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,47}$')][string]$EnvironmentName = 'funwithfoundry-dev',
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform')
)

$ErrorActionPreference = 'Stop'

function Assert-ArtifactPlainPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse points are not permitted in artifact paths: $Path" }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}

function Get-RunnerArtifactPlan {
    param([string]$ManifestPath)
    Assert-ArtifactPlainPath $ManifestPath
    $pins = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($pins.schemaVersion -ne 1 -or $pins.platform -cne 'windows/amd64' -or $pins.artifactDirectory -cne 'runner-tool-cache') {
        throw 'Expected a schemaVersion 1 windows/amd64 manifest with adjacent runner-tool-cache.'
    }
    $cache = Join-Path (Split-Path ([IO.Path]::GetFullPath($ManifestPath)) -Parent) 'runner-tool-cache'
    foreach ($kind in @('azd', 'uv', 'python', 'extensionBundle')) {
        $pin = $pins.$kind
        $expected = switch ($kind) {
            'azd' { "azd-$($pin.version).msi" }
            'uv' { "uv-$($pin.version).zip" }
            'python' { "python-$($pin.version)-amd64.exe" }
            'extensionBundle' { 'foundry-extensions.zip' }
        }
        if (($kind -ne 'extensionBundle' -and $pin.version -notmatch '^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$') -or
            $pin.fileName -cne $expected -or $pin.fileName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+$' -or
            $pin.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$pin.bytes -notmatch '^[1-9]\d*$') {
            throw "Invalid artifact pin: $kind"
        }
        $path = Join-Path $cache $pin.fileName
        Assert-ArtifactPlainPath $path
        if ((Get-Item -LiteralPath $path).Length -ne [long]$pin.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $pin.sha256) {
            throw "Artifact hash/size mismatch: $($pin.fileName)"
        }
        [pscustomobject]@{ fileName = $pin.fileName; bytes = [long]$pin.bytes; sha256 = $pin.sha256.ToLowerInvariant(); path = $path }
    }
}

function Invoke-ArtifactCommand {
    param([string]$Command, [string[]]$Arguments, [Collections.Generic.List[string]]$StandardError)
    $global:LASTEXITCODE = 0
    $result = $null
    if ($null -ne $StandardError) {
        $PSNativeCommandUseErrorActionPreference = $false
        & $Command @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) {
                $StandardError.Add((ConvertTo-ArtifactDiagnosticLine $_.ToString()))
                if ($StandardError.Count -gt 6) { $StandardError.RemoveAt(0) }
            }
        }
    }
    else { $result = & $Command @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
    $result
}

function ConvertTo-ArtifactDiagnosticLine {
    param([string]$Line)
    $text = [regex]::Replace($Line, '\x1b\[[0-?]*[ -/]*[@-~]', '')
    $text = [regex]::Replace($text, '[\x00-\x1f\x7f-\x9f]', ' ')
    if ($text -match '(?i)token|password|passwd|secret|authorization|bearer|credential|private.?key|-----BEGIN|ssh-(?:ed25519|rsa)\s|[?&](?:sig|sv|se|sp)=|[a-z0-9+/_=-]{40,}') {
        return '[redacted sensitive diagnostic line]'
    }
    $text.Substring(0, [math]::Min(240, $text.Length))
}

function Get-ArtifactDiagnosticsScript {
    {
        param($payload)
        $ErrorActionPreference = 'Stop'
        if ($payload.id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid diagnostic transfer ID.' }
        $job = "C:\ProgramData\FunWithFoundry\.artifact-transfer\$($payload.id)"
        $record = @{ recordType = 'artifact-transfer-diagnostics'; source = 'guest-sshd'; lines = @('Owned sshd log unavailable.') }
        if (-not (Test-Path -LiteralPath $job)) { return $record }
        Assert-ArtifactPlainPath $job
        $statePath = Join-Path $job 'state.json'
        $lock = 'C:\ProgramData\FunWithFoundry\.artifact-transfer\active'
        foreach ($path in @($statePath, $lock)) { Assert-ArtifactPlainPath $path }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.id -cne $payload.id -or (Get-Content -LiteralPath $lock -Raw).Trim() -cne $payload.id) { throw 'Diagnostic ownership mismatch.' }
        $log = Join-Path $job 'sshd.log'
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return $record }
        Assert-ArtifactPlainPath $log
        $stream = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $offset = [math]::Max(0, $stream.Length - 8192)
            $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] 8192
            $count = $stream.Read($buffer, 0, $buffer.Length)
        }
        finally { $stream.Dispose() }
        $lines = [Text.Encoding]::UTF8.GetString($buffer, 0, $count) -split '\r?\n'
        if ($offset -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
        $record.lines = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 6 | ForEach-Object { ConvertTo-ArtifactDiagnosticLine $_ })
        $record
    }
}

function Get-ArtifactTransferScope {
    param([guid]$Subscription, [string]$Directory)
    $outputs = @{}
    foreach ($name in @('subscription_id', 'resource_groups', 'jumpbox', 'spoke_primary_subnets')) {
        $outputs[$name] = Invoke-ArtifactCommand 'terraform' @("-chdir=$Directory", 'output', '-json', $name) | ConvertFrom-Json
    }
    if ($Subscription -eq [guid]::Empty -or [string]$outputs.subscription_id -ne [string]$Subscription) { throw 'Terraform subscription mismatch.' }
    $group = [string]$outputs.resource_groups.primary
    $vm = [string]$outputs.jumpbox.name
    $bastion = [string]$outputs.jumpbox.bastion
    foreach ($name in @($group, $vm, $bastion)) {
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,89}$') { throw 'Missing or invalid Terraform jumpbox/Bastion identity.' }
    }
    $prefix = "/subscriptions/$Subscription/resourceGroups/$group/providers"
    $vmId = "$prefix/Microsoft.Compute/virtualMachines/$vm"
    $bastionId = "$prefix/Microsoft.Network/bastionHosts/$bastion"
    $subnetId = [string]$outputs.spoke_primary_subnets.AzureBastionSubnet
    if ($subnetId -notmatch "^/subscriptions/$Subscription/resourceGroups/[a-zA-Z0-9_.-]+/providers/Microsoft.Network/virtualNetworks/[a-zA-Z0-9_.-]+/subnets/AzureBastionSubnet$") {
        throw 'Missing or cross-subscription Bastion subnet output.'
    }
    $machine = Invoke-ArtifactCommand 'az' @('vm', 'show', '--subscription', [string]$Subscription, '--ids', $vmId, '-o', 'json') | ConvertFrom-Json
    if ($machine.id -ne $vmId -or $machine.storageProfile.osDisk.osType -ne 'Windows') { throw 'Expected the exact Windows jumpbox from Terraform.' }
    $hostInfo = Invoke-ArtifactCommand 'az' @('network', 'bastion', 'show', '--subscription', [string]$Subscription,
        '--resource-group', $group, '--name', $bastion, '-o', 'json') | ConvertFrom-Json
    if ($hostInfo.id -ne $bastionId -or $hostInfo.sku.name -notin @('Standard', 'Premium') -or
        $hostInfo.enableTunneling -ne $true -or @($hostInfo.ipConfigurations).Count -ne 1 -or
        $hostInfo.ipConfigurations[0].subnet.id -ne $subnetId) { throw 'Bastion identity, SKU, native tunneling or subnet does not match Terraform.' }
    $subnet = Invoke-ArtifactCommand 'az' @('network', 'vnet', 'subnet', 'show', '--subscription', [string]$Subscription,
        '--ids', $subnetId, '-o', 'json') | ConvertFrom-Json
    $cidrs = @($subnet.addressPrefix) + @($subnet.addressPrefixes) | Where-Object { $_ } | Select-Object -Unique
    if ($subnet.id -ne $subnetId -or @($cidrs).Count -ne 1) { throw 'Expected one unambiguous Bastion IPv4 subnet.' }
    $cidr = [string]@($cidrs)[0]
    $null = Get-ArtifactNetworkBoundary $cidr
    [pscustomobject]@{ subscription = [string]$Subscription; group = $group; vm = $vm; vmId = $vmId
        bastion = $bastion; bastionId = $bastionId; cidr = $cidr }
}

function Get-ArtifactNetworkBoundary {
    param([string]$Cidr)
    if ($Cidr -notmatch '^((?:\d{1,3}\.){3}\d{1,3})/(\d{1,2})$') { throw 'Bastion CIDR must be IPv4.' }
    $address = [Net.IPAddress]::Parse($Matches[1]).GetAddressBytes()
    $prefixLength = [int]$Matches[2]
    if ($prefixLength -lt 16 -or $prefixLength -gt 29 -or -not ($address[0] -eq 10 -or
        ($address[0] -eq 172 -and $address[1] -ge 16 -and $address[1] -le 31) -or ($address[0] -eq 192 -and $address[1] -eq 168))) {
        throw 'Bastion CIDR must be a private, bounded /16 through /29 subnet.'
    }
    $first = [uint64]$address[0] * 16777216 + [uint64]$address[1] * 65536 + [uint64]$address[2] * 256 + $address[3]
    $size = [uint64][math]::Pow(2, 32 - $prefixLength)
    if ($first % $size) { throw 'Bastion CIDR is not a canonical network address.' }
    [pscustomobject]@{ first = $first; last = $first + $size - 1 }
}

function Read-ArtifactEnvelope {
    param([string]$Json, [string]$Marker)
    $response = $Json | ConvertFrom-Json
    if (-not $response.value -or @($response.value | Where-Object { $_.code -notmatch '/succeeded$' -or $_.level -eq 'Error' }).Count) {
        throw 'ARM Run Command failed or is incomplete.'
    }
    if (@($response.value | Where-Object { $_.code -match '/StdErr/' -and -not [string]::IsNullOrWhiteSpace($_.message) }).Count) { throw 'ARM Run Command reported stderr.' }
    $text = $response.value.message -join "`n"
    if ($text -match '(?s)\[stderr\](.*)$' -and -not [string]::IsNullOrWhiteSpace($Matches[1])) { throw 'ARM Run Command reported stderr.' }
    $records = [regex]::Matches($text, '(?m)^' + [regex]::Escape($Marker) + '(\{[^\r\n]+\})\r?$')
    if ($records.Count -ne 1) { throw 'ARM completion envelope missing, duplicated or truncated; outcome unknown.' }
    $record = $records[0].Groups[1].Value | ConvertFrom-Json
    if ($record.status -ne 'succeeded') { throw "Runner transfer failed: $($record.reason)" }
    $record.output
}

function Invoke-ArtifactRemote {
    param($Scope, [scriptblock]$Operation, $Payload, [string]$LocalDirectory)
    $marker = 'FWF_ARTIFACT_' + [guid]::NewGuid().ToString('N') + '='
    $scriptText = ${function:Assert-ArtifactPlainPath}.ToString()
    $networkText = ${function:Get-ArtifactNetworkBoundary}.ToString()
    $diagnosticText = ${function:ConvertTo-ArtifactDiagnosticLine}.ToString()
    $body = "function Assert-ArtifactPlainPath { $scriptText }`nfunction Get-ArtifactNetworkBoundary { $networkText }`nfunction ConvertTo-ArtifactDiagnosticLine { $diagnosticText }`n& { $Operation } `$payload"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
    $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 12 -Compress)))
    $wrapper = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$global:LASTEXITCODE = 0
`$record = @{ status = 'failed'; reason = 'runner_operation_failed' }
try {
    `$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$data')) | ConvertFrom-Json
    `$result = & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded'))))
    if (`$LASTEXITCODE -ne 0) { throw 'Native command failed.' }
    `$record = @{ status = 'succeeded'; output = `$result }
} catch {
    if (`$_.Exception.Message -like 'ACTION:*') { `$record.reason = `$_.Exception.Message }
    else { `$record.reason = 'runner_operation_failed [' + `$_.Exception.GetType().Name + '; ' + `$_.FullyQualifiedErrorId + '; line ' + `$_.InvocationInfo.ScriptLineNumber + ']' }
} finally { Write-Output ('$marker' + (`$record | ConvertTo-Json -Depth 12 -Compress)) }
"@
    $path = Join-Path $LocalDirectory ('arm-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Set-Content -LiteralPath $path -Value $wrapper -Encoding UTF8
        $raw = Invoke-ArtifactCommand 'az' @('vm', 'run-command', 'invoke', '--subscription', $Scope.subscription,
            '--resource-group', $Scope.group, '--name', $Scope.vm, '--command-id', 'RunPowerShellScript', '--scripts', "@$path", '-o', 'json')
        Read-ArtifactEnvelope ($raw -join "`n") $marker
    }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
}

function Get-ArtifactCleanupScript {
    {
        param($payload)
        $ErrorActionPreference = 'Stop'
        $job = "C:\ProgramData\FunWithFoundry\.artifact-transfer\$($payload.id)"
        $lock = 'C:\ProgramData\FunWithFoundry\.artifact-transfer\active'
        if ($payload.id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid transfer ID.' }
        if (-not (Test-Path -LiteralPath $job)) {
            if ((Test-Path -LiteralPath $lock) -and (Get-Content -LiteralPath $lock -Raw).Trim() -ceq $payload.id) {
                Assert-ArtifactPlainPath $lock
                Remove-Item -LiteralPath $lock -Force
            }
            return @{ cleaned = $true }
        }
        Assert-ArtifactPlainPath $job
        $statePath = Join-Path $job 'state.json'
        if (-not (Test-Path -LiteralPath $statePath)) { throw 'ACTION: Transfer state missing; inspect the owned transfer directory before cleanup.' }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.id -cne $payload.id -or (Get-Content -LiteralPath $lock -Raw).Trim() -cne $payload.id) { throw 'ACTION: Transfer ownership changed; cleanup refused.' }
        $failures = [Collections.Generic.List[string]]::new()
        $loadedSid = $null
        foreach ($step in @('account', 'keys', 'process', 'tasks', 'firewall', 'user', 'capability')) {
            try {
                switch ($step) {
                    'account' {
                        $user = Get-LocalUser -Name $state.user -ErrorAction SilentlyContinue
                        if ($user) {
                            if ($user.Description -cne "FWF transfer $($state.id)") { throw 'Temporary account ownership changed.' }
                            Disable-LocalUser -Name $state.user
                        }
                    }
                    'firewall' {
                        Get-NetFirewallRule -Name "FWF-$($state.id)-allow" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
                        if ($state.installAttempted -and -not $state.defaultRuleExisted) {
                            Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
                        }
                        if ('process' -in $failures -or 'tasks' -in $failures) { throw 'Listener shutdown unconfirmed; retain non-Bastion block.' }
                        Get-NetFirewallRule -Name "FWF-$($state.id)-block" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
                    }
                    'keys' {
                        foreach ($name in @('authorized_keys', 'host_key', 'host_key.pub')) {
                            $path = Join-Path $job $name
                            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                        }
                    }
                    'process' {
                        $processes = Get-CimInstance Win32_Process -Filter "Name = 'sshd.exe'"
                        foreach ($process in $processes) {
                            if ($process.ExecutablePath -eq $state.sshd -and $process.CommandLine -and $process.CommandLine.Contains("-f `"$job\sshd_config`"")) {
                                & "$env:SystemRoot\System32\taskkill.exe" /PID $process.ProcessId /T /F *> $null
                                if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) { throw 'Owned sshd process did not stop.' }
                                $global:LASTEXITCODE = 0
                            }
                        }
                    }
                    'tasks' {
                        foreach ($name in @("FWF-$($state.id)-sshd", "FWF-$($state.id)-cleanup")) {
                            if ($payload.scheduled -and $name -eq "FWF-$($state.id)-cleanup") { continue }
                            if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
                                Stop-ScheduledTask -TaskName $name
                                Unregister-ScheduledTask -TaskName $name -Confirm:$false
                            }
                        }
                    }
                    'user' {
                        $user = Get-LocalUser -Name $state.user -ErrorAction SilentlyContinue
                        if ($user) {
                            if ($user.Description -cne "FWF transfer $($state.id)") { throw 'Temporary account ownership changed.' }
                            $profile = Get-CimInstance Win32_UserProfile -Filter "SID = '$($user.SID.Value)'"
                            if ($profile.Loaded) { $loadedSid = $user.SID.Value; throw 'Owned profile remains loaded.' }
                            if ($profile) { $profile | Remove-CimInstance }
                            Remove-LocalUser -Name $state.user
                        }
                    }
                    'capability' {
                        if ($state.installAttempted) {
                            if ((Get-Service sshd -ErrorAction SilentlyContinue).Status -eq 'Running') { throw 'Default SSH service started externally; capability removal refused.' }
                            $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
                            if ($capability.State -eq 'Installed') {
                                $removed = Remove-WindowsCapability -Online -Name $capability.Name
                                if ($removed.RestartNeeded) { throw 'Capability removal requires restart.' }
                            }
                            if ((Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0').State -ne 'NotPresent') { throw 'OpenSSH capability restoration unconfirmed.' }
                            Get-NetFirewallRule -Name "FWF-$($state.id)-install-block" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
                        }
                    }
                }
            }
            catch { $failures.Add($step) }
        }
        if ($failures.Count) {
            $guidance = if ($loadedSid) { " Loaded profile $loadedSid requires an explicitly approved VM restart before retrying cleanup; do not force-unload it or widen permissions." } else { '' }
            throw "ACTION: Cleanup incomplete ($($failures -join ',')). Reconcile transfer $($state.id) through ARM; do not delete its state or lock.$guidance"
        }
        if ($payload.scheduled) { Unregister-ScheduledTask -TaskName "FWF-$($state.id)-cleanup" -Confirm:$false }
        Remove-Item -LiteralPath $job -Recurse -Force
        Remove-Item -LiteralPath $lock -Force
        @{ cleaned = $true }
    }
}

function Get-ArtifactPrepareScript {
    {
        param($payload)
        if ($payload.id -notmatch '^[a-f0-9]{32}$' -or $payload.publicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: .*)?$') { throw 'Invalid public transfer identity.' }
        $boundary = Get-ArtifactNetworkBoundary $payload.cidr
        $base = 'C:\ProgramData\FunWithFoundry\.artifact-transfer'
        $job = Join-Path $base $payload.id
        $userName = 'fwf' + $payload.id.Substring(0, 16)
        if (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue) { throw 'ACTION: Temporary username collision; existing account was not changed.' }
        $expires = [datetime]::UtcNow.AddHours(1)
        $sshd = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
        foreach ($path in @('C:\ProgramData', 'C:\ProgramData\FunWithFoundry', $base)) {
            if (Test-Path -LiteralPath $path) { Assert-ArtifactPlainPath $path }
            else { $null = New-Item -ItemType Directory -Path $path }
        }
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
        Set-Acl -LiteralPath $base -AclObject $acl
        $lock = Join-Path $base 'active'
        try { $stream = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        catch { throw 'ACTION: Another transfer or unresolved cleanup owns the runner lock; reconcile it before retrying.' }
        try { $bytes = [Text.Encoding]::ASCII.GetBytes($payload.id); $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
        $null = New-Item -ItemType Directory -Path $job
        $state = @{ id = $payload.id; user = $userName; sshd = $sshd; installAttempted = $false }
        $statePath = Join-Path $job 'state.json'
        $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding ASCII
        $cleanupPath = Join-Path $job 'cleanup.ps1'
        $cleanupText = "function Assert-ArtifactPlainPath { $($payload.pathGuard) }`n& { $($payload.cleanup) } ([pscustomobject]@{ id = '$($payload.id)'; scheduled = `$true })"
        Set-Content -LiteralPath $cleanupPath -Value $cleanupText -Encoding UTF8
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $cleanupAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -File `"$cleanupPath`""
        $null = Register-ScheduledTask -TaskName "FWF-$($payload.id)-cleanup" -Action $cleanupAction -Principal $principal -Trigger (New-ScheduledTaskTrigger -Once -At $expires.ToLocalTime()) -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20))
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
        if ($profiles.Count -ne 3 -or @($profiles | Where-Object { $_.Enabled -ne $true -or $_.AllowLocalFirewallRules -eq $false }).Count) { throw 'ACTION: Active Windows Firewall policy cannot enforce temporary scoped rules.' }
        if (-not (Test-Path -LiteralPath $sshd)) {
            if ((Get-Service sshd -ErrorAction SilentlyContinue) -or (Test-Path 'C:\ProgramData\ssh') -or
                (Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0').State -ne 'NotPresent') {
                throw 'ACTION: Nonstandard or partial OpenSSH installation; repair separately without modifying its configuration.'
            }
            if (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue) { throw 'ACTION: Another listener owns port 22; automatic OpenSSH installation refused.' }
            $state.defaultRuleExisted = [bool](Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)
            $state.installAttempted = $true
            $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding ASCII
            $null = New-NetFirewallRule -Name "FWF-$($payload.id)-install-block" -DisplayName "FWF $($payload.id) install guard" -Direction Inbound -Action Block -Protocol TCP -LocalPort 22 -RemoteAddress Any -Profile Any
            $guard = Get-NetFirewallRule -Name "FWF-$($payload.id)-install-block" -PolicyStore ActiveStore
            if ($guard.Enabled -ne $true -or $guard.Action -ne 'Block') { throw 'ACTION: OpenSSH installation firewall guard is not effective.' }
            try { $installed = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' }
            catch { throw 'ACTION: Microsoft OpenSSH Server capability installation failed. Check approved Windows Update servicing and reboot state; no egress exceptions were added.' }
            if (-not $state.defaultRuleExisted) { Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
            if ($installed.RestartNeeded -or -not (Test-Path -LiteralPath $sshd)) { throw 'ACTION: OpenSSH Server installation requires repair/restart; no listener opened.' }
        }
        foreach ($executable in @('ssh-keygen.exe', 'sftp-server.exe')) {
            if (-not (Test-Path -LiteralPath "C:\Windows\System32\OpenSSH\$executable" -PathType Leaf)) { throw "ACTION: Windows OpenSSH $executable is missing. Repair the Microsoft OpenSSH capabilities separately; no third-party downloads attempted." }
        }
        $secretBytes = New-Object byte[] 48
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($secretBytes) } finally { $random.Dispose() }
        $password = ConvertTo-SecureString ('Aa1!' + [Convert]::ToBase64String($secretBytes)) -AsPlainText -Force
        [Array]::Clear($secretBytes, 0, $secretBytes.Length)
        try { $user = New-LocalUser -Name $userName -Password $password -AccountExpires $expires -UserMayNotChangePassword -Description "FWF transfer $($payload.id)" }
        finally { $password.Dispose() }
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $user
        $authorized = Join-Path $job 'authorized_keys'
        Set-Content -LiteralPath $authorized -Value $payload.publicKey -Encoding ASCII
        $hostKey = Join-Path $job 'host_key'
        & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -q -t ed25519 -N '""' -f $hostKey *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Host key generation failed.' }
        $socket = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $socket.Start()
        try { $port = $socket.LocalEndpoint.Port } finally { $socket.Stop() }
        $config = @"
Port $port
AddressFamily inet
ListenAddress 0.0.0.0
HostKey $($hostKey.Replace('\', '/'))
PidFile $($job.Replace('\', '/'))/sshd.pid
AuthorizedKeysFile $($authorized.Replace('\', '/'))
StrictModes yes
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers $userName
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
PermitTTY no
X11Forwarding no
MaxAuthTries 2
MaxSessions 1
Subsystem sftp C:/Windows/System32/OpenSSH/sftp-server.exe
LogLevel ERROR
"@
        $configPath = Join-Path $job 'sshd_config'
        Set-Content -LiteralPath $configPath -Value $config -Encoding ASCII
        & $sshd -t -f $configPath *> $null
        if ($LASTEXITCODE -ne 0) { throw 'ACTION: Isolated OpenSSH configuration failed validation; existing sshd was not changed.' }
        if ([datetime]::UtcNow -ge $expires.AddMinutes(-10)) { throw 'ACTION: Setup consumed the transfer lifetime; no listener opened.' }
        function Convert-ArtifactIp { param([uint64]$Value) '{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255) }
        $outside = @("0.0.0.0-$(Convert-ArtifactIp ($boundary.first - 1))", "$(Convert-ArtifactIp ($boundary.last + 1))-255.255.255.255")
        $null = New-NetFirewallRule -Name "FWF-$($payload.id)-block" -DisplayName "FWF $($payload.id) non-Bastion block" -Direction Inbound -Action Block -Protocol TCP -LocalPort $port -RemoteAddress $outside -Profile Any
        $null = New-NetFirewallRule -Name "FWF-$($payload.id)-allow" -DisplayName "FWF $($payload.id) Bastion allow" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress $payload.cidr -Program $sshd -Profile Any
        foreach ($name in @("FWF-$($payload.id)-allow", "FWF-$($payload.id)-block")) {
            $rule = Get-NetFirewallRule -Name $name -PolicyStore ActiveStore -ErrorAction SilentlyContinue
            $expectedAction = if ($name.EndsWith('-allow')) { 'Allow' } else { 'Block' }
            if (-not $rule -or $rule.Enabled -ne $true -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne $expectedAction) { throw 'ACTION: Temporary firewall rule is not effective in ActiveStore.' }
        }
        $null = New-Item -ItemType Directory -Path (Join-Path $job 'incoming')
        $action = New-ScheduledTaskAction -Execute $sshd -Argument "-D -f `"$configPath`" -E `"$job\sshd.log`""
        $null = Register-ScheduledTask -TaskName "FWF-$($payload.id)-sshd" -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1))
        Start-ScheduledTask -TaskName "FWF-$($payload.id)-sshd"
        @{ user = $userName; port = $port; hostKey = (Get-Content -LiteralPath "$hostKey.pub" -Raw).Trim(); incoming = "$job\incoming" }
    }
}

function Get-ArtifactVerifyScript {
    {
        param($payload)
        if ($payload.environment -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,47}$' -or $payload.id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid artifact destination.' }
        $active = 'C:\ProgramData\FunWithFoundry\.artifact-transfer\active'
        if (Test-Path -LiteralPath $active) {
            Assert-ArtifactPlainPath $active
            if ((Get-Content -LiteralPath $active -Raw).Trim() -cne $payload.id) { throw 'ACTION: Previous artifact transfer cleanup is unresolved. Reconcile its owned state before accepting retained files.' }
        }
        $destination = "C:\ProgramData\FunWithFoundry\$($payload.environment)\tool-artifacts"
        $incoming = "C:\ProgramData\FunWithFoundry\.artifact-transfer\$($payload.id)\incoming"
        $verified = @()
        foreach ($artifact in $payload.files) {
            if ($artifact.fileName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+$' -or $artifact.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid remote artifact pin.' }
            $target = Join-Path $destination $artifact.fileName
            if (Test-Path -LiteralPath $target) {
                Assert-ArtifactPlainPath $target
                if ((Get-Item -LiteralPath $target).Length -ne $artifact.bytes -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $artifact.sha256) {
                    throw "ACTION: Existing artifact differs: $($artifact.fileName). Quarantine it with separate approval before retrying; it was not overwritten."
                }
                $verified += $artifact.fileName
            }
            if ($payload.publish) {
                $source = Join-Path $incoming $artifact.fileName
                Assert-ArtifactPlainPath $source
                if ((Get-Item -LiteralPath $source).Length -ne $artifact.bytes -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $artifact.sha256) { throw 'ACTION: Uploaded artifact hash/size mismatch; nothing new published.' }
            }
        }
        if ($payload.publish) {
            foreach ($path in @('C:\ProgramData\FunWithFoundry', "C:\ProgramData\FunWithFoundry\$($payload.environment)", $destination)) {
                if (Test-Path -LiteralPath $path) { Assert-ArtifactPlainPath $path }
                else { $null = New-Item -ItemType Directory -Path $path }
            }
            foreach ($artifact in $payload.files) {
                $target = Join-Path $destination $artifact.fileName
                if ($verified -notcontains $artifact.fileName) { [IO.File]::Move((Join-Path $incoming $artifact.fileName), $target) }
                if ((Get-Item -LiteralPath $target).Length -ne $artifact.bytes -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $artifact.sha256) { throw 'ACTION: Final artifact read-back failed.' }
            }
            $verified = @($payload.files.fileName)
        }
        @{ verified = @($verified); root = $destination }
    }
}

function New-ArtifactLocalDirectory {
    $temporaryRoot = [IO.Path]::GetTempPath()
    if ($temporaryRoot -notmatch '^[a-zA-Z]:\\') { throw 'Temporary SSH credentials require a local Windows drive.' }
    Assert-ArtifactPlainPath $temporaryRoot
    $path = Join-Path $temporaryRoot ('fwf-transfer-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path
    try {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($owner)
        foreach ($identity in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $path -AclObject $acl
        $path
    }
    catch { Remove-Item -LiteralPath $path -Recurse -Force; throw }
}

function Get-ArtifactClientOptions {
    param([string]$Directory, [string]$Alias)
    @('-F', (Join-Path $Directory 'client_config'), '-i', (Join-Path $Directory 'identity'),
        '-o', "UserKnownHostsFile=`"$(Join-Path $Directory 'known_hosts')`"",
        '-o', "GlobalKnownHostsFile=`"$(Join-Path $Directory 'client_config')`"",
        '-o', "HostKeyAlias=$Alias", '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlgorithms=ssh-ed25519',
        '-o', 'VerifyHostKeyDNS=no', '-o', 'UpdateHostKeys=no', '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
        '-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
        '-o', 'PreferredAuthentications=publickey', '-o', 'ConnectTimeout=5', '-o', 'ConnectionAttempts=1',
        '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', '-o', 'ClearAllForwardings=yes', '-o', 'LogLevel=ERROR')
}

function Start-ArtifactTunnel {
    param($Scope, [int]$RemotePort, [int]$LocalPort)
    $azPath = @(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source.Replace("'", "''")
    $arguments = @('network', 'bastion', 'tunnel', '--subscription', $Scope.subscription, '--resource-group', $Scope.group,
        '--name', $Scope.bastion, '--target-resource-id', $Scope.vmId, '--resource-port', [string]$RemotePort, '--port', [string]$LocalPort)
    $encodedArguments = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($arguments | ConvertTo-Json -Compress)))
    $command = "`$ErrorActionPreference = 'Stop'; `$parameters = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedArguments')) | ConvertFrom-Json; & '$azPath' @parameters; exit `$LASTEXITCODE"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-NonInteractive')
    $start.ArgumentList.Add('-EncodedCommand')
    $start.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['AZURE_EXTENSION_USE_DYNAMIC_INSTALL'] = 'no'
    $process = [Diagnostics.Process]::Start($start)
    try { [pscustomobject]@{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync() } }
    catch { $process.Kill($true); $process.Dispose(); throw }
}

function Stop-ArtifactTunnel {
    param($Tunnel)
    try {
        if (-not $Tunnel.process.HasExited) {
            $Tunnel.process.Kill($true)
            if (-not $Tunnel.process.WaitForExit(10000)) { throw 'Bastion tunnel process tree did not stop.' }
        }
    }
    finally { $Tunnel.process.Dispose() }
}

function Wait-ArtifactTunnel {
    param($Tunnel, [int]$Port)
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    do {
        if ($Tunnel.process.HasExited) { throw 'Bastion tunnel exited before TCP readiness. Check native tunneling, CLI extension, RBAC and routing; no network exceptions are made.' }
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $remaining = [int][math]::Max(1, [math]::Min(1000, ($deadline - [datetime]::UtcNow).TotalMilliseconds))
            if ($client.ConnectAsync('127.0.0.1', $Port).Wait($remaining) -and $client.Connected) { return }
        }
        catch { }
        finally { $client.Dispose() }
        $remaining = [int][math]::Max(0, [math]::Min(200, ($deadline - [datetime]::UtcNow).TotalMilliseconds))
        if ($remaining) { [Threading.Thread]::Sleep($remaining) }
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Bastion TCP readiness timed out; no public network workaround is attempted.'
}

function ConvertTo-ArtifactSftpPath {
    param([string]$Path)
    if ($Path -notmatch '^[a-zA-Z]:[\\/]' -or $Path -match '[*?\[\]"\x00-\x1f\x7f]' -or $Path.Substring(2).Contains(':')) {
        throw 'SFTP requires an absolute local drive path without glob characters, quotes, control characters or alternate streams.'
    }
    '"' + $Path.Replace('\', '/') + '"'
}

function New-ArtifactSftpBatch {
    param([object[]]$Files, [string]$Directory, [string]$Id)
    if ($Id -notmatch '^[a-f0-9]{32}$' -or $Files.Count -ne 4) { throw 'Expected one transfer ID and exactly four artifacts.' }
    $canary = Join-Path $Directory 'canary.bin'
    $readback = Join-Path $Directory 'canary-readback.bin'
    $commands = [Collections.Generic.List[string]]::new()
    $commands.Add('pwd')
    $commands.Add("cd /C:/ProgramData/FunWithFoundry/.artifact-transfer/$Id/incoming")
    $commands.Add('put ' + (ConvertTo-ArtifactSftpPath $canary) + ' canary.bin')
    $commands.Add('get canary.bin ' + (ConvertTo-ArtifactSftpPath $readback))
    $commands.Add('rm canary.bin')
    foreach ($file in $Files) {
        if ($file.fileName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+$' -or [IO.Path]::GetFileName($file.path) -cne $file.fileName) { throw 'Invalid SFTP artifact basename.' }
        $commands.Add('put ' + (ConvertTo-ArtifactSftpPath $file.path) + ' ' + $file.fileName)
    }
    [IO.File]::WriteAllBytes($canary, [Text.Encoding]::ASCII.GetBytes("FWF artifact transfer canary $Id"))
    $batch = Join-Path $Directory 'transfer.sftp'
    Set-Content -LiteralPath $batch -Value $commands -Encoding utf8NoBOM
    @{ path = $batch; canary = $canary; readback = $readback }
}

function Invoke-RunnerArtifactTransfer {
    param($Scope, [object[]]$Files, [string]$Environment)
    $local = $null
    $tunnel = $null
    $attempted = $false
    $locks = [Collections.Generic.List[IDisposable]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    $clientErrors = [Collections.Generic.List[string]]::new()
    $id = [guid]::NewGuid().ToString('N')
    $payload = @{ id = $id; environment = $Environment; files = @($Files | Select-Object fileName, bytes, sha256); publish = $false }
    $result = $null
    try {
        foreach ($file in $Files) {
            $locks.Add([IO.File]::Open($file.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
            if ((Get-Item -LiteralPath $file.path).Length -ne $file.bytes -or (Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ne $file.sha256) { throw 'Local artifact changed before the locked transfer.' }
        }
        $local = New-ArtifactLocalDirectory
        $batch = New-ArtifactSftpBatch $Files $local $id
        $inspection = Invoke-ArtifactRemote $Scope (Get-ArtifactVerifyScript) $payload $local
        if (@($inspection.verified).Count -eq 4 -and @($Files | Where-Object { $_.fileName -notin $inspection.verified }).Count -eq 0) {
            $result = @{ status = 'verified'; transport = 'already-present'; root = $inspection.root; files = $payload.files }
        }
        else {
            $identity = Join-Path $local 'identity'
            $null = Invoke-ArtifactCommand 'ssh-keygen.exe' @('-q', '-t', 'ed25519', '-N', '', '-f', $identity)
            $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $privateAcl = Get-Acl -LiteralPath $identity
            $trustedOwners = @($owner.Value, 'S-1-5-18', 'S-1-5-32-544')
            if ($privateAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $owner.Value -or
                @($privateAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                    $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $trustedOwners
                }).Count) { throw 'Generated SSH key ownership or access is broader than the current user and trusted Windows administrators.' }
            $public = (Get-Content -LiteralPath "$identity.pub" -Raw).Trim()
            $prepare = @{ id = $id; cidr = $Scope.cidr; publicKey = $public; cleanup = (Get-ArtifactCleanupScript).ToString(); pathGuard = ${function:Assert-ArtifactPlainPath}.ToString() }
            $attempted = $true
            $server = Invoke-ArtifactRemote $Scope (Get-ArtifactPrepareScript) $prepare $local
            if ($server.user -cne ('fwf' + $id.Substring(0, 16)) -or $server.port -lt 1024 -or $server.port -gt 65535 -or
                $server.incoming -cne "C:\ProgramData\FunWithFoundry\.artifact-transfer\$id\incoming" -or
                $server.hostKey -notmatch '^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: [^\r\n]*)?$') { throw 'Invalid authenticated SSH bootstrap contract.' }
            $alias = "fwf-$id"
            Set-Content -LiteralPath (Join-Path $local 'known_hosts') -Value "$alias ssh-ed25519 $($Matches[1])" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $local 'client_config') -Value '' -Encoding ASCII
            $options = Get-ArtifactClientOptions $local $alias
            $socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $socket.Start()
            try { $port = $socket.LocalEndpoint.Port } finally { $socket.Stop() }
            $tunnel = Start-ArtifactTunnel $Scope $server.port $port
            Wait-ArtifactTunnel $tunnel $port
            $null = Invoke-ArtifactCommand 'sftp.exe' (@('-b', $batch.path) + $options + @('-P', [string]$port, "$($server.user)@127.0.0.1")) -StandardError $clientErrors
            if (-not (Test-Path -LiteralPath $batch.readback -PathType Leaf) -or
                (Get-Item -LiteralPath $batch.canary).Length -ne (Get-Item -LiteralPath $batch.readback).Length -or
                (Get-FileHash -LiteralPath $batch.canary -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $batch.readback -Algorithm SHA256).Hash) {
                throw 'SFTP canary byte count or SHA256 mismatch; nothing published.'
            }
            $payload.publish = $true
            $verified = Invoke-ArtifactRemote $Scope (Get-ArtifactVerifyScript) $payload $local
            if (@($verified.verified).Count -ne 4 -or @($Files | Where-Object { $_.fileName -notin $verified.verified }).Count) { throw 'Final ARM hash verification is incomplete.' }
            $result = @{ status = 'verified'; transport = 'bastion-ssh'; root = $verified.root; files = $payload.files }
        }
    }
    catch {
        $failures.Add($_.Exception.Message)
        if ($attempted) {
            $guestLines = @('Guest diagnostics unavailable; cleanup will still be attempted.')
            try {
                $diagnostics = Invoke-ArtifactRemote $Scope (Get-ArtifactDiagnosticsScript) @{ id = $id } $local
                if ($diagnostics.recordType -ceq 'artifact-transfer-diagnostics' -and $diagnostics.source -ceq 'guest-sshd') {
                    $guestLines = @($diagnostics.lines | Select-Object -Last 6 | ForEach-Object { ConvertTo-ArtifactDiagnosticLine ([string]$_) })
                }
            }
            catch { }
            $diagnosticRecord = @{ recordType = 'artifact-transfer-diagnostics'; transferId = $id
                clientStderr = @($clientErrors | Select-Object -Last 6 | ForEach-Object { ConvertTo-ArtifactDiagnosticLine $_ }); guestSshd = $guestLines }
            Write-Warning ($diagnosticRecord | ConvertTo-Json -Depth 4 -Compress) -WarningAction Continue
        }
    }
    finally {
        if ($tunnel) { try { Stop-ArtifactTunnel $tunnel } catch { $failures.Add('Local tunnel cleanup failed.') } }
        if ($attempted) {
            try {
                $cleanup = Invoke-ArtifactRemote $Scope (Get-ArtifactCleanupScript) @{ id = $id } $local
                if ($cleanup.cleaned -ne $true) { throw 'Missing cleanup completion.' }
            }
            catch {
                $failures.Add("Remote cleanup not confirmed for transfer $id. Its one-hour guest cleanup task is a fallback, not proof; reconcile the owned state via ARM.")
                if ($_.Exception.Message -match 'Loaded profile (S-\d+(?:-\d+)+) requires') {
                    $failures.Add("Loaded profile $($Matches[1]) requires an explicitly approved VM restart before retrying cleanup; do not force-unload it or widen permissions.")
                }
            }
        }
        if ($local) { try { Remove-Item -LiteralPath $local -Recurse -Force } catch { $failures.Add("Delete the temporary credential directory immediately: $local") } }
        foreach ($handle in $locks) { $handle.Dispose() }
    }
    if ($failures.Count) { throw ($failures -join ' ') }
    [pscustomobject]$result
}

if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess("$SubscriptionId / $EnvironmentName", 'Private verified artifact transfer, temporary SSH/key/capability lifecycle, Bastion tunnel and cleanup')
    return
}
if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.3') { throw 'Use Windows PowerShell 7.3+ with native Windows OpenSSH clients.' }
if ($env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION) { throw 'Azure CLI TLS verification must be enabled before trusting ARM host-key delivery.' }
foreach ($name in @('terraform', 'az', 'pwsh', 'sftp.exe', 'ssh-keygen.exe')) { $null = Get-Command $name -CommandType Application -ErrorAction Stop }
$files = @(Get-RunnerArtifactPlan $ToolManifestPath)
$dynamicInstall = $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
try {
    $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no'
    $scope = Get-ArtifactTransferScope $SubscriptionId ([IO.Path]::GetFullPath($TerraformDir))
    if (-not $PSCmdlet.ShouldProcess("$($scope.vmId) via $($scope.bastionId); source CIDR $($scope.cidr)",
        'Upload four verified artifacts; create/remove isolated SSH account, keys, tasks and firewall rules; install/remove OpenSSH Server only if absent; start/stop local Bastion tunnel; mandatory cleanup')) { throw 'Artifact transfer approval declined.' }
    Invoke-RunnerArtifactTransfer $scope $files $EnvironmentName
}
finally { $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = $dynamicInstall }
