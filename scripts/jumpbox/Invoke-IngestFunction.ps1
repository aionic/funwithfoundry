[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*\.azurewebsites\.net$')]
    [string]$FunctionHostname,
    [Parameter(Mandatory)]
    [guid]$ApiClientId,
    [ValidateSet('fixture', 'sharepoint')]
    [string]$Mode = 'fixture',
    [guid]$ManagedIdentityClientId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $PSCmdlet.ShouldProcess($FunctionHostname, "Invoke authorized $Mode ingestion")) { return }

$bearer = $null
$headers = @{}
$httpStatus = 0
try {
    $resource = [uri]::EscapeDataString("api://$ApiClientId")
    $identityQuery = if ($ManagedIdentityClientId -ne [guid]::Empty) { "&client_id=$ManagedIdentityClientId" } else { '' }
    $identityUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource$identityQuery"
    $bearer = (Invoke-RestMethod -Uri $identityUri -Headers @{ Metadata = 'true' } -TimeoutSec 15 -MaximumRedirection 0 -Verbose:$false -Debug:$false).access_token
    if ([string]::IsNullOrWhiteSpace($bearer)) { throw 'Managed identity returned no token.' }
    $headers.Authorization = "Bearer $bearer"
    $payload = @{ mode = $Mode }
    if ($Mode -eq 'fixture') { $payload.fixtureId = 'accelerator-v1' }
    $response = Invoke-WebRequest -Uri "https://$FunctionHostname/api/ingest" -Method Post `
        -Headers $headers -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Compress) `
        -MaximumRedirection 0 -TimeoutSec 240 -UseBasicParsing -Verbose:$false -Debug:$false
    $httpStatus = [int]$response.StatusCode
    if ($httpStatus -ne 202) { throw 'Expected HTTP 202.' }
    $result = $response.Content | ConvertFrom-Json
    foreach ($field in @('status', 'source_id', 'content_hash', 'source_url', 'blob_url', 'blob_name', 'bytes', 'mode', 'request_id')) {
        if ($null -eq $result.PSObject.Properties[$field]) { throw 'Missing staging field.' }
    }
    if ($result.status -cne 'staged' -or $result.mode -cne $Mode -or
        $null -ne $result.PSObject.Properties['document_id'] -or $null -ne $result.PSObject.Properties['indexed'] -or
        [string]$result.request_id -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z' -or
        [string]$result.source_id -cnotmatch '^[0-9a-f]{64}\z' -or
        [string]$result.content_hash -cnotmatch '^[0-9a-f]{64}\z' -or
        ($result.bytes -isnot [int] -and $result.bytes -isnot [long]) -or $result.bytes -le 0 -or
        [string]$result.blob_name -cnotmatch "^native/$($result.source_id)/source\.[a-z0-9]{1,10}\z") {
        throw 'Invalid staging contract.'
    }
    $blob = [uri]$result.blob_url
    $source = [uri]$result.source_url
    if (-not $blob.IsAbsoluteUri -or $blob.Scheme -cne 'https' -or
        $blob.Host -cnotmatch '^[a-z0-9]{3,24}\.blob\.core\.windows\.net\z' -or
        -not $blob.IsDefaultPort -or $blob.UserInfo -or $blob.Query -or $blob.Fragment -or
        $blob.AbsolutePath -cnotmatch '^/[a-z0-9][a-z0-9-]{1,61}[a-z0-9]/native/' -or
        $blob.AbsolutePath.Substring($blob.AbsolutePath.IndexOf('/', 1) + 1) -cne $result.blob_name -or
        [string]$result.blob_url -cne $blob.AbsoluteUri -or
        -not $source.IsAbsoluteUri -or ([string]$result.source_url).Length -gt 2048) {
        throw 'Invalid staging URLs.'
    }
    if (($Mode -eq 'fixture' -and $result.source_url -cne 'urn:funwithfoundry:fixture:accelerator-v1') -or
        ($Mode -eq 'sharepoint' -and ($source.Scheme -cne 'https' -or $source.UserInfo -or $source.Query -or $source.Fragment))) {
        throw 'Invalid source URL.'
    }
    [pscustomobject]@{
        status = 'staged'
        mode = $Mode
        request_id = $result.request_id
        source_id = $result.source_id
        content_hash = $result.content_hash
        source_url = $result.source_url
        blob_url = $result.blob_url
        blob_name = $result.blob_name
        bytes = $result.bytes
        indexing = 'not_tested'
    }
}
catch {
    $responseProperty = $_.Exception.PSObject.Properties['Response']
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) { $httpStatus = [int]$responseProperty.Value.StatusCode }
    throw "Authorized Function staging failed (HTTP $httpStatus; expected a valid 202 contract). Check API audience, caller allowlist, private DNS, and Function health; no response body or token was logged."
}
finally {
    $bearer = $null
    $headers.Clear()
}
