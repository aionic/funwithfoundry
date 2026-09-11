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

$action = if ($IncludeSharePoint) { 'Stage the configured SharePoint document and fixed fixture' } else { 'Stage the fixed fixture' }
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
            -MaximumRedirection 0 -TimeoutSec 240 -UseBasicParsing -Verbose:$false -Debug:$false
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
    param([string]$Name, [hashtable]$Probe, [int]$Expected, [string]$StagedMode)
    $passed = $Probe.http_status -eq $Expected
    $requestId = Get-ProbeField $Probe.body 'request_id'
    if ($StagedMode) {
        $sourceId = Get-ProbeField $Probe.body 'source_id'
        $blobName = Get-ProbeField $Probe.body 'blob_name'
        $bytes = Get-ProbeField $Probe.body 'bytes'
        $passed = $passed -and $Expected -eq 202 -and (Get-ProbeField $Probe.body 'status') -ceq 'staged' `
            -and (Get-ProbeField $Probe.body 'mode') -ceq $StagedMode `
            -and [string]$requestId -cmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z' `
            -and [string]$sourceId -cmatch '^[0-9a-f]{64}\z' `
            -and [string](Get-ProbeField $Probe.body 'content_hash') -cmatch '^[0-9a-f]{64}\z' `
            -and ($bytes -is [int] -or $bytes -is [long]) -and $bytes -gt 0 `
            -and [string]$blobName -cmatch "^native/$sourceId/source\.[a-z0-9]{1,10}\z" `
            -and $null -ne $Probe.body -and $Probe.body.PSObject.Properties.Name -notcontains 'document_id' `
            -and $Probe.body.PSObject.Properties.Name -notcontains 'indexed'
        try {
            $blobUrl = Get-ProbeField $Probe.body 'blob_url'
            $sourceUrl = Get-ProbeField $Probe.body 'source_url'
            $blob = [uri]$blobUrl
            $source = [uri]$sourceUrl
            $passed = $passed -and $blob.IsAbsoluteUri -and $blob.Scheme -ceq 'https' `
                -and $blob.Host -cmatch '^[a-z0-9]{3,24}\.blob\.core\.windows\.net\z' `
                -and $blob.IsDefaultPort -and -not $blob.UserInfo -and -not $blob.Query -and -not $blob.Fragment `
                -and $blob.AbsolutePath -cmatch '^/[a-z0-9][a-z0-9-]{1,61}[a-z0-9]/native/' `
                -and $blob.AbsolutePath.Substring($blob.AbsolutePath.IndexOf('/', 1) + 1) -ceq $blobName `
                -and [string]$blobUrl -ceq $blob.AbsoluteUri -and $source.IsAbsoluteUri -and ([string]$sourceUrl).Length -le 2048
            if ($StagedMode -eq 'fixture') { $passed = $passed -and $sourceUrl -ceq 'urn:funwithfoundry:fixture:accelerator-v1' }
            else { $passed = $passed -and $source.Scheme -ceq 'https' -and -not $source.UserInfo -and -not $source.Query -and -not $source.Fragment }
        }
        catch { $passed = $false }
    }
    $classification = if ($passed) { 'passed' } elseif ($Probe.http_status -eq 0) { 'inconclusive_network_or_transport' } else { 'failed' }
    $record = @{ check = $Name; status = $classification; http_status = $Probe.http_status }
    if ([string]$requestId -cmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z') { $record.request_id = $requestId }
    if ($StagedMode -and [string]$sourceId -cmatch '^[0-9a-f]{64}\z') { $record.source_id = $sourceId }
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
        $identityResponse = Invoke-RestMethod -Uri $identityUri -Headers @{ Metadata = 'true' } -TimeoutSec 15 -MaximumRedirection 0 -Verbose:$false -Debug:$false
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
    Add-ProbeResult 'fixture_staging' $first 202 -StagedMode fixture
    $second = Invoke-IngestionProbe $headers $fixture
    Add-ProbeResult 'fixture_rerun' $second 202 -StagedMode fixture
    $stable = $results[4].status -eq 'passed' -and $results[5].status -eq 'passed' `
        -and (Get-ProbeField $first.body 'source_id') -ceq (Get-ProbeField $second.body 'source_id') `
        -and (Get-ProbeField $first.body 'content_hash') -ceq (Get-ProbeField $second.body 'content_hash') `
        -and (Get-ProbeField $first.body 'blob_url') -ceq (Get-ProbeField $second.body 'blob_url')
    $results.Add(@{ check = 'stable_fixture_identity'; status = $(if ($stable) { 'passed' } else { 'failed' }) })
    if ($DeniedAccessToken) {
        $deniedBearer = [System.Net.NetworkCredential]::new('', $DeniedAccessToken).Password
        Add-ProbeResult 'unapproved_app_denied' (Invoke-IngestionProbe @{ Authorization = "Bearer $deniedBearer" } $fixture) 403
    }
    if ($IncludeSharePoint) {
        Add-ProbeResult 'configured_sharepoint_staging' (Invoke-IngestionProbe $headers @{ mode = 'sharepoint' }) 202 -StagedMode sharepoint
    }
    $failed = @($results | Where-Object { $_.status -ne 'passed' }).Count -gt 0
    @{
        status = $(if ($failed) { 'failed' } else { 'passed' })
        checks = $results.ToArray()
        sharepoint = $(if ($IncludeSharePoint) { 'attempted' } else { 'not_tested' })
        unapproved_app = $(if ($DeniedAccessToken) { 'attempted' } else { 'not_tested' })
        public_network_isolation = 'not_tested'
        indexing = 'not_tested'
        retrieval = 'not_tested'
    } | ConvertTo-Json -Depth 6 -Compress
    if ($failed) { exit 1 }
}
catch {
    @{ status = 'failed'; reason = 'ingestion_probe_failed'; indexing = 'not_tested'; checks = $results.ToArray() } | ConvertTo-Json -Depth 6 -Compress
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
