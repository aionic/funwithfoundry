<#
.SYNOPSIS
    Download and verify official Windows runner tools locally, without Azure calls.
.DESCRIPTION
    Requires PowerShell 7, Node.js with fetch, and an existing azd/uv installation.
    Does not install software, authenticate, or change cloud resources. Downloads
    stay beside the ignored manifest. TLS verification is never disabled.
    Tests extension installation in a disposable AZD_CONFIG_DIR using the verified
    portable azd build. The user's installed extensions and login cache are not copied.
    Copy the generated runner-tool-cache directory to the VM's
    C:\ProgramData\FunWithFoundry\<environment>\tool-artifacts before Workload.
    This is bulk transport, not thousands of 12 KB VM Run Command calls.
    Bundles the official full Python Windows x64 installer, verified against its
    published SHA256 and PSF Authenticode. Workload dependencies still need PyPI
    egress or a prepared wheelhouse. No Python installer is executed locally.
.EXAMPLE
    .\scripts\Get-RunnerToolManifest.ps1 -PythonVersion 3.13.7
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.azure\runner-tools.json'),
    [ValidatePattern('^3\.\d+\.\d+$')][string]$PythonVersion = '3.13.7'
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $IsWindows) { throw 'Use PowerShell 7 on Windows for Authenticode and read-only MSI inspection.' }
$null = Get-Command node -ErrorAction Stop
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$cache = Join-Path (Split-Path $OutputPath -Parent) 'runner-tool-cache'
$null = New-Item -ItemType Directory -Path $cache -Force

function Get-OfficialArtifact {
  param([string]$Url, [string]$Name, [string]$ExpectedSha256)
  Write-Verbose "Verifying official download: $Name"
    $destination = Join-Path $cache $Name
  if ($ExpectedSha256 -match '^[a-fA-F0-9]{64}$' -and (Test-Path -LiteralPath $destination) -and
    (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $ExpectedSha256) {
    return [pscustomobject]@{
      url = $Url; path = $destination; sha256 = $ExpectedSha256.ToLowerInvariant()
      bytes = (Get-Item -LiteralPath $destination).Length
      downloadedAtUtc = (Get-Item -LiteralPath $destination).LastWriteTimeUtc.ToString('o')
      retrieval = 'cache rehashed against freshly retrieved official digest'
    }
  }
    $downloadScript = @'
const fs = require('node:fs');
const {Readable} = require('node:stream');
const {pipeline} = require('node:stream/promises');
const [initialUrl, destination] = process.argv.slice(1);
const allowed = new Set(['raw.githubusercontent.com', 'api.github.com', 'github.com',
  'release-assets.githubusercontent.com', 'objects.githubusercontent.com',
  'azuresdkartifacts.z5.web.core.windows.net', 'www.python.org']);
(async () => {
  if (process.env.NODE_TLS_REJECT_UNAUTHORIZED === '0') throw new Error('Insecure Node TLS configuration is forbidden');
  let url = initialUrl;
  const redirects = [];
  for (let count = 0; count < 10; count++) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || !allowed.has(parsed.hostname) || parsed.username || parsed.password)
      throw new Error('Non-official HTTPS URL: ' + parsed.origin);
    const response = await fetch(url, {redirect: 'manual', signal: AbortSignal.timeout(300000)});
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      redirects.push(parsed.hostname);
      url = new URL(response.headers.get('location'), url).href;
      await response.body?.cancel();
      continue;
    }
    if (!response.ok) throw new Error('HTTP ' + response.status + ': ' + initialUrl);
    await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(destination + '.partial'));
    fs.renameSync(destination + '.partial', destination);
    console.log(JSON.stringify({url: initialUrl, finalHost: parsed.hostname, redirectHosts: redirects,
      downloadedAtUtc: new Date().toISOString(), bytes: fs.statSync(destination).size}));
    return;
  }
  throw new Error('Too many redirects');
})().catch(error => { fs.rmSync(destination + '.partial', {force: true}); console.error(error.message); process.exitCode = 1; });
'@
    $result = & node -e $downloadScript $Url $destination
    if ($LASTEXITCODE -ne 0) { throw "Official download failed: $Url" }
    $receipt = $result | ConvertFrom-Json
    $receipt | Add-Member -NotePropertyName path -NotePropertyValue $destination
    $receipt | Add-Member -NotePropertyName sha256 -NotePropertyValue (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt
}

function Read-MsiTable {
    param($Database, [string]$Query, [string[]]$Columns)
    $view = $Database.OpenView($Query)
    try {
        $null = $view.Execute()
        while ($record = $view.Fetch()) {
            $row = [ordered]@{}
            for ($index = 0; $index -lt $Columns.Count; $index++) { $row[$Columns[$index]] = $record.StringData($index + 1) }
            [pscustomobject]$row
        }
    }
    finally { $null = $view.Close() }
}

$azdText = (& azd version) -join ' '
if ($LASTEXITCODE -ne 0 -or $azdText -notmatch 'azd version (\d+\.\d+\.\d+)(?: |$)') { throw "Cannot identify installed azd version: $azdText" }
$azdVersion = $Matches[1]
$uvText = (& uv --version) -join ' '
if ($LASTEXITCODE -ne 0 -or $uvText -notmatch '^uv (\d+\.\d+\.\d+)(?: |$)') { throw "Cannot identify installed uv version: $uvText" }
$uvVersion = $Matches[1]
$installerSource = Get-OfficialArtifact 'https://raw.githubusercontent.com/Azure/azure-dev/main/cli/installer/install-azd.ps1' 'install-azd.source.ps1'
$installerText = Get-Content -LiteralPath $installerSource.path -Raw
if ($installerText -notmatch 'https://azuresdkartifacts\.z5\.web\.core\.windows\.net/azd/standalone/release' -or
    $installerText -notmatch 'azd-windows-amd64\.msi') { throw 'Official installer source changed; review its release URL before updating this provider.' }
$azdRelease = Get-OfficialArtifact "https://api.github.com/repos/Azure/azure-dev/releases/tags/azure-dev-cli_$azdVersion" "azd-$azdVersion-release.json"
$azdReleaseData = Get-Content -LiteralPath $azdRelease.path -Raw | ConvertFrom-Json
$msiAsset = @($azdReleaseData.assets | Where-Object name -eq 'azd-windows-amd64.msi')
if ($msiAsset.Count -ne 1 -or $msiAsset[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Official azd MSI release digest is missing.' }
$msi = Get-OfficialArtifact "https://azuresdkartifacts.z5.web.core.windows.net/azd/standalone/release/$azdVersion/azd-windows-amd64.msi" "azd-$azdVersion.msi" $msiAsset[0].digest.Substring(7)
$signature = Get-AuthenticodeSignature -LiteralPath $msi.path
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'azd MSI does not have valid Microsoft Authenticode.' }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($msi.path, 0)
$properties = @(Read-MsiTable $database 'SELECT `Property`, `Value` FROM `Property`' @('property', 'value'))
$directories = @(Read-MsiTable $database 'SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`' @('id', 'parent', 'default'))
$environment = @(Read-MsiTable $database 'SELECT `Name`, `Value`, `Component_` FROM `Environment`' @('name', 'value', 'component'))
$components = @(Read-MsiTable $database 'SELECT `Component`, `Condition` FROM `Component`' @('id', 'condition'))
if (@($properties | Where-Object { $_.property -eq 'WIXUI_INSTALLDIR' -and $_.value -eq 'INSTALLDIR' }).Count -ne 1 -or
  @($directories | Where-Object id -eq 'INSTALLDIR').Count -ne 1 -or
  @($environment | Where-Object { $_.name -eq '=-*PATH' -and $_.value -eq '[~];[INSTALLDIR]' }).Count -ne 1) { throw 'MSI installation/PATH contract changed; inspect the signed package.' }
if ($msiAsset.Count -ne 1 -or $msiAsset[0].digest -ne "sha256:$($msi.sha256)") { throw 'azd MSI does not match the official GitHub release digest.' }
$portableAsset = @($azdReleaseData.assets | Where-Object name -eq 'azd-windows-amd64.zip')
if ($portableAsset.Count -ne 1) { throw 'Official portable azd release missing.' }
$portable = Get-OfficialArtifact $portableAsset[0].browser_download_url "azd-$azdVersion.zip" $portableAsset[0].digest.Substring(7)
if ($portableAsset[0].digest -ne "sha256:$($portable.sha256)") { throw 'Portable azd official digest mismatch.' }
$release = Get-OfficialArtifact "https://api.github.com/repos/astral-sh/uv/releases/tags/$uvVersion" "uv-$uvVersion-release.json"
$releaseData = Get-Content -LiteralPath $release.path -Raw | ConvertFrom-Json
$uvAsset = @($releaseData.assets | Where-Object name -eq 'uv-x86_64-pc-windows-msvc.zip')
if ($uvAsset.Count -ne 1) { throw 'Official uv Windows x64 release asset missing or ambiguous.' }
$uvArchive = Get-OfficialArtifact $uvAsset[0].browser_download_url "uv-$uvVersion.zip" $uvAsset[0].digest.Substring(7)
$sidecar = Get-OfficialArtifact "$($uvAsset[0].browser_download_url).sha256" "uv-$uvVersion.zip.sha256"
$sidecarText = (Get-Content -LiteralPath $sidecar.path -Raw).Trim()
if ($sidecarText -notmatch '^([a-fA-F0-9]{64})\s+\*?uv-x86_64-pc-windows-msvc\.zip$' -or $Matches[1] -ne $uvArchive.sha256) { throw 'uv official checksum sidecar mismatch.' }
if ($uvAsset[0].digest -and $uvAsset[0].digest -ne "sha256:$($uvArchive.sha256)") { throw 'uv GitHub release digest mismatch.' }
$pythonUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
$pythonChecksum = Get-OfficialArtifact "$pythonUrl.sigstore" "python-$PythonVersion-amd64.exe.sigstore"
$pythonMetadata = Get-Content -LiteralPath $pythonChecksum.path -Raw | ConvertFrom-Json
if ($pythonMetadata.messageSignature.messageDigest.algorithm -cne 'SHA2_256') { throw 'Official Python installer SHA256 is missing from its published Sigstore sidecar.' }
$pythonDigestBytes = [Convert]::FromBase64String($pythonMetadata.messageSignature.messageDigest.digest)
if ($pythonDigestBytes.Length -ne 32) { throw 'Invalid published Python installer SHA256.' }
$pythonDigest = [BitConverter]::ToString($pythonDigestBytes).Replace('-', '').ToLowerInvariant()
$pythonInstaller = Get-OfficialArtifact $pythonUrl "python-$PythonVersion-amd64.exe" $pythonDigest
if ($pythonInstaller.sha256 -ne $pythonDigest) { throw 'Python installer does not match the official published SHA256.' }
$pythonSignature = Get-AuthenticodeSignature -LiteralPath $pythonInstaller.path
if ($pythonSignature.Status -ne 'Valid' -or $pythonSignature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Python Software Foundation(?:,|$)') {
  throw 'Python installer does not have valid Python Software Foundation Authenticode.'
}
$registryReceipt = Get-OfficialArtifact 'https://raw.githubusercontent.com/Azure/azure-dev/refs/heads/main/cli/azd/extensions/registry.json' 'official-extension-registry.json'
$registry = Get-Content -LiteralPath $registryReceipt.path -Raw | ConvertFrom-Json
$installed = & azd extension list --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the installed extension pins.' }
$required = @('azure.ai.inspector', 'azure.ai.projects', 'azure.ai.connections', 'azure.ai.toolboxes', 'azure.ai.routines', 'azure.ai.skills', 'azure.ai.agents', 'microsoft.foundry')
$pins = @()
$bundleEntries = @()
$bundleDirectory = Join-Path $cache 'extension-bundle'
$null = New-Item -ItemType Directory -Path $bundleDirectory -Force
foreach ($id in $required) {
  $local = @($installed | Where-Object id -eq $id)
  if ($local.Count -ne 1 -or -not $local[0].installedVersion) { throw "Install and test $id locally before generating a pin; latest is never substituted." }
  $entry = @($registry.extensions | Where-Object id -eq $id)
  $version = @($entry.versions | Where-Object version -eq $local[0].installedVersion)
  if ($entry.Count -ne 1 -or $version.Count -ne 1) { throw "Installed $id version is absent from Microsoft's current registry." }
  $selected = $version[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json
  $pin = [ordered]@{
    id = $id; version = $selected.version; namespace = $entry[0].namespace
    requiredAzdVersion = $selected.requiredAzdVersion
    dependencies = @($selected.dependencies | Where-Object { $null -ne $_ })
    providers = @($selected.providers | Where-Object { $null -ne $_ })
  }
  if ($id -ne 'microsoft.foundry') {
    $artifact = $selected.artifacts.'windows/amd64'
    if ($artifact.checksum.algorithm -ne 'sha256' -or $artifact.checksum.value -notmatch '^[a-fA-F0-9]{64}$' -or
      $artifact.url -notlike 'https://github.com/Azure/azure-dev/releases/download/*') { throw "No official Windows x64 SHA256 artifact for $id." }
    $download = Get-OfficialArtifact $artifact.url "$id-$($pin.version).zip" $artifact.checksum.value
    if ($download.sha256 -ne $artifact.checksum.value) { throw "Official extension checksum mismatch: $id" }
    $fileName = [IO.Path]::GetFileName($download.path)
    Copy-Item -LiteralPath $download.path -Destination (Join-Path $bundleDirectory $fileName) -Force
    $pin.url = $download.url
    $pin.sha256 = $download.sha256
    $pin.bytes = $download.bytes
    $pin.fileName = $fileName
    $pin.entryPoint = $artifact.entryPoint
    $pin.downloadedAtUtc = $download.downloadedAtUtc
    $artifact.url = $fileName
    $selected.artifacts = [pscustomobject]@{ 'windows/amd64' = $artifact }
  }
  $bundleEntries += [pscustomobject]@{
    id = $id; namespace = $entry[0].namespace; displayName = $entry[0].displayName
    description = $entry[0].description; versions = @($selected)
  }
  $pins += [pscustomobject]$pin
}
foreach ($pin in $pins) {
  foreach ($dependency in $pin.dependencies) {
    if ($dependency.id -notin $required) { throw "New dependency $($dependency.id) requires explicit review before expanding the bundle." }
  }
}
$projectPin = $pins | Where-Object id -eq 'azure.ai.projects'
if (@($projectPin.providers | Where-Object { $_.name -eq 'microsoft.foundry' -and $_.type -eq 'provisioning-provider' }).Count -ne 1) { throw 'azure.ai.projects does not supply the required microsoft.foundry provisioning provider.' }
$bundleRegistry = [ordered]@{ extensions = $bundleEntries }
if ($registry.schemaVersion) { $bundleRegistry.schemaVersion = $registry.schemaVersion }
$bundleRegistry | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $bundleDirectory 'registry.json') -Encoding utf8NoBOM
$bundlePath = Join-Path $cache 'foundry-extensions.zip'
if (Test-Path -LiteralPath $bundlePath) { Remove-Item -LiteralPath $bundlePath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($bundlePath, [IO.Compression.ZipArchiveMode]::Create)
try {
  $bundleFiles = @('registry.json') + @($pins | Where-Object fileName | Select-Object -ExpandProperty fileName)
  foreach ($fileName in ($bundleFiles | Sort-Object)) {
    $entry = $archive.CreateEntry($fileName, [IO.Compression.CompressionLevel]::NoCompression)
    $entry.LastWriteTime = [datetimeoffset]::new(2000, 1, 1, 0, 0, 0, [timespan]::Zero)
    $sourceStream = [IO.File]::OpenRead((Join-Path $bundleDirectory $fileName))
    try {
      $destinationStream = $entry.Open()
      try { $sourceStream.CopyTo($destinationStream) }
      finally { $destinationStream.Dispose() }
    }
    finally { $sourceStream.Dispose() }
  }
}
finally { $archive.Dispose() }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('fwf-tools-' + [guid]::NewGuid().ToString('N'))
$oldConfig = $env:AZD_CONFIG_DIR
$oldTelemetry = $env:AZURE_DEV_COLLECT_TELEMETRY
$oldProxy = $env:HTTPS_PROXY
$oldHttpProxy = $env:HTTP_PROXY
$oldNoProxy = $env:NO_PROXY
try {
  Expand-Archive -LiteralPath $portable.path -DestinationPath (Join-Path $testRoot 'azd')
  Expand-Archive -LiteralPath $uvArchive.path -DestinationPath (Join-Path $testRoot 'uv')
  $azdExecutables = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'azd') -Filter azd-windows-amd64.exe -Recurse)
  $uvExecutables = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'uv') -Filter uv.exe -Recurse)
  if ($azdExecutables.Count -ne 1 -or $uvExecutables.Count -ne 1) { throw 'Unexpected official portable tool archive layout.' }
  $azdExecutable = $azdExecutables[0].FullName
  $portableSignature = Get-AuthenticodeSignature -LiteralPath $azdExecutable
  if ($portableSignature.Status -ne 'Valid' -or $portableSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'Portable azd signature verification failed.' }
  $env:AZD_CONFIG_DIR = Join-Path $testRoot 'config'
  $env:AZURE_DEV_COLLECT_TELEMETRY = 'no'
  $env:HTTPS_PROXY = 'http://127.0.0.1:9'
  $env:HTTP_PROXY = 'http://127.0.0.1:9'
  $env:NO_PROXY = ''
  $observedAzd = (& $azdExecutable version) -join ' '
  if ($LASTEXITCODE -ne 0 -or $observedAzd -notmatch "^azd version $([regex]::Escape($azdVersion))(?: |$)") { throw 'Downloaded azd binary version mismatch.' }
  $observedUv = (& $uvExecutables[0].FullName --version) -join ' '
  if ($LASTEXITCODE -ne 0 -or $observedUv -notmatch "^uv $([regex]::Escape($uvVersion))(?: |$)") { throw 'Downloaded uv binary version mismatch.' }
  Write-Verbose 'Testing dependency-enabled bundle installation in an isolated azd configuration.'
  $installLog = Join-Path $cache 'offline-install-test.log'
  & $azdExecutable extension install $bundlePath --no-prompt *> $installLog
  if ($LASTEXITCODE -ne 0) { throw "Offline extension installation failed; inspect $installLog. The manifest will not be written." }
  Write-Verbose 'Verifying the eight installed pins and command availability.'
  $observed = & $azdExecutable extension list --installed --output json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'Cannot verify the isolated installed extension set.' }
  foreach ($pin in $pins) {
    $match = @($observed | Where-Object { $_.id -eq $pin.id -and $_.installedVersion -eq $pin.version })
    if ($match.Count -ne 1) { throw "Isolated extension pin mismatch: $($pin.id)" }
  }
  foreach ($arguments in @(@('ai','agent','--help'), @('ai','project','--help'), @('ai','toolbox','--help'), @('env','list','--help'))) {
    $null = & $azdExecutable @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Pinned azd command is unavailable: $($arguments -join ' ')" }
  }
  $azdBinaryHash = (Get-FileHash -LiteralPath $azdExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
  $uvBinaryHash = (Get-FileHash -LiteralPath $uvExecutables[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
finally {
  $env:AZD_CONFIG_DIR = $oldConfig
  $env:AZURE_DEV_COLLECT_TELEMETRY = $oldTelemetry
  $env:HTTPS_PROXY = $oldProxy
  $env:HTTP_PROXY = $oldHttpProxy
  $env:NO_PROXY = $oldNoProxy
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
$manifest = [ordered]@{
  schemaVersion = 1
  verifiedAtUtc = [datetime]::UtcNow.ToString('o')
  platform = 'windows/amd64'
  artifactDirectory = 'runner-tool-cache'
  azd = @{ version = $azdVersion; url = $msi.url; sha256 = $msi.sha256; bytes = $msi.bytes; fileName = [IO.Path]::GetFileName($msi.path); binarySha256 = $azdBinaryHash
    officialDigest = $msiAsset[0].digest; releaseMetadataUrl = $azdRelease.url; downloadedAtUtc = $msi.downloadedAtUtc
    authenticode = @{ status = [string]$signature.Status; subject = $signature.SignerCertificate.Subject; thumbprint = $signature.SignerCertificate.Thumbprint }
    msi = @{ directoryProperty = 'INSTALLDIR'; properties = $properties; directories = $directories; environment = $environment; components = $components
      runnerArguments = @('ALLUSERS=1', 'MSIINSTALLPERUSER=""'); note = 'Default is per-user; VM Run Command installs per-machine as SYSTEM. Refresh process PATH explicitly.' }
    installerSource = @{ url = $installerSource.url; sha256 = $installerSource.sha256; checkedAtUtc = $installerSource.downloadedAtUtc } }
  uv = @{ version = $uvVersion; url = $uvArchive.url; sha256 = $uvArchive.sha256; bytes = $uvArchive.bytes; fileName = [IO.Path]::GetFileName($uvArchive.path); binarySha256 = $uvBinaryHash
    officialDigest = $uvAsset[0].digest; checksumUrl = $sidecar.url; releaseMetadataUrl = $release.url; downloadedAtUtc = $uvArchive.downloadedAtUtc }
  python = @{ version = $PythonVersion; url = $pythonInstaller.url; sha256 = $pythonInstaller.sha256; bytes = $pythonInstaller.bytes; fileName = [IO.Path]::GetFileName($pythonInstaller.path)
    officialDigest = "sha256:$pythonDigest"; checksumUrl = $pythonChecksum.url; checksumSha256 = $pythonChecksum.sha256; downloadedAtUtc = $pythonInstaller.downloadedAtUtc
    authenticode = @{ status = [string]$pythonSignature.Status; subject = $pythonSignature.SignerCertificate.Subject; thumbprint = $pythonSignature.SignerCertificate.Thumbprint }
    checksumVerification = 'SHA256 from official python.org Sigstore sidecar over verified HTTPS; Sigstore signature not verified. Installer Authenticode independently verified against Python Software Foundation.' }
  pythonVersion = $PythonVersion
  pythonReadiness = 'Full Windows x64 installer staged and verified locally; machine installation and runtime version check on the VM are not run. Verify uses the explicit runner Python path with uv --no-python-downloads. Workload packages still need PyPI or a prepared wheelhouse.'
  extensions = $pins
  extensionRegistry = @{ url = $registryReceipt.url; sha256 = $registryReceipt.sha256; checkedAtUtc = $registryReceipt.downloadedAtUtc }
  extensionBundle = @{ fileName = [IO.Path]::GetFileName($bundlePath); sha256 = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = (Get-Item -LiteralPath $bundlePath).Length }
  verification = @{ azd = $observedAzd; uv = $observedUv; python = 'Official published SHA256 and valid PSF Authenticode; installer not executed'; isolatedExtensionInstall = 'passed'; dependencyResolution = 'enabled, exact pins only'; networkDuringExtensionTest = 'HTTP/HTTPS proxies set to unreachable loopback; no Azure calls'; vmInstallation = 'not run' }
  staging = @{ mode = 'bulk-copy'; runnerRelativeDirectory = 'tool-artifacts'; requiredFiles = @([IO.Path]::GetFileName($msi.path), [IO.Path]::GetFileName($uvArchive.path), [IO.Path]::GetFileName($pythonInstaller.path), [IO.Path]::GetFileName($bundlePath))
    totalBytes = $msi.bytes + $uvArchive.bytes + $pythonInstaller.bytes + (Get-Item -LiteralPath $bundlePath).Length
    automaticTransferImplemented = $true
    legacyRunCommandChunks = [int][Math]::Ceiling(($msi.bytes + $uvArchive.bytes + $pythonInstaller.bytes + (Get-Item -LiteralPath $bundlePath).Length) / 12000)
    note = 'Send-RunnerArtifacts transfers these four verified files over the approved private Bastion path before Workload.Tools. Initialize-RunnerTools verifies each hash; it never downloads from the VM or changes firewall rules. Live transport not verified by this generator.' }
  remainingEgress = @('pypi.org and files.pythonhosted.org for workload dependencies unless locally staged', 'Windows Authenticode trust/revocation endpoints or a pre-populated valid trust cache')
}
$temporary = "$OutputPath.tmp"
$manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
Move-Item -LiteralPath $temporary -Destination $OutputPath -Force
[pscustomobject]@{ manifest = $OutputPath; azd = $azdVersion; uv = $uvVersion; extensions = $pins.Count; staging = $manifest.staging; verifiedAtUtc = $manifest.verifiedAtUtc }
