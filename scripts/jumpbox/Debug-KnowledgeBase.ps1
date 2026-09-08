# Isolates the knowledge base 400 and prints the full error, then tries schema variants.
# Uses Write-Host deliberately: Write-Output inside a function called in an 'if' condition
# becomes the function's return value and never reaches the console.
$ErrorActionPreference = 'Continue'

$search = "https://$FqdnSearch"
$openai = "https://$FqdnFoundryOAI"
$cogsvc = "https://$FqdnFoundryCog"
$ks = 'spo-knowledge-source'
$kb = 'spo-knowledge-base'
$agenticApi = '2026-05-01-preview'

function Get-ImdsToken {
    param([string]$Resource)
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource"
    (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

$token = Get-ImdsToken -Resource 'https://search.azure.com/'

function Try-Kb {
    param([string]$Label, $Body)
    Write-Host "--- $Label"
    $json = $Body | ConvertTo-Json -Depth 20
    try {
        $r = Invoke-WebRequest -Uri "$search/knowledgeBases/$kb`?api-version=$agenticApi" -Method PUT `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -Body $json -TimeoutSec 120 -UseBasicParsing
        Write-Host "    http $($r.StatusCode) OK"
        return $true
    }
    catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        $body = ''
        if ($resp) { try { $body = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() } catch {} }
        Write-Host "    http $code"
        Write-Host "    $body"
        return $false
    }
}

$variants = @(
    @{ label = 'A: models[] azureOpenAIParameters (openai endpoint)'; body = @{
            name             = $kb
            knowledgeSources = @(@{ name = $ks; alwaysQuery = $true })
            models           = @(@{ kind = 'azureOpenAI'; azureOpenAIParameters = @{ resourceUri = $openai; deploymentId = 'gpt-5.2'; modelName = 'gpt-5.2' } })
        }
    },
    @{ label = 'B: models[] azureOpenAIParameters (cognitiveservices endpoint)'; body = @{
            name             = $kb
            knowledgeSources = @(@{ name = $ks; alwaysQuery = $true })
            models           = @(@{ kind = 'azureOpenAI'; azureOpenAIParameters = @{ resourceUri = $cogsvc; deploymentId = 'gpt-5.2'; modelName = 'gpt-5.2' } })
        }
    },
    @{ label = 'C: completionModel object'; body = @{
            name             = $kb
            knowledgeSources = @(@{ name = $ks; alwaysQuery = $true })
            completionModel  = @{ kind = 'azureOpenAI'; azureOpenAIParameters = @{ resourceUri = $openai; deploymentId = 'gpt-5.2'; modelName = 'gpt-5.2' } }
        }
    },
    @{ label = 'D: minimal, no model'; body = @{
            name             = $kb
            knowledgeSources = @(@{ name = $ks; alwaysQuery = $true })
        }
    },
    @{ label = 'E: bare knowledge source reference'; body = @{
            name             = $kb
            knowledgeSources = @(@{ name = $ks })
        }
    }
)

$done = $false
foreach ($v in $variants) {
    if ($done) { break }
    $ok = Try-Kb -Label $v.label -Body $v.body
    if ($ok) { $done = $true }
}

if (-not $done) {
    Write-Host ""
    Write-Host "All variants failed. Existing knowledge bases (schema reference):"
    try {
        $r = Invoke-WebRequest -Uri "$search/knowledgeBases?api-version=$agenticApi" `
            -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 60 -UseBasicParsing
        Write-Host $r.Content
    }
    catch { Write-Host "list failed: $($_.Exception.Message)" }
}
