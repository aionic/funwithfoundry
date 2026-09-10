<#
.SYNOPSIS
    Resumable, explicitly approved private deployment using Terraform and VM Run Command.
.DESCRIPTION
    Stages: Preflight, Infrastructure, Workload, Verify. No teardown and no GitHub/OIDC flow.
    Run -ListStages or -WhatIf without cloud calls. -Resume skips completed, fingerprint-matched
    steps. Failed/unknown native deployment attempts require read-back, never a blind redeploy.

        Workload requires -ToolManifestPath from scripts/Get-RunnerToolManifest.ps1.
        That local-only provider verifies official azd/uv artifacts and the complete
        eight-extension Foundry bundle. Review .azure/runner-tools.json; Workload.Artifacts
        transfers the three verified files through Bastion using temporary pinned SSH
        after source staging and before tool initialization. No runner
        GitHub/aka.ms download or firewall change is used for tool installation.

    Terraform owns infrastructure. azd owns native code/toolbox deployment only; no azd provision.
    The runner receives explicit source files plus a non-secret manifest, never .azure/.azd
    login caches, Terraform state, or workstation credentials. Its own azd login uses IMDS.
    Plans/state/results live under the already git-ignored .azure/<environment>/accelerator.
    Plans can contain sensitive Terraform values: protect this local directory as Terraform state.
    Workload.RuntimeRbac writes native-agent.auto.tfvars.json there (not inside terraform);
    every subsequent plan passes it explicitly using -var-file. Never use -auto-approve.

    Missing foundry_primary.planner_deployment / planner_model outputs must be supplied by
    the parent Terraform change, or explicitly via -PlannerDeployment and -PlannerModel.
.EXAMPLE
    .\scripts\Invoke-Accelerator.ps1 -ListStages
.EXAMPLE
    .\scripts\Invoke-Accelerator.ps1 -SubscriptionId <guid> -Stage Preflight,Infrastructure -Resume -Confirm
.EXAMPLE
    .\scripts\Invoke-Accelerator.ps1 -SubscriptionId <guid> -Stage Workload,Verify -Resume -ToolManifestPath .azure\tools.json -Confirm
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Preflight', 'Infrastructure', 'Workload', 'Verify')]
    [string[]]$Stage = @('Preflight'),
    [guid]$SubscriptionId,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,47}$')][string]$EnvironmentName = 'funwithfoundry-dev',
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [string]$ToolManifestPath,
    [string]$PlannerDeployment,
    [string]$PlannerModel,
    [string]$PrimaryRegion = 'centralus',
    [string]$SecondaryRegion = 'southcentralus',
    [string]$JumpboxSize = 'Standard_D4s_v5',
    [switch]$Resume,
    [switch]$ListStages
)

$ErrorActionPreference = 'Stop'

function Invoke-CheckedCommand {
    param([string]$Command, [string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $result = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command $($Arguments[0]) failed (exit $LASTEXITCODE)." }
    $result
}

function Save-AcceleratorState {
    $temporary = "$statePath.tmp"
    $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
}

function Invoke-StageStep {
    param([string]$Name, [scriptblock]$Action, [switch]$Always)
    if ($Resume -and -not $Always -and $state.steps.ContainsKey($Name) -and $state.steps[$Name].status -eq 'succeeded') {
        Write-Host "Resume: $Name already completed."
        return $state.steps[$Name].output
    }
    $state.steps[$Name] = @{ status = 'running'; started_utc = [datetime]::UtcNow.ToString('o'); output = $null }
    Save-AcceleratorState
    try {
        Write-Host "Running $Name"
        $output = & $Action
        $state.steps[$Name].output = $output
        $state.steps[$Name].status = 'succeeded'
        $state.steps[$Name].finished_utc = [datetime]::UtcNow.ToString('o')
        Save-AcceleratorState
        $output
    }
    catch {
        $state.steps[$Name].status = 'failed'
        $state.steps[$Name].reason = 'step_failed_or_outcome_unknown'
        Save-AcceleratorState
        throw
    }
}

function Invoke-ReviewedApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string]$Name, [string[]]$AdditionalArguments = @())
    $planPath = Join-Path $stateDirectory "$Name.tfplan"
    $arguments = @("-chdir=$TerraformDir", 'plan', '-input=false', '-no-color', "-out=$planPath") + $AdditionalArguments
    if (Test-Path -LiteralPath $nativeVariablesPath) { $arguments += "-var-file=$nativeVariablesPath" }
    else { $arguments += '-var=native_agent_principal_id=' }
    Invoke-CheckedCommand 'terraform' $arguments | Out-Host
    $plan = Invoke-CheckedCommand 'terraform' @("-chdir=$TerraformDir", 'show', '-json', $planPath) | ConvertFrom-Json
    if ([string]$plan.variables.subscription_id.value -ne [string]$SubscriptionId) { throw 'Plan subscription differs from the explicitly selected subscription.' }
    Invoke-CheckedCommand 'terraform' @("-chdir=$TerraformDir", 'show', '-no-color', $planPath) | Out-Host
    $hash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
    if (-not $PSCmdlet.ShouldProcess("$planPath SHA256=$hash", 'Apply the displayed Terraform plan')) { throw 'Terraform plan approval declined.' }
    if ((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -ne $hash) { throw 'Plan changed after review.' }
    Invoke-CheckedCommand 'terraform' @("-chdir=$TerraformDir", 'apply', '-input=false', '-no-color', $planPath) | Out-Host
    @{ plan_sha256 = $hash; status = 'applied' }
}

function Get-DeploymentManifest {
    $outputs = Invoke-CheckedCommand 'terraform' @("-chdir=$TerraformDir", 'output', '-json') | ConvertFrom-Json
    if ([string]$outputs.subscription_id.value -ne [string]$SubscriptionId) { throw 'Terraform subscription output is missing or mismatched.' }
    $primary = $outputs.foundry_primary.value
    $function = $outputs.ingest_function.value
    $planner = if ($PlannerDeployment) { $PlannerDeployment } else { $primary.planner_deployment }
    $model = if ($PlannerModel) { $PlannerModel } else { $primary.planner_model }
    $manifest = [ordered]@{
        subscription_id = [string]$SubscriptionId
        tenant_id = $outputs.tenant_id.value
        environment = $EnvironmentName
        primary_resource_group = $outputs.resource_groups.value.primary
        jumpbox_name = $outputs.jumpbox.value.name
        project_id = $outputs.foundry_primary_project_id.value
        account_id = $outputs.foundry_primary_account_id.value
        project_endpoint = $primary.project_endpoint
        location = $primary.location
        agent_model = $primary.agent_tool_model
        search_endpoint = $primary.search_endpoint
        search_connection = $primary.search
        openai_endpoint = "https://$($primary.account).openai.azure.com"
        planner_deployment = $planner
        planner_model = $model
        function_hostname = $function.hostname
        function_api_client_id = $function.api_client_id
    }
    foreach ($key in $manifest.Keys) {
        if (-not $manifest[$key]) { throw "Missing deployment contract '$key'. Planner values require foundry_primary.planner_deployment and planner_model outputs or explicit parameters." }
    }
    if ($manifest.project_id -notlike "/subscriptions/$SubscriptionId/*" -or
        $manifest.account_id -notlike "/subscriptions/$SubscriptionId/*") { throw 'Foundry output ARM scope mismatch.' }
    $manifest
}

function Invoke-PrivateCommand {
    param([scriptblock]$Script, $Payload)
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.ToString()))
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 30 -Compress)))
    $marker = 'FWF_ACCELERATOR_' + [guid]::NewGuid().ToString('N') + '='
    $wrapper = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$global:LASTEXITCODE = 0
`$record = @{ status = 'failed'; reason = 'private_runner_failed' }
try {
    `$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedPayload')) | ConvertFrom-Json
    `$script = [scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedScript')))
    `$result = & `$script `$payload
    if (`$LASTEXITCODE -ne 0) { throw 'Native command failed.' }
    `$record = @{ status = 'succeeded'; output = `$result }
}
catch {
    if (`$_.Exception.Message -like 'ACTION:*') { `$record.reason = `$_.Exception.Message }
}
finally { Write-Output ('$marker' + (`$record | ConvertTo-Json -Depth 20 -Compress)) }
"@
    $temporary = [IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $temporary -Value $wrapper -Encoding UTF8
        $raw = Invoke-CheckedCommand 'az' @('vm', 'run-command', 'invoke', '--subscription', [string]$SubscriptionId,
            '--resource-group', $manifest.primary_resource_group, '--name', $manifest.jumpbox_name,
            '--command-id', 'RunPowerShellScript', '--scripts', "@$temporary", '-o', 'json')
        $response = $raw | ConvertFrom-Json
        if (-not $response.value -or @($response.value | Where-Object { $_.code -notmatch '/succeeded$' -or $_.level -eq 'Error' }).Count) {
            throw 'Run Command failed or is incomplete; inspect the VM operation before retrying.'
        }
        if (@($response.value | Where-Object { $_.code -match '/StdErr/' -and -not [string]::IsNullOrWhiteSpace($_.message) }).Count) { throw 'Private runner reported stderr.' }
        $text = $response.value.message -join "`n"
        if ($text -match '(?s)\[stderr\](.*)$' -and -not [string]::IsNullOrWhiteSpace($Matches[1])) { throw 'Private runner reported stderr.' }
        $matches = [regex]::Matches($text, '(?m)^' + [regex]::Escape($marker) + '(\{[^\r\n]+\})\r?$')
        if ($matches.Count -ne 1) { throw 'Private runner completion marker missing or truncated. Read back remote state before retrying deployment.' }
        $record = $matches[0].Groups[1].Value | ConvertFrom-Json
        if ($record.status -ne 'succeeded') { throw "Private runner failed: $($record.reason)" }
        $record.output
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Send-RunnerSource {
    $staging = Join-Path $stateDirectory 'transfer'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $staging -Force
    foreach ($relative in $sourceFiles) {
        $destination = Join-Path $staging $relative
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination
    }
    [IO.File]::WriteAllText((Join-Path $staging 'src\foundry_native_agent\requirements.txt'), "--require-hashes`n-r requirements.lock`n", [Text.UTF8Encoding]::new($false))
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $staging 'deployment-manifest.json') -Encoding UTF8
    $tools | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $staging 'tool-manifest.json') -Encoding UTF8
    $archive = Join-Path $stateDirectory 'source.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $archive)
    $bytes = [IO.File]::ReadAllBytes($archive)
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $runnerRoot = "C:\ProgramData\FunWithFoundry\$EnvironmentName"
    for ($offset = 0; $offset -lt $bytes.Length; $offset += 12000) {
        $length = [Math]::Min(12000, $bytes.Length - $offset)
        $chunk = [Convert]::ToBase64String($bytes, $offset, $length)
        $null = Invoke-PrivateCommand {
            param($payload)
            $null = New-Item -ItemType Directory -Path $payload.root -Force
            $path = Join-Path $payload.root "$($payload.hash).zip"
            $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write)
            try {
                if ($payload.offset -eq 0) { $stream.SetLength(0) }
                $null = $stream.Seek([long]$payload.offset, [IO.SeekOrigin]::Begin)
                $content = [Convert]::FromBase64String($payload.chunk)
                $stream.Write($content, 0, $content.Length)
            }
            finally { $stream.Dispose() }
        } @{ root = $runnerRoot; hash = $hash; offset = $offset; chunk = $chunk }
    }
    Invoke-PrivateCommand {
        param($payload)
        $archive = Join-Path $payload.root "$($payload.hash).zip"
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $payload.hash) { throw 'Source transfer hash mismatch.' }
        $destination = Join-Path $payload.root "source\$($payload.fingerprint)"
        $null = New-Item -ItemType Directory -Path $destination -Force
        Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
        Remove-Item -LiteralPath $archive -Force
        @{ root = $payload.root; source = $destination; source_sha256 = $payload.hash }
    } @{ root = $runnerRoot; hash = $hash; fingerprint = $workloadFingerprint }
}

function Initialize-RunnerTools {
    $artifactDirectory = Join-Path (Split-Path ([IO.Path]::GetFullPath($ToolManifestPath)) -Parent) 'runner-tool-cache'
    foreach ($artifact in @($tools.azd, $tools.uv, $tools.python, $tools.extensionBundle)) {
        $path = Join-Path $artifactDirectory $artifact.fileName
        if (-not (Test-Path -LiteralPath $path) -or
            (Get-Item -LiteralPath $path).Length -ne $artifact.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $artifact.sha256) {
            throw "Local runner artifact missing or changed: $path. Regenerate scripts/Get-RunnerToolManifest.ps1 before staging."
        }
    }
    Invoke-PrivateCommand {
        param($payload)
        $tools = Get-Content (Join-Path $payload.source 'tool-manifest.json') -Raw | ConvertFrom-Json
        $toolRoot = Join-Path $payload.root 'tools'
        $artifactRoot = Join-Path $payload.root 'tool-artifacts'
        foreach ($artifact in @($tools.azd, $tools.uv, $tools.python, $tools.extensionBundle)) {
            $path = Join-Path $artifactRoot $artifact.fileName
            if (-not (Test-Path -LiteralPath $path)) {
            throw "ACTION: Bulk-copy the four files listed in runner-tools.json staging.requiredFiles from workstation runner-tool-cache to $artifactRoot over an approved private file-transfer path, then resume. No VM downloads or firewall changes are attempted."
            }
            if ((Get-Item -LiteralPath $path).Length -ne $artifact.bytes -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $artifact.sha256) { throw "ACTION: Staged artifact hash/size mismatch: $($artifact.fileName). Copy the verified workstation artifact again." }
        }
        $null = New-Item -ItemType Directory -Path $toolRoot -Force
        foreach ($tool in @('azd', 'uv', 'python')) {
            $pin = $tools.$tool
            $directory = Join-Path $toolRoot $(if ($tool -eq 'python') { "python$($pin.version)" } else { "$tool-$($pin.version)" })
            $executable = Join-Path $directory "$tool.exe"
            $download = Join-Path $artifactRoot $pin.fileName
            if ($tool -eq 'azd') {
                $signature = Get-AuthenticodeSignature -LiteralPath $download
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)' -or
                    $signature.SignerCertificate.Thumbprint -ne $pin.authenticode.thumbprint) { throw 'ACTION: Staged azd MSI does not match the verified Microsoft Authenticode signer; inspect certificate trust/revocation access and artifact integrity.' }
            }
            if ($tool -eq 'python') {
                $signature = Get-AuthenticodeSignature -LiteralPath $download
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Python Software Foundation(?:,|$)' -or
                    $signature.SignerCertificate.Thumbprint -ne $pin.authenticode.thumbprint) { throw 'ACTION: Staged Python installer does not match the verified Python Software Foundation Authenticode signer; inspect certificate trust/revocation access and artifact integrity.' }
            }
            if (-not (Test-Path -LiteralPath $executable)) {
                $null = New-Item -ItemType Directory -Path $directory -Force
                if ($tool -in @('azd', 'python')) {
                    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
                    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'ACTION: Run the bootstrap through VM Run Command (SYSTEM). No interactive elevation is attempted.' }
                }
                if ($tool -eq 'azd') {
                    $installer = New-Object -ComObject WindowsInstaller.Installer
                    $database = $installer.OpenDatabase($download, 0)
                    $view = $database.OpenView('SELECT `Value` FROM `Property` WHERE `Property` = ''WIXUI_INSTALLDIR''')
                    try {
                        $null = $view.Execute()
                        $record = $view.Fetch()
                        if (-not $record -or $record.StringData(1) -ne 'INSTALLDIR') { throw 'ACTION: Signed MSI no longer supports the verified INSTALLDIR property.' }
                    }
                    finally { $null = $view.Close() }
                    $log = Join-Path $directory 'msi-install.log'
                    $process = Start-Process "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/i', "`"$download`"", '/qn', '/norestart',
                        'ALLUSERS=1', 'MSIINSTALLPERUSER=""', "INSTALLDIR=`"$directory`"", '/L*v', "`"$log`"") -PassThru -Wait
                    if ($process.ExitCode -eq 3010) { throw 'ACTION: azd MSI requires a reboot; reboot the runner and resume.' }
                    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $executable)) { throw "ACTION: azd MSI installation failed or used an existing registered location. Inspect $log and HKLM\SOFTWARE\Microsoft\Azure Dev CLI\InstallDir before retrying." }
                }
                elseif ($tool -eq 'python') {
                    $log = Join-Path $directory 'python-install.log'
                    $process = Start-Process -FilePath $download -ArgumentList @('/quiet', '/norestart', 'InstallAllUsers=1', "TargetDir=`"$directory`"",
                        'Include_launcher=0', 'InstallLauncherAllUsers=0', 'PrependPath=0', 'AppendPath=0', 'Include_test=0', 'Include_pip=0',
                        'AssociateFiles=0', 'Shortcuts=0', '/log', "`"$log`"") -PassThru -Wait
                    if ($process.ExitCode -eq 3010) { throw 'ACTION: Python installer requires a restart; restart the runner and resume.' }
                    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $executable)) { throw "ACTION: Python installation failed or used an existing registered location. Inspect $log; the explicit runner Python path is required." }
                }
                else {
                    Expand-Archive -LiteralPath $download -DestinationPath $directory -Force
                    if (-not (Test-Path $executable)) {
                        $candidates = @(Get-ChildItem -LiteralPath $directory -Filter uv.exe -Recurse)
                        if ($candidates.Count -ne 1) { throw 'Unexpected uv release layout.' }
                        Copy-Item -LiteralPath $candidates[0].FullName -Destination $executable
                    }
                }
            }
            if ($tool -eq 'python') {
                $runtimeSignature = Get-AuthenticodeSignature -LiteralPath $executable
                if ($runtimeSignature.Status -ne 'Valid' -or $runtimeSignature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Python Software Foundation(?:,|$)') { throw 'ACTION: Runner Python executable lacks valid Python Software Foundation Authenticode.' }
                $version = @(& $executable -I -c "import struct, sys; print('.'.join(map(str, sys.version_info[:3]))); print(struct.calcsize('P') * 8)")
                if ($LASTEXITCODE -ne 0 -or $version.Count -ne 2 -or $version[0] -cne $pin.version -or $version[1] -cne '64') { throw 'ACTION: Runner Python must match the exact pinned release and Windows x64 architecture.' }
                continue
            }
            if ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ne $pin.binarySha256) { throw "ACTION: $tool binary differs from the verified official release; inspect runner integrity before reinstalling." }
            $version = if ($tool -eq 'azd') { & $executable version } else { & $executable --version }
            $prefix = if ($tool -eq 'azd') { 'azd version' } else { 'uv' }
            if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch "^$prefix $([regex]::Escape($pin.version))(?: |$)") { throw "ACTION: $tool installed version differs from the reviewed pin." }
            $env:PATH = "$directory;$env:PATH"
        }
        $bundle = Join-Path $artifactRoot $tools.extensionBundle.fileName
        $bundleDirectory = Join-Path $toolRoot "extension-bundle-$($tools.extensionBundle.sha256)"
        Expand-Archive -LiteralPath $bundle -DestinationPath $bundleDirectory -Force
        $registry = Get-Content -LiteralPath (Join-Path $bundleDirectory 'registry.json') -Raw | ConvertFrom-Json
        if (@($registry.extensions).Count -ne 8) { throw 'ACTION: Extension bundle must contain exactly eight reviewed entries.' }
        foreach ($extension in $tools.extensions) {
            $entry = @($registry.extensions | Where-Object id -eq $extension.id)
            if ($entry.Count -ne 1 -or @($entry[0].versions).Count -ne 1 -or $entry[0].versions[0].version -ne $extension.version) { throw "ACTION: Bundle version mismatch for $($extension.id)." }
            $version = $entry[0].versions[0]
            if ($extension.id -ne 'microsoft.foundry') {
                $artifact = $version.artifacts.'windows/amd64'
                if ($artifact.url -ne $extension.fileName -or $artifact.checksum.algorithm -ne 'sha256' -or
                    $artifact.checksum.value -ne $extension.sha256 -or
                    (Get-FileHash -LiteralPath (Join-Path $bundleDirectory $extension.fileName) -Algorithm SHA256).Hash -ne $extension.sha256) { throw "ACTION: Bundle artifact mismatch for $($extension.id)." }
            }
            foreach ($dependency in $version.dependencies) {
                if ($dependency.id -notin $tools.extensions.id) { throw "ACTION: Unpinned extension dependency $($dependency.id)." }
            }
        }
        $installLog = Join-Path $toolRoot 'extensions-install.log'
        & azd extension install $bundle --no-prompt --force *> $installLog
        if ($LASTEXITCODE -ne 0) { throw "ACTION: Pinned offline extension installation failed. Inspect $installLog; no network fallback is approved." }
        $installed = & azd extension list --installed --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'ACTION: Cannot verify runner extension pins.' }
        foreach ($extension in $tools.extensions) {
            if (@($installed | Where-Object { $_.id -eq $extension.id -and $_.installedVersion -eq $extension.version }).Count -ne 1) { throw "ACTION: Installed extension differs from pin: $($extension.id)." }
        }
        Push-Location $payload.source
        try {
            $environments = & azd env list --output json
            if ($LASTEXITCODE -ne 0) { throw 'ACTION: Pinned azd does not support environment JSON discovery.' }
            $null = $environments | ConvertFrom-Json
        }
        finally { Pop-Location }
        @{ status = 'ready'; azd_version = $tools.azd.version; uv_version = $tools.uv.version; python_version = $tools.python.version
            python_executable = (Join-Path $toolRoot "python$($tools.python.version)\python.exe") }
    } $runner
}

function Invoke-RunnerWorkload {
    param([ValidateSet('Knowledge', 'Native', 'Verify')][string]$Action)
    Invoke-PrivateCommand {
        param($payload)
        $source = $payload.source
        $manifest = Get-Content (Join-Path $source 'deployment-manifest.json') -Raw | ConvertFrom-Json
        $tools = Get-Content (Join-Path $source 'tool-manifest.json') -Raw | ConvertFrom-Json
        $env:PATH = "$(Join-Path $payload.root "tools\azd-$($tools.azd.version)");$(Join-Path $payload.root "tools\uv-$($tools.uv.version)");$env:PATH"
        $env:AZURE_SUBSCRIPTION_ID = $manifest.subscription_id
        $env:AZURE_TENANT_ID = $manifest.tenant_id
        Push-Location $source
        try {
            if ($payload.action -eq 'Knowledge') {
                return & .\scripts\Initialize-KnowledgeBase.ps1 -SearchEndpoint $manifest.search_endpoint `
                    -FoundryOpenAIEndpoint $manifest.openai_endpoint -PlannerDeployment $manifest.planner_deployment `
                    -PlannerModel $manifest.planner_model -Confirm:$false
            }
            if ($payload.action -eq 'Verify') {
                $runtimePython = Join-Path $payload.root "tools\python$($tools.python.version)\python.exe"
                if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) { throw 'ACTION: Pinned runner Python is missing. Complete Workload.Tools before Verify; automatic Python downloads are disabled.' }
                $python = Join-Path $payload.root 'verification-venv\Scripts\python.exe'
                if (-not (Test-Path $python)) {
                    $ErrorActionPreference = 'Continue'
                    & uv venv (Split-Path (Split-Path $python -Parent) -Parent) --no-python-downloads --python $runtimePython *> (Join-Path $payload.root 'verification-environment.log')
                    $exitCode = $LASTEXITCODE
                    $ErrorActionPreference = 'Stop'
                    if ($exitCode -ne 0) { throw 'ACTION: uv could not create the isolated verification environment from the pinned runner Python. Repair Workload.Tools; automatic Python downloads are disabled.' }
                }
                $ErrorActionPreference = 'Continue'
                & uv pip install --python $python --require-hashes -r .\src\hello_world\requirements.lock *> (Join-Path $payload.root 'verification-install.log')
                $exitCode = $LASTEXITCODE
                $ErrorActionPreference = 'Stop'
                if ($exitCode -ne 0) { throw 'ACTION: Verification dependencies failed; check allowed package-index hosts.' }
                $global:LASTEXITCODE = 0
                $probeText = & .\scripts\jumpbox\Test-Ingestion.ps1 -FunctionHostname $manifest.function_hostname -ApiClientId $manifest.function_api_client_id -Confirm:$false
                if ($LASTEXITCODE -ne 0) { throw 'Authorized ingestion probes failed.' }
                $probes = ($probeText -join "`n") | ConvertFrom-Json
                if ($probes.status -ne 'passed') { throw 'Authorized ingestion probes did not pass.' }
                $proof = & .\scripts\jumpbox\Invoke-EndToEnd.ps1 -FunctionHostname $manifest.function_hostname `
                    -ApiClientId $manifest.function_api_client_id -SearchEndpoint $manifest.search_endpoint `
                    -ProjectEndpoint $manifest.project_endpoint -SearchToolName $manifest.search_connection `
                    -ModelDeployment $manifest.agent_model -PythonExecutable $python -Confirm:$false
                return @{ ingestion = $probes; end_to_end = $proof }
            }
            $null = & azd auth login --managed-identity --no-prompt 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'ACTION: azd managed-identity login failed on the runner; no workstation login cache is used.' }
            $environment = $manifest.environment
            $newEnvironment = -not (Test-Path -LiteralPath (Join-Path $source ".azure\$environment"))
            if ($newEnvironment) {
                $null = & azd env new $environment --subscription $manifest.subscription_id --location $manifest.location --no-prompt
                if ($LASTEXITCODE -ne 0) { throw 'Unable to create runner azd environment.' }
            }
            $null = & azd env select $environment --no-prompt
            if ($LASTEXITCODE -ne 0) { throw 'Unable to select runner azd environment.' }
            foreach ($pair in @(@('AZURE_AI_PROJECT_ID', $manifest.project_id), @('FOUNDRY_PROJECT_ENDPOINT', $manifest.project_endpoint))) {
                $null = & azd env set $pair[0] $pair[1]
                if ($LASTEXITCODE -ne 0) { throw 'Unable to bind runner azd project.' }
            }
            $readParameters = @{ ReadOnly = $true; ProjectEndpoint = $manifest.project_endpoint; EnvironmentName = $environment; AzdDebug = $true }
            $attemptPath = Join-Path $source '.azure\native-attempt.json'
            $prior = $null
            if (Test-Path $attemptPath) {
                $prior = Get-Content $attemptPath -Raw | ConvertFrom-Json
            }
            else {
                $previousVersion = ''
                if (-not $newEnvironment) {
                    $before = & .\scripts\Deploy-NativeFoundryAgent.ps1 @readParameters
                    if ($LASTEXITCODE -ne 0 -or -not $before.agent.version) { throw 'ACTION: Existing runner environment has no readable agent version. Reconcile the environment before starting another deployment.' }
                    $previousVersion = [string]$before.agent.version
                }
                $prior = @{ previous_version = $previousVersion; status = 'attempting' }
                $prior | ConvertTo-Json | Set-Content $attemptPath -Encoding UTF8
                $parameters = @{
                    EnvironmentName = $environment; ProjectId = $manifest.project_id; Location = $manifest.location
                    ProjectEndpoint = $manifest.project_endpoint; ModelDeployment = $manifest.agent_model
                    SearchEndpoint = $manifest.search_endpoint; SearchConnectionName = $manifest.search_connection
                    AzdDebug = $true
                }
                & .\scripts\Deploy-NativeFoundryAgent.ps1 @parameters *> (Join-Path $source '.azure\native-deploy.log')
                if ($LASTEXITCODE -ne 0) { throw 'ACTION: Native deployment outcome unknown. Resume reads back the attempt; it does not redeploy.' }
            }
            $deadline = [datetime]::UtcNow.AddMinutes(20)
            do {
                $metadata = & .\scripts\Deploy-NativeFoundryAgent.ps1 @readParameters
                $agent = $metadata.agent
                if ($LASTEXITCODE -ne 0 -or -not $agent.status) { throw 'ACTION: Native agent read-back failed. Resume after checking the existing deployment; do not delete the attempt marker to retry blindly.' }
                if ($agent.status -in @('active', 'idle')) { break }
                if ($agent.error -or $agent.status -in @('failed', 'deleted') -or [datetime]::UtcNow -ge $deadline) {
                    throw 'ACTION: Native agent did not become active/idle before the deadline. Inspect the existing build and resume read-back.'
                }
                Start-Sleep -Seconds 15
            } while ($true)
            $principal = $agent.instance_identity.principal_id
            $version = [string]$agent.version
            if ($agent.name -ne 'funwithfoundry-rag-agent' -or -not $version -or
                [string]$principal -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
                ($prior.status -eq 'attempting' -and $version -eq $prior.previous_version)) {
                throw 'ACTION: Native read-back lacks the expected name, a new immutable version, or instance_identity.principal_id. Never substitute a blueprint/client/application ID.'
            }
            if ($prior.status -eq 'succeeded' -and ($prior.agent_version -ne $version -or $prior.principal_id -ne $principal)) {
                throw 'ACTION: Agent identity/version drifted from the recorded deployment. Review the live deployment before replacing the local workload record.'
            }
            $toolbox = $metadata.toolbox
            if ($LASTEXITCODE -ne 0 -or -not $toolbox.version.version) { throw 'Toolbox immutable version read-back missing.' }
            $result = @{ status = 'succeeded'; agent_name = 'funwithfoundry-rag-agent'; agent_version = $version
                principal_id = $principal; toolbox_version = $toolbox.version.version }
            $result | ConvertTo-Json | Set-Content $attemptPath -Encoding UTF8
            $result
        }
        catch {
            if ($payload.action -ne 'Native') { throw }
            $message = $_.Exception.Message -replace '(?i)\bBearer\s+[^\s"'',;]+', 'Bearer [REDACTED]'
            $message = $message -replace '(?i)(["'']?(?:access_token|refresh_token|id_token|client_secret|authorization|token|password|api[-_]?key|sig)["'']?\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s,;&]+)', '$1[REDACTED]'
            $message = $message -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[REDACTED]'
            $message = ($message -replace '[\r\n]+', ' ' -replace '^ACTION:\s*', '').Trim()
            if ($message.Length -gt 1024) { $message = $message.Substring(0, 1024) }
            throw "ACTION: Native workflow failed: $message Inspect runner .azure\native-deploy.log and .azure\native-diagnostics. Resume reads the existing attempt; it does not redeploy."
        }
        finally { Pop-Location }
    } @{ source = $runner.source; root = $runner.root; action = $Action }
}

$stageNames = @('Preflight', 'Infrastructure', 'Workload', 'Verify')
if ($ListStages) { $stageNames; return }
if ($WhatIfPreference) {
    foreach ($selected in $stageNames | Where-Object { $Stage -contains $_ }) { $null = $PSCmdlet.ShouldProcess($selected, 'Run accelerator stage') }
    return
}
if ($SubscriptionId -eq [guid]::Empty) { throw 'Specify -SubscriptionId; implicit Azure subscription selection is not supported.' }
if ($env:ARM_USE_OIDC -eq 'true' -or $env:ACTIONS_ID_TOKEN_REQUEST_URL) { throw 'This entrypoint supports local Azure CLI Terraform authentication, not GitHub/OIDC.' }
$root = Split-Path $PSScriptRoot -Parent
$TerraformDir = (Resolve-Path -LiteralPath $TerraformDir).Path
$stateDirectory = Join-Path $root ".azure\$EnvironmentName\accelerator"
$statePath = Join-Path $stateDirectory 'state.json'
$nativeVariablesPath = Join-Path $stateDirectory 'native-agent.auto.tfvars.json'
$sourceFiles = @('azure.yaml', 'toolbox.yaml', 'scripts\Deploy-NativeFoundryAgent.ps1', 'scripts\Initialize-KnowledgeBase.ps1',
    'scripts\jumpbox\Invoke-IngestFunction.ps1', 'scripts\jumpbox\Invoke-EndToEnd.ps1', 'scripts\jumpbox\Test-Ingestion.ps1',
    'src\shared\search-index.json', 'src\foundry_native_agent\.agentignore', 'src\foundry_native_agent\main.py',
    'src\foundry_native_agent\requirements.txt', 'src\foundry_native_agent\requirements.lock',
    'src\hello_world\ask_agent.py', 'src\hello_world\requirements.txt', 'src\hello_world\requirements.lock')
$hashInputs = @($sourceFiles | ForEach-Object { Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256 })
$hashInputs += @('Invoke-Accelerator.ps1', 'Deploy-IngestFunction.ps1', 'Ensure-AgentCapabilityHost.ps1', 'Approve-SharedPrivateLink.ps1',
    'Test-Preflight.ps1', 'Verify-Deployment.ps1', 'Test-PublicDataPlaneRefused.ps1', 'Send-RunnerArtifacts.ps1') | ForEach-Object {
    Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) -Algorithm SHA256
}
$hashInputs += Get-ChildItem -LiteralPath $TerraformDir -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.terraform[\\/]' -and $_.Name -match '\.(tf|tfvars|tfvars\.json)$'
} | Sort-Object FullName | Get-FileHash -Algorithm SHA256
$hashInputs += Get-ChildItem -LiteralPath (Join-Path $root 'src\ingest_func') -File | Sort-Object Name | Get-FileHash -Algorithm SHA256
$sha = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((($hashInputs.Hash -join '|') + "|$PrimaryRegion|$SecondaryRegion|$JumpboxSize")))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
$null = New-Item -ItemType Directory -Path $stateDirectory -Force
$state = @{ version = 1; subscription_id = [string]$SubscriptionId; environment = $EnvironmentName; fingerprint = $fingerprint; steps = @{} }
if (Test-Path -LiteralPath $statePath) {
    $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($saved.subscription_id -ne [string]$SubscriptionId) { throw 'Saved stage state belongs to another subscription.' }
    if ($saved.fingerprint -ne $fingerprint -and $saved.steps.'Workload.Native'.status -in @('running', 'failed')) {
        throw 'Native deployment outcome is unresolved. Reconcile the recorded private-runner attempt before changing source fingerprints.'
    }
    if ($Resume -and $saved.fingerprint -ne $fingerprint) { throw 'Sources or Terraform inputs changed. Run the selected stages without -Resume to review new plans.' }
    if ($saved.fingerprint -eq $fingerprint) {
        foreach ($property in $saved.steps.PSObject.Properties) { $state.steps[$property.Name] = $property.Value }
        $state.workload_fingerprint = $saved.workload_fingerprint
    }
}
$account = Invoke-CheckedCommand 'az' @('account', 'show', '-o', 'json') | ConvertFrom-Json
if ([string]$account.id -ne [string]$SubscriptionId) { throw 'Run az account set explicitly for the selected subscription before invoking the accelerator.' }

foreach ($selected in $stageNames | Where-Object { $Stage -contains $_ }) {
    if (-not $PSCmdlet.ShouldProcess("$EnvironmentName / $SubscriptionId", "Run $selected stage")) { throw "$selected stage declined." }
    switch ($selected) {
        'Preflight' {
            $null = Invoke-StageStep 'Preflight.Checks' {
                foreach ($command in @('az', 'terraform')) { $null = Get-Command $command -ErrorAction Stop }
                $checks = & {
                    . (Join-Path $PSScriptRoot 'Test-Preflight.ps1') -PrimaryRegion $PrimaryRegion -SecondaryRegion $SecondaryRegion -JumpboxSize $JumpboxSize
                    $script:Results.ToArray()
                }
                if (-not @($checks | Where-Object Status -eq 'PASS').Count -or @($checks | Where-Object Status -eq 'FAIL').Count) { throw 'Preflight failed or was inconclusive.' }
                @{ status = 'passed'; warnings = @($checks | Where-Object Status -eq 'WARN' | Select-Object Check, Status) }
            } -Always
        }
        'Infrastructure' {
            if ($state.steps['Preflight.Checks'].status -ne 'succeeded') { throw 'Run Preflight before Infrastructure.' }
            $null = Invoke-StageStep 'Infrastructure.Init' { Invoke-CheckedCommand 'terraform' @("-chdir=$TerraformDir", 'init', '-input=false', '-no-color') | Out-Host; @{ status = 'initialized' } }
            if ($state.steps['Infrastructure.SharedLink'].status -eq 'succeeded') {
                $current = Invoke-CheckedCommand 'terraform' @("-chdir=$TerraformDir", 'output', '-json') | ConvertFrom-Json
                $recordedAccount = $state.steps['Infrastructure.SharedLink'].output.account_id
                if (-not $recordedAccount -or $current.foundry_primary_account_id.value -ne $recordedAccount) {
                    if ($Resume) { throw 'Terraform account identity is missing or changed after teardown. Archive the old stage evidence and run Preflight,Infrastructure without -Resume.' }
                    foreach ($key in @($state.steps.Keys | Where-Object { $_ -like 'Infrastructure.*' -or $_ -like 'Workload.*' -or $_ -like 'Verify.*' })) { $state.steps.Remove($key) }
                    if (Test-Path -LiteralPath $nativeVariablesPath) { Remove-Item -LiteralPath $nativeVariablesPath -Force }
                    $state.workload_fingerprint = $null
                    Save-AcceleratorState
                }
            }
            $null = Invoke-StageStep 'Infrastructure.Account' { Invoke-ReviewedApply 'account' @('-target=module.foundry_primary.azapi_resource.foundry') }
            $null = Invoke-StageStep 'Infrastructure.AccountHost' { & (Join-Path $PSScriptRoot 'Ensure-AgentCapabilityHost.ps1') -TerraformDir $TerraformDir | Out-Host; @{ status = 'ready' } }
            $null = Invoke-StageStep 'Infrastructure.FullGraph' { Invoke-ReviewedApply 'infrastructure' }
            $null = Invoke-StageStep 'Infrastructure.SharedLink' {
                $outputs = Invoke-CheckedCommand 'terraform' @("-chdir=$TerraformDir", 'output', '-json') | ConvertFrom-Json
                $foundryId = $outputs.foundry_primary_account_id.value
                $searchId = "/subscriptions/$SubscriptionId/resourceGroups/$($outputs.resource_groups.value.primary)/providers/Microsoft.Search/searchServices/$($outputs.foundry_primary.value.search)"
                $url = "https://management.azure.com$searchId/sharedPrivateLinkResources/spl-foundry?api-version=2025-05-01"
                $link = Invoke-CheckedCommand 'az' @('rest', '--method', 'get', '--url', $url, '-o', 'json') | ConvertFrom-Json
                if ($link.properties.privateLinkResourceId -ne $foundryId -or $link.properties.groupId -ne 'openai_account') { throw 'Shared link target/group mismatch.' }
                if ($link.properties.status -ne 'Approved') {
                    $connections = Invoke-CheckedCommand 'az' @('rest', '--method', 'get', '--url', "https://management.azure.com$foundryId/privateEndpointConnections?api-version=2025-06-01", '-o', 'json') | ConvertFrom-Json
                    $pending = @($connections.value | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq 'Pending' })
                    if ($pending.Count -ne 1 -or $pending[0].properties.privateLinkServiceConnectionState.description -ne 'Foundry IQ agentic retrieval query planner') {
                        throw 'Shared-link approval is ambiguous or not yet visible. Inspect the exact Search connection and resume; unrelated pending endpoints are never approved.'
                    }
                    $connectionId = [string]$pending[0].id
                    if (-not $connectionId.StartsWith("$foundryId/privateEndpointConnections/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Pending connection ARM scope mismatch.' }
                    if (-not $PSCmdlet.ShouldProcess("$connectionId -> $($pending[0].properties.privateEndpoint.id)", 'Approve the displayed Search planner private connection')) { throw 'Shared-link approval declined.' }
                    $approvalPath = Join-Path $stateDirectory 'shared-link-approval.json'
                    @{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved'; description = 'Approved for Foundry IQ query planner' } } } |
                        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $approvalPath -Encoding UTF8
                    $null = Invoke-CheckedCommand 'az' @('rest', '--method', 'put', '--url', "https://management.azure.com$connectionId`?api-version=2025-06-01", '--body', "@$approvalPath", '-o', 'none')
                }
                $deadline = [datetime]::UtcNow.AddMinutes(15)
                do {
                    $link = Invoke-CheckedCommand 'az' @('rest', '--method', 'get', '--url', $url, '-o', 'json') | ConvertFrom-Json
                    if ($link.properties.status -eq 'Approved' -and $link.properties.provisioningState -eq 'Succeeded') { break }
                    if ($link.properties.provisioningState -eq 'Failed' -or [datetime]::UtcNow -ge $deadline) { throw 'Shared link did not become ready.' }
                    Start-Sleep -Seconds 15
                } while ($true)
                @{ status = 'approved'; group_id = 'openai_account'; account_id = $foundryId; search_id = $searchId }
            }
        }
        { $_ -in @('Workload', 'Verify') } {
            if ($state.steps['Infrastructure.SharedLink'].status -ne 'succeeded') { throw 'Complete Infrastructure before Workload or Verify.' }
            $manifest = Get-DeploymentManifest
            if (-not $ToolManifestPath) { throw 'Specify -ToolManifestPath with verified azd/uv/Python artifacts and all eight pinned Foundry extension versions. Generate it with scripts/Get-RunnerToolManifest.ps1.' }
            $pins = Get-Content -LiteralPath $ToolManifestPath -Raw | ConvertFrom-Json
            if ($pins.schemaVersion -ne 1 -or $pins.platform -ne 'windows/amd64' -or $pins.artifactDirectory -ne 'runner-tool-cache') { throw 'Use a schemaVersion 1 Windows x64 manifest from Get-RunnerToolManifest.ps1 with its adjacent runner-tool-cache.' }
            $tools = [pscustomobject]@{
                azd = $pins.azd | Select-Object version, sha256, binarySha256, bytes, fileName, url, officialDigest,
                    @{ Name = 'authenticode'; Expression = { $_.authenticode | Select-Object status, subject, thumbprint } }
                uv = $pins.uv | Select-Object version, sha256, binarySha256, bytes, fileName, url, officialDigest
                python = $pins.python | Select-Object version, sha256, bytes, fileName, url, officialDigest, checksumUrl,
                    @{ Name = 'authenticode'; Expression = { $_.authenticode | Select-Object status, subject, thumbprint } }
                pythonVersion = $pins.pythonVersion
                extensions = @($pins.extensions | Select-Object id, version, sha256, bytes, fileName, entryPoint, dependencies, providers)
                extensionBundle = $pins.extensionBundle | Select-Object fileName, sha256, bytes
            }
            foreach ($tool in @('azd', 'uv')) {
                $pin = $tools.$tool
                if ($pin.version -notmatch '^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$' -or
                    $pin.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $pin.binarySha256 -notmatch '^[0-9a-fA-F]{64}$' -or
                    [string]$pin.bytes -notmatch '^[1-9]\d*$' -or $pin.officialDigest -ne "sha256:$($pin.sha256)") { throw "Invalid verified release pin for $tool." }
                $fileName = if ($tool -eq 'azd') { "azd-$($pin.version).msi" } else { "uv-$($pin.version).zip" }
                $url = if ($tool -eq 'azd') { "https://azuresdkartifacts.z5.web.core.windows.net/azd/standalone/release/$($pin.version)/azd-windows-amd64.msi" }
                    else { "https://github.com/astral-sh/uv/releases/download/$($pin.version)/uv-x86_64-pc-windows-msvc.zip" }
                if ($pin.fileName -cne $fileName -or $pin.url -cne $url) { throw "Noncanonical artifact file or official URL for $tool." }
            }
            if ($tools.azd.authenticode.status -ne 'Valid' -or $tools.azd.authenticode.subject -notmatch 'O=Microsoft Corporation(?:,|$)' -or
                $tools.azd.authenticode.thumbprint -notmatch '^[a-fA-F0-9]{40}$') { throw 'Manifest requires verified Microsoft azd MSI Authenticode.' }
            if ($tools.extensionBundle.fileName -cne 'foundry-extensions.zip' -or $tools.extensionBundle.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
                [string]$tools.extensionBundle.bytes -notmatch '^[1-9]\d*$') { throw 'Manifest requires a verified local Foundry extension bundle.' }
            $pythonPin = $tools.python
            if ($tools.pythonVersion -notmatch '^3\.\d+\.\d+$' -or $pythonPin.version -cne $tools.pythonVersion -or
                $pythonPin.fileName -cne "python-$($pythonPin.version)-amd64.exe" -or
                $pythonPin.url -cne "https://www.python.org/ftp/python/$($pythonPin.version)/python-$($pythonPin.version)-amd64.exe" -or
                $pythonPin.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$pythonPin.bytes -notmatch '^[1-9]\d*$' -or
                $pythonPin.officialDigest -cne "sha256:$($pythonPin.sha256)" -or $pythonPin.checksumUrl -cne "$($pythonPin.url).sigstore") { throw 'Manifest requires the exact official Python Windows x64 full installer and published SHA256.' }
            if ($pythonPin.authenticode.status -ne 'Valid' -or $pythonPin.authenticode.subject -notmatch '(?:^|,\s*)O=Python Software Foundation(?:,|$)' -or
                $pythonPin.authenticode.thumbprint -notmatch '^[a-fA-F0-9]{40}$') { throw 'Manifest requires verified Python Software Foundation installer Authenticode.' }
            foreach ($id in @('azure.ai.inspector', 'azure.ai.projects', 'azure.ai.connections', 'azure.ai.toolboxes', 'azure.ai.routines', 'azure.ai.skills', 'azure.ai.agents', 'microsoft.foundry')) {
                $pin = @($tools.extensions | Where-Object id -eq $id)
                if ($pin.Count -ne 1 -or $pin[0].version -notmatch '^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$') { throw "Pin exactly one official extension version for $id." }
                if ($id -ne 'microsoft.foundry' -and ($pin[0].fileName -cne "$id-$($pin[0].version).zip" -or
                    $pin[0].sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]$pin[0].bytes -notmatch '^[1-9]\d*$')) { throw "Missing verified offline extension artifact for $id." }
                foreach ($dependency in $pin[0].dependencies) {
                    if ($dependency.id -notin $tools.extensions.id) { throw "Unpinned extension dependency: $($dependency.id)." }
                }
            }
            if (@($tools.extensions).Count -ne 8) { throw 'Exactly the eight required Foundry extension pins are accepted, including microsoft.foundry, routines, and skills.' }
            $projectPin = $tools.extensions | Where-Object id -eq 'azure.ai.projects'
            if (@($projectPin.providers | Where-Object { $_.name -eq 'microsoft.foundry' -and $_.type -eq 'provisioning-provider' }).Count -ne 1) { throw 'azure.ai.projects must supply the microsoft.foundry provisioning provider.' }
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $binding = [ordered]@{ source = $fingerprint; manifest = $manifest; tools = $tools } | ConvertTo-Json -Depth 20 -Compress
                $workloadFingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($binding))).Replace('-', '').ToLowerInvariant()
            }
            finally { $sha.Dispose() }
            if ($state.workload_fingerprint -and $state.workload_fingerprint -ne $workloadFingerprint) {
                if ($Resume) { throw 'Planner, tool pins, or deployed output identities changed. Run Workload without -Resume to review the changed binding.' }
                foreach ($key in @($state.steps.Keys | Where-Object { $_ -like 'Workload.*' -or $_ -like 'Verify.*' })) { $state.steps.Remove($key) }
            }
            $state.workload_fingerprint = $workloadFingerprint
            Save-AcceleratorState
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $stateDirectory 'deployment-manifest.json') -Encoding UTF8
            $runner = Invoke-StageStep 'Workload.Transfer' { Send-RunnerSource }
            $null = Invoke-StageStep 'Workload.Artifacts' {
                & (Join-Path $PSScriptRoot 'Send-RunnerArtifacts.ps1') -SubscriptionId $SubscriptionId -TerraformDir $TerraformDir -EnvironmentName $EnvironmentName -ToolManifestPath $ToolManifestPath
            } -Always
            $null = Invoke-StageStep 'Workload.Tools' { Initialize-RunnerTools }
            if ($selected -eq 'Workload') {
                $null = Invoke-StageStep 'Workload.Knowledge' { Invoke-RunnerWorkload 'Knowledge' }
                $null = Invoke-StageStep 'Workload.Function' { & (Join-Path $PSScriptRoot 'Deploy-IngestFunction.ps1') -TerraformDir $TerraformDir -Confirm:$false }
                $native = Invoke-StageStep 'Workload.Native' { Invoke-RunnerWorkload 'Native' }
                if ([string]$native.principal_id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Native deployment returned no valid principal ID.' }
                $null = Invoke-StageStep 'Workload.RuntimeRbac' {
                    @{ native_agent_principal_id = $native.principal_id } | ConvertTo-Json | Set-Content -LiteralPath $nativeVariablesPath -Encoding UTF8
                    Invoke-ReviewedApply 'native-runtime-rbac'
                }
            }
            else {
                if ($state.steps['Workload.RuntimeRbac'].status -ne 'succeeded') { throw 'Complete Workload runtime RBAC before Verify.' }
                $null = Invoke-StageStep 'Verify.ControlPlane' { & (Join-Path $PSScriptRoot 'Verify-Deployment.ps1') -TerraformDir $TerraformDir }
                $null = Invoke-StageStep 'Verify.PrivateWorkflow' { Invoke-RunnerWorkload 'Verify' } -Always
                $null = Invoke-StageStep 'Verify.PublicDenial' { & (Join-Path $PSScriptRoot 'Test-PublicDataPlaneRefused.ps1') -TerraformDir $TerraformDir } -Always
            }
        }
    }
}
[pscustomobject]@{ status = 'succeeded'; stages = $Stage; state_path = $statePath; native_variables_path = $nativeVariablesPath }
