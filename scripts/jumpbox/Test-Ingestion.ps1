[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*\.azurewebsites\.net$')]
    [string]$FunctionHostname,

    [Parameter(Mandatory)]
    [guid]$ApiClientId,

    [guid]$ManagedIdentityClientId,
    [securestring]$AccessToken,
    [securestring]$DeniedAccessToken,
    [switch]$IncludeSharePoint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$action = if ($IncludeSharePoint) { 'Ingest the configured SharePoint document and fixed fixture into staging and Search' } else { 'Ingest the fixed fixture into staging and Search' }
if (-not $PSCmdlet.ShouldProcess($FunctionHostname, $action)) {
    @{ status = 'not_run'; reason = 'should_process_declined' } | ConvertTo-Json -Compress
    return
}

function Invoke-IngestionProbe {
    param([hashtable]$Headers, [hashtable]$Payload)
    $statusCode = 0
    $content = ''
    try {
        $response = Invoke-WebRequest -Uri "https://$FunctionHostname/api/ingest" -Method Post `
            -Headers $Headers -ContentType 'application/json' -Body ($Payload | ConvertTo-Json -Compress) `
            -MaximumRedirection 0 -TimeoutSec 240 -UseBasicParsing
        $statusCode = [int]$response.StatusCode
        $content = $response.Content
    }
    catch {
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
        if ($null -ne $response) {
            $statusCode = [int]$response.StatusCode
            try {
                if ($response -is [System.Net.Http.HttpResponseMessage]) {
                    $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
                else {
                    $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
                    try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            }
            catch { $content = '' }
        }
    }
    $parsed = $null
    try { $parsed = $content | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    return @{ http_status = $statusCode; body = $parsed }
}

function Get-ProbeField {
    param($Body, [string]$Name)
    if ($null -ne $Body -and $Body.PSObject.Properties.Name -contains $Name) {
        return $Body.$Name
    }
    return $null
}

function Add-ProbeResult {
    param([string]$Name, [hashtable]$Probe, [int]$Expected, [switch]$Indexed)
    $passed = $Probe.http_status -eq $Expected
    $requestId = Get-ProbeField $Probe.body 'request_id'
    $documentId = Get-ProbeField $Probe.body 'document_id'
    if ($Indexed) {
        $passed = $passed -and (Get-ProbeField $Probe.body 'status') -eq 'indexed' `
            -and [string]$requestId -match '^[0-9a-f-]{36}$' `
            -and [string]$documentId -match '^[0-9a-f]{64}$' `
            -and [string](Get-ProbeField $Probe.body 'content_hash') -match '^[0-9a-f]{64}$'
    }
    $classification = if ($passed) { 'passed' } elseif ($Probe.http_status -eq 0) { 'inconclusive_network_or_transport' } else { 'failed' }
    $record = @{ check = $Name; status = $classification; http_status = $Probe.http_status }
    if ([string]$requestId -match '^[0-9a-f-]{36}$') { $record.request_id = $requestId }
    if ($Indexed -and [string]$documentId -match '^[0-9a-f]{64}$') { $record.document_id = $documentId }
    $results.Add($record)
}

$results = [System.Collections.Generic.List[object]]::new()
$bearer = $null
$deniedBearer = $null
try {
    if ($AccessToken) {
        $bearer = [System.Net.NetworkCredential]::new('', $AccessToken).Password
    }
    else {
        $resource = [uri]::EscapeDataString("api://$ApiClientId")
        $identityQuery = if ($ManagedIdentityClientId -ne [guid]::Empty) { "&client_id=$ManagedIdentityClientId" } else { '' }
        $identityUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource$identityQuery"
        $identityResponse = Invoke-RestMethod -Uri $identityUri -Headers @{ Metadata = 'true' } -TimeoutSec 15 -MaximumRedirection 0
        $bearer = $identityResponse.access_token
    }
    if ([string]::IsNullOrWhiteSpace($bearer)) { throw 'Token not available' }

    $fixture = @{ mode = 'fixture'; fixtureId = 'accelerator-v1' }
    Add-ProbeResult 'missing_bearer' (Invoke-IngestionProbe @{} $fixture) 401
    Add-ProbeResult 'spoofed_identity_headers' (Invoke-IngestionProbe @{ 'X-MS-CLIENT-PRINCIPAL-ID' = '44444444-4444-4444-8444-444444444444'; 'X-MS-CLIENT-PRINCIPAL' = 'spoofed' } $fixture) 401
    Add-ProbeResult 'invalid_bearer' (Invoke-IngestionProbe @{ Authorization = 'Bearer invalid-token' } $fixture) 401
    $headers = @{ Authorization = "Bearer $bearer" }
    Add-ProbeResult 'source_override_rejected' (Invoke-IngestionProbe $headers @{ mode = 'sharepoint'; filePath = 'elsewhere.pdf' }) 400
    $first = Invoke-IngestionProbe $headers $fixture
    Add-ProbeResult 'fixture_pipeline' $first 200 -Indexed
    $second = Invoke-IngestionProbe $headers $fixture
    Add-ProbeResult 'fixture_rerun' $second 200 -Indexed
    $stable = $first.http_status -eq 200 -and $second.http_status -eq 200 `
        -and (Get-ProbeField $first.body 'document_id') -eq (Get-ProbeField $second.body 'document_id') `
        -and (Get-ProbeField $first.body 'content_hash') -eq (Get-ProbeField $second.body 'content_hash')
    $results.Add(@{ check = 'stable_fixture_identity'; status = $(if ($stable) { 'passed' } else { 'failed' }) })
    if ($DeniedAccessToken) {
        $deniedBearer = [System.Net.NetworkCredential]::new('', $DeniedAccessToken).Password
        Add-ProbeResult 'unapproved_app_denied' (Invoke-IngestionProbe @{ Authorization = "Bearer $deniedBearer" } $fixture) 403
    }
    if ($IncludeSharePoint) {
        Add-ProbeResult 'configured_sharepoint_pipeline' (Invoke-IngestionProbe $headers @{ mode = 'sharepoint' }) 200 -Indexed
    }
    $failed = @($results | Where-Object { $_.status -ne 'passed' }).Count -gt 0
    @{
        status = $(if ($failed) { 'failed' } else { 'passed' })
        checks = $results.ToArray()
        sharepoint = $(if ($IncludeSharePoint) { 'attempted' } else { 'not_tested' })
        unapproved_app = $(if ($DeniedAccessToken) { 'attempted' } else { 'not_tested' })
        public_network_isolation = 'not_tested'
        retrieval = 'not_tested'
    } | ConvertTo-Json -Depth 6 -Compress
    if ($failed) { exit 1 }
}
catch {
    @{ status = 'failed'; reason = 'ingestion_probe_failed'; checks = $results.ToArray() } | ConvertTo-Json -Depth 6 -Compress
    exit 1
}
finally {
    $bearer = $null
    $deniedBearer = $null
    $AccessToken = $null
    $DeniedAccessToken = $null
    if (Get-Variable headers -ErrorAction SilentlyContinue) { $headers.Clear() }
    if (Get-Variable identityResponse -ErrorAction SilentlyContinue) { $identityResponse = $null }
}
