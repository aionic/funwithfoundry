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
try {
    $resource = [uri]::EscapeDataString("api://$ApiClientId")
    $identityQuery = if ($ManagedIdentityClientId -ne [guid]::Empty) { "&client_id=$ManagedIdentityClientId" } else { '' }
    $identityUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource$identityQuery"
    $bearer = (Invoke-RestMethod -Uri $identityUri -Headers @{ Metadata = 'true' } -TimeoutSec 15 -MaximumRedirection 0).access_token
    if ([string]::IsNullOrWhiteSpace($bearer)) { throw 'Managed identity returned no token.' }
    $headers.Authorization = "Bearer $bearer"
    $payload = @{ mode = $Mode }
    if ($Mode -eq 'fixture') { $payload.fixtureId = 'accelerator-v1' }
    $response = Invoke-WebRequest -Uri "https://$FunctionHostname/api/ingest" -Method Post `
        -Headers $headers -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Compress) `
        -MaximumRedirection 0 -TimeoutSec 240 -UseBasicParsing
    $result = $response.Content | ConvertFrom-Json
    if ([int]$response.StatusCode -ne 200 -or $result.status -ne 'indexed' -or
        [string]$result.request_id -notmatch '^[0-9a-f-]{36}$' -or
        [string]$result.document_id -notmatch '^[0-9a-f]{64}$' -or
        [string]$result.content_hash -notmatch '^[0-9a-f]{64}$') {
        throw 'The Function did not confirm indexed content with provenance.'
    }
    [pscustomobject]@{
        status = 'indexed'
        mode = $Mode
        request_id = $result.request_id
        document_id = $result.document_id
        content_hash = $result.content_hash
    }
}
catch {
    throw 'Authorized Function ingestion failed. Check API audience, caller allowlist, fixture enablement, private DNS, and Function deployment health; no response body or token was logged.'
}
finally {
    $bearer = $null
    $headers.Clear()
}
