[CmdletBinding()]
param([string] $ArchivePath = (Join-Path $env:TEMP 'funwithfoundry-azure-icons-v24.zip'))

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$destination = Join-Path $root 'docs\diagrams\assets'
$archiveUrl = 'https://arch-center.azureedge.net/icons/Azure_Public_Service_Icons_V24.zip'
$iconNames = @(
    '035746832-icon-service-AI-Foundry.svg',
    '038470497-icon-service-Azure-AI-Foundry-IQ.svg',
    '038470614-icon-service-Foundry-Models.svg',
    '10044-icon-service-Cognitive-Search.svg',
    '10021-icon-service-Virtual-Machine.svg',
    '10029-icon-service-Function-Apps.svg',
    '10121-icon-service-Azure-Cosmos-DB.svg',
    '10245-icon-service-Key-Vaults.svg',
    '10086-icon-service-Storage-Accounts.svg',
    '02579-icon-service-Private-Endpoints.svg',
    '02422-icon-service-Bastions.svg',
    '10084-icon-service-Firewalls.svg',
    '10064-icon-service-DNS-Zones.svg',
    '00427-icon-service-Private-Link.svg'
)

if (-not (Test-Path $ArchivePath)) {
    Invoke-WebRequest -Uri $archiveUrl -OutFile $ArchivePath
}
[void] (New-Item -ItemType Directory -Path $destination -Force)
$archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $assets = foreach ($name in $iconNames) {
        $entry = @($archive.Entries | Where-Object Name -EQ $name | Sort-Object FullName)[0]
        if (-not $entry) { throw "Official icon is missing: $name" }
        $outputPath = Join-Path $destination $name
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $outputPath, $true)
        $originalStream = $entry.Open()
        try {
            $originalHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($originalStream)).ToLowerInvariant()
        } finally { $originalStream.Dispose() }
        $outputHash = (Get-FileHash -Algorithm SHA256 $outputPath).Hash.ToLowerInvariant()
        if ($originalHash -ne $outputHash) { throw "Official icon bytes changed: $name" }
        [ordered]@{ file = "docs/diagrams/assets/$name"; archiveEntry = $entry.FullName; sha256 = $outputHash }
    }
    $manifest = [ordered]@{
        source = 'https://learn.microsoft.com/en-us/azure/architecture/icons/'
        archiveUrl = $archiveUrl
        archiveSha256 = (Get-FileHash -Algorithm SHA256 $ArchivePath).Hash.ToLowerInvariant()
        artwork = 'Original SVG bytes, unmodified. Architectural documentation use only; Microsoft reserves all other rights.'
        assets = @($assets)
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'render-diagrams.assets.json')
    Write-Output "Verified $($assets.Count) original Microsoft SVG assets."
} finally { $archive.Dispose() }
