# Reads back the created knowledge base and knowledge source so the real schema is
# visible, then tries retrieve variants against it.
$ErrorActionPreference = 'Continue'

$search = "https://$FqdnSearch"
$kb = 'spo-knowledge-base'
$ks = 'spo-knowledge-source'
$agenticApi = '2026-05-01-preview'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}
$token = Get-ImdsToken -Resource 'https://search.azure.com/'
$h = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

function Show-Get {
    param([string]$Label, [string]$Url)
    Write-Host "--- $Label"
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $h -TimeoutSec 60 -UseBasicParsing
        Write-Host $r.Content
    }
    catch {
        $resp = $_.Exception.Response
        $b = ''
        if ($resp) { try { $b = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() } catch {} }
        Write-Host "    http $(if($resp){[int]$resp.StatusCode}else{0}) $b"
    }
    Write-Host ""
}

Show-Get -Label 'knowledgeSource definition' -Url "$search/knowledgeSources/$ks`?api-version=$agenticApi"
Show-Get -Label 'knowledgeBase definition'   -Url "$search/knowledgeBases/$kb`?api-version=$agenticApi"

function Try-Retrieve {
    param([string]$Label, $Body)
    Write-Host "--- retrieve: $Label"
    $json = $Body | ConvertTo-Json -Depth 20
    try {
        $r = Invoke-WebRequest -Uri "$search/knowledgeBases/$kb/retrieve?api-version=$agenticApi" -Method POST `
            -Headers $h -Body $json -TimeoutSec 180 -UseBasicParsing
        Write-Host "    http $($r.StatusCode) OK"
        Write-Host $r.Content
        return $true
    }
    catch {
        $resp = $_.Exception.Response
        $b = ''
        if ($resp) { try { $b = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() } catch {} }
        Write-Host "    http $(if($resp){[int]$resp.StatusCode}else{0})"
        Write-Host "    $b"
        return $false
    }
}

$q = 'What is the maintenance window code?'

$variants = @(
    @{ label = 'messages with content array'; body = @{ messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = $q }) }) } },
    @{ label = 'messages with string content'; body = @{ messages = @(@{ role = 'user'; content = $q }) } },
    @{ label = 'knowledgeSourceParams + messages'; body = @{
            messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = $q }) })
            knowledgeSourceParams = @(@{ knowledgeSourceName = $ks; kind = 'searchIndex' })
        }
    },
    @{ label = 'retrievalReasoningEffort minimal'; body = @{
            messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = $q }) })
            retrievalReasoningEffort = 'minimal'
        }
    }
)

$done = $false
foreach ($v in $variants) {
    if ($done) { break }
    if (Try-Retrieve -Label $v.label -Body $v.body) { $done = $true }
}
