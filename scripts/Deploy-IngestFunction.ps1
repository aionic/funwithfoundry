<#
.SYNOPSIS
    Deploy the ingest function to its private SCM endpoint, via the jumpbox.
.DESCRIPTION
    The function app has public network access disabled, so its SCM endpoint is only
    reachable from inside the VNet. This zips src/ingest_func, embeds it as base64 in a
    jumpbox script, and pushes it with the jumpbox managed identity.

    RemoteBuild=true installs the hash-locked dependencies server-side from a
    packaged copy of the full lock. Source requirements and locks are unchanged.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\src\ingest_func'),
    [ValidateRange(1, 45)][int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'

$lab = & (Join-Path $PSScriptRoot 'Get-LabEnvironment.ps1') -TerraformDir $TerraformDir

Push-Location $TerraformDir
try {
    $fn = terraform output -json ingest_function | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $fn.name) { throw 'Function Terraform output is unavailable.' }
}
finally {
    Pop-Location
}

if (-not $PSCmdlet.ShouldProcess($fn.name, 'Deploy private Function package, wait for build, and synchronize triggers')) { return }

$zip = Join-Path $env:TEMP ("ingest-$([guid]::NewGuid().ToString('N')).zip")
$packageFiles = @(Get-ChildItem -LiteralPath $SourceDir -File | Where-Object { $_.Extension -eq '.py' -or $_.Name -in @('host.json', 'requirements.txt', 'requirements.lock') })
foreach ($required in @('function_app.py', 'host.json', 'requirements.txt', 'requirements.lock')) {
    if ($packageFiles.Name -notcontains $required) { throw "Function package is missing $required." }
}
try {
    Compress-Archive -LiteralPath $packageFiles.FullName -DestinationPath $zip -Force
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $requirementsStream = $archive.GetEntry('requirements.txt').Open()
        try {
            $requirementsStream.SetLength(0)
            $lockedRequirements = [IO.File]::ReadAllBytes((Join-Path $SourceDir 'requirements.lock'))
            $requirementsStream.Write($lockedRequirements, 0, $lockedRequirements.Length)
        }
        finally { $requirementsStream.Dispose() }
    }
    finally { $archive.Dispose() }
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zip))
    $packageHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
}
finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }

# Flex Consumption injects a legacy connection-string setting at creation even when
# identity-based host storage is configured. Shared-key access is disabled here, and
# the exact setting overrides AzureWebJobsStorage__*, preventing trigger sync.
az functionapp config appsettings delete `
    --subscription $lab.SubscriptionId `
    --resource-group $lab.ResourceGroups.Secondary `
    --name $fn.name `
    --setting-names AzureWebJobsStorage `
    --output none
if ($LASTEXITCODE -ne 0) { throw 'Failed to remove the legacy AzureWebJobsStorage setting.' }

az functionapp restart --subscription $lab.SubscriptionId --resource-group $lab.ResourceGroups.Secondary --name $fn.name
if ($LASTEXITCODE -ne 0) { throw 'Failed to restart the function app.' }

Write-Host "Deploying package SHA256 $packageHash -> $($fn.name)" -ForegroundColor Cyan
$marker = 'FWF_FUNCTION_' + [guid]::NewGuid().ToString('N') + '='

$remote = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$completion = @{ status = 'failed'; reason = 'private_publish_or_build_failed' }
`$b64 = '$b64'
`$zipPath = Join-Path `$env:TEMP 'ingest-$([guid]::NewGuid().ToString('N')).zip'
`$headers = @{}
try {
    [System.IO.File]::WriteAllBytes(`$zipPath, [Convert]::FromBase64String(`$b64))
    if ((Get-FileHash -LiteralPath `$zipPath -Algorithm SHA256).Hash -ne '$packageHash') { throw 'Package hash mismatch.' }
    `$uri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/'
    `$token = (Invoke-RestMethod -Uri `$uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
    if (-not `$token) { throw 'No managed identity token.' }
    `$headers.Authorization = "Bearer `$token"
    `$scm = 'https://$($fn.name).scm.azurewebsites.net/api/publish?RemoteBuild=true'
    `$attemptDirectory = Join-Path `$env:ProgramData 'FunWithFoundry\function-deployments\$($fn.name)'
    `$null = New-Item -ItemType Directory -Path `$attemptDirectory -Force
    `$attemptPath = Join-Path `$attemptDirectory '$packageHash.json'
    `$location = `$null
    if (Test-Path -LiteralPath `$attemptPath) {
        `$attempt = Get-Content -LiteralPath `$attemptPath -Raw | ConvertFrom-Json
        `$location = `$attempt.status_url
        `$completion.reason = 'previous_publish_outcome_unknown_inspect_scm_history'
    }
    else {
        @{ status = 'attempting' } | ConvertTo-Json | Set-Content -LiteralPath `$attemptPath -Encoding UTF8
        `$r = Invoke-WebRequest -Uri `$scm -Method Post ``
            -Headers `$headers -ContentType 'application/zip' ``
            -InFile `$zipPath -TimeoutSec 600 -MaximumRedirection 0 -UseBasicParsing
        `$location = [string]`$r.Headers['Location']
        if (-not `$location -and `$r.Content) {
            `$publish = `$r.Content | ConvertFrom-Json
            if (`$publish.id) { `$location = "/api/deployments/`$(`$publish.id)" }
        }
        `$completion.reason = 'publish_returned_no_deployment_status_url'
    }
    if (-not `$location) { throw 'Publish returned no deployment-specific status URL; inspect SCM deployment history before retrying.' }
    `$pollUri = [uri]::new([uri]`$scm, `$location)
    if (`$pollUri.Scheme -ne 'https' -or `$pollUri.Host -ne '$($fn.name).scm.azurewebsites.net' -or
        `$pollUri.AbsolutePath -notmatch '^/api/deployments/[a-zA-Z0-9-]+$' -or `$pollUri.AbsolutePath -eq '/api/deployments/latest' -or `$pollUri.UserInfo -or `$pollUri.Query) {
        throw 'Unrecognized deployment status URL.'
    }
    @{ status_url = `$pollUri.AbsoluteUri } | ConvertTo-Json | Set-Content -LiteralPath `$attemptPath -Encoding UTF8
    `$completion.reason = 'remote_build_failed_or_timed_out'
    `$deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        `$deployment = Invoke-RestMethod -Uri `$pollUri -Headers `$headers -TimeoutSec 60 -MaximumRedirection 0
        if (`$deployment.status -eq 3) { throw 'Remote build failed.' }
        if (`$deployment.status -eq 4 -and `$deployment.complete -eq `$true -and `$deployment.id -eq (`$pollUri.AbsolutePath -split '/')[-1]) { break }
        if ([datetime]::UtcNow -ge `$deadline) { throw 'Remote build deadline exceeded.' }
        Start-Sleep -Seconds 10
    } while (`$true)
    `$completion = @{ status = 'succeeded'; deployment_id = `$deployment.id; package_sha256 = '$packageHash'; build = 'completed' }
}
catch { `$completion.status = 'failed' }
finally {
    `$headers.Clear()
    `$token = `$null
    Remove-Item -LiteralPath `$zipPath -Force -ErrorAction SilentlyContinue
    Write-Output ('$marker' + (`$completion | ConvertTo-Json -Compress))
}
"@

$tmp = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $tmp -Value $remote -Encoding UTF8
    $raw = az vm run-command invoke --subscription $lab.SubscriptionId `
        --resource-group $lab.ResourceGroups.Primary --name $lab.Jumpbox.name `
        --command-id RunPowerShellScript --scripts "@$tmp" -o json
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Run Command outcome unknown. Inspect Function SCM deployment history before retrying.' }
    $envelope = $raw | ConvertFrom-Json
    if (-not $envelope.value -or @($envelope.value | Where-Object { $_.code -notmatch '/succeeded$' -or $_.level -eq 'Error' }).Count) {
        throw 'Function Run Command did not complete successfully.'
    }
    if (@($envelope.value | Where-Object { $_.code -match '/StdErr/' -and -not [string]::IsNullOrWhiteSpace($_.message) }).Count) { throw 'Function Run Command reported stderr.' }
    $text = ($envelope.value.message -join "`n")
    if ($text -match '(?s)\[stderr\](.*)$' -and -not [string]::IsNullOrWhiteSpace($Matches[1])) { throw 'Function Run Command reported stderr.' }
    $sentinels = [regex]::Matches($text, '(?m)^' + [regex]::Escape($marker) + '(\{[^\r\n]+\})\r?$')
    if ($sentinels.Count -ne 1) { throw 'Missing Function completion marker. Inspect SCM build status before retrying.' }
    $completion = $sentinels[0].Groups[1].Value | ConvertFrom-Json
    if ($completion.status -ne 'succeeded' -or -not $completion.deployment_id -or $completion.build -ne 'completed') {
        throw "Function publish/build failed ($($completion.reason)). Check private SCM access, managed-identity RBAC and deployment logs; trigger synchronization was not attempted."
    }
    $siteUrl = "https://management.azure.com/subscriptions/$($lab.SubscriptionId)/resourceGroups/$($lab.ResourceGroups.Secondary)/providers/Microsoft.Web/sites/$($fn.name)"
    az rest --method post --url "$siteUrl/syncfunctiontriggers?api-version=2024-04-01" --output none
    if ($LASTEXITCODE -ne 0) { throw 'Function trigger synchronization failed.' }
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        $raw = az rest --method get --url "$siteUrl/functions?api-version=2024-04-01" -o json
        if ($LASTEXITCODE -ne 0) { throw 'Unable to read the Function trigger manifest.' }
        $manifest = $raw | ConvertFrom-Json
        $ingest = @($manifest.value | Where-Object { $_.name -match '/ingest$' })
        $triggers = @($ingest | ForEach-Object { $_.properties.config.bindings } | Where-Object {
            $_.type -eq 'httpTrigger' -and $_.route -eq 'ingest' -and $_.methods -contains 'POST'
        })
        if ($triggers.Count -eq 1) { break }
        if ([datetime]::UtcNow -ge $deadline) { throw 'Build completed but the ingest HTTP trigger is missing. Check Function import/startup logs.' }
        Start-Sleep -Seconds 10
    } while ($true)
    [pscustomobject]@{
        status = 'succeeded'
        function_name = $fn.name
        package_sha256 = $packageHash
        deployment_id = $completion.deployment_id
        build = 'completed'
        trigger = 'ingest'
        invocation = 'not_tested'
    }
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
