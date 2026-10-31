#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $IncludeGitHubIntegration,
    [switch] $DownloadMockWorker,
    [string] $Scenario,
    [string] $AdfPath,
    [string] $GitUrl
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Compare-AdfPipeline.ps1'
if ($DownloadMockWorker) {
    $env:GH_TOKEN = 'test-token'
    function Invoke-WebRequest {
        param($Uri, $Headers, $OutFile, [switch] $PassThru, [switch] $UseBasicParsing, $TimeoutSec, $MaximumRedirection)

        $script:mockDownloadPath = $OutFile
        if ($Uri -cne 'https://api.github.com/repos/example/pipelines/contents/folder/Pipeline%20one.json?ref=feature%2Ftest' -or
            $Headers.Accept -cne 'application/vnd.github.raw+json' -or
            $Headers.Authorization -cne 'Bearer test-token' -or $MaximumRedirection -ne 0) {
            throw 'Unexpected download request.'
        }
        if ($Scenario -eq 'http-error') {
            throw [System.Net.WebException]::new('HTTP 404: file not found or access denied.')
        }
        if ($Scenario -eq 'timeout') {
            throw [System.Net.WebException]::new('Download timed out.')
        }

        $bytes = [System.IO.File]::ReadAllBytes($AdfPath)
        if ($Scenario -eq 'different') {
            $bytes += [byte] 10
        }
        [System.IO.File]::WriteAllBytes($OutFile, $bytes)
        $contentType = if ($Scenario -eq 'html') { 'text/html' } else { 'application/vnd.github.raw+json; charset=utf-8' }
        return @{ Headers = @{ 'Content-Type' = $contentType } }
    }

    & $scriptPath -AdfPath $AdfPath -GitUrl $GitUrl
    $comparisonExitCode = $LASTEXITCODE
    if ($script:mockDownloadPath -and (Test-Path -LiteralPath $script:mockDownloadPath)) {
        throw 'Temporary download was not removed.'
    }
    exit $comparisonExitCode
}

$executable = (Get-Process -Id $PID).Path
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('adf-compare-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDirectory
$adfPath = Join-Path $testDirectory 'ADF pipeline [source].json'
$gitPath = Join-Path $testDirectory 'Git pipeline [copy].json'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$json = '{"name":"pipeline1","properties":{"activities":[]}}'

function Assert-Comparison {
    param(
        [string] $Name,
        [int] $ExpectedExitCode,
        [string] $ExpectedText,
        [string] $RepositoryPath = $gitPath,
        [string] $RepositoryUrl,
        [string] $MockScenario
    )

    # Windows PowerShell converts redirected native stderr into error records.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($MockScenario) {
            $output = & $executable -NoProfile -NonInteractive -File $PSCommandPath -DownloadMockWorker -Scenario $MockScenario -AdfPath $adfPath -GitUrl $RepositoryUrl 2>&1 | Out-String
        }
        elseif ($RepositoryUrl) {
            $output = & $executable -NoProfile -NonInteractive -File $scriptPath -AdfPath $adfPath -GitUrl $RepositoryUrl 2>&1 | Out-String
        }
        else {
            $output = & $executable -NoProfile -NonInteractive -File $scriptPath -AdfPath $adfPath -GitPath $RepositoryPath 2>&1 | Out-String
        }
        $actualExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($actualExitCode -ne $ExpectedExitCode -or -not $output.Contains($ExpectedText)) {
        throw "${Name}: expected exit $ExpectedExitCode and '$ExpectedText'; got exit $actualExitCode.`n$output"
    }

    if ($ExpectedExitCode -ne 2) {
        $expectedAdfHash = (Get-FileHash -LiteralPath $adfPath -Algorithm SHA256).Hash
        if ($MockScenario) {
            $bytes = [System.IO.File]::ReadAllBytes($adfPath)
            if ($MockScenario -eq 'different') {
                $bytes += [byte] 10
            }
            $algorithm = [System.Security.Cryptography.SHA256]::Create()
            try {
                $expectedGitHash = [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '')
            }
            finally {
                $algorithm.Dispose()
            }
        }
        else {
            $expectedGitHash = (Get-FileHash -LiteralPath $RepositoryPath -Algorithm SHA256).Hash
        }
        if (-not $output.Contains($expectedAdfHash) -or -not $output.Contains($expectedGitHash)) {
            throw "${Name}: output does not contain both SHA-256 hashes.`n$output"
        }
    }

    if ($RepositoryUrl -and $ExpectedExitCode -ne 2 -and -not $output.Contains($RepositoryUrl)) {
        throw "${Name}: output does not identify the GitHub URL."
    }
    Write-Output "PASS: $Name"
}

try {
    [System.IO.File]::WriteAllText($adfPath, $json, $utf8)
    [System.IO.File]::WriteAllText($gitPath, $json, $utf8)
    Assert-Comparison -Name 'Identical bytes, paths with spaces and brackets' -ExpectedExitCode 0 -ExpectedText 'MATCH'

    [System.IO.File]::WriteAllText($gitPath, $json.Replace('pipeline1', 'pipeline2'), $utf8)
    Assert-Comparison -Name 'Changed pipeline content' -ExpectedExitCode 1 -ExpectedText 'DIFFERENT'

    [System.IO.File]::WriteAllText($gitPath, $json.Replace(':', ': '), $utf8)
    Assert-Comparison -Name 'Whitespace is significant' -ExpectedExitCode 1 -ExpectedText 'DIFFERENT'

    [System.IO.File]::WriteAllText($adfPath, "$json`n", $utf8)
    [System.IO.File]::WriteAllText($gitPath, "$json`r`n", $utf8)
    Assert-Comparison -Name 'LF versus CRLF' -ExpectedExitCode 1 -ExpectedText 'DIFFERENT'

    [System.IO.File]::WriteAllText($adfPath, $json, $utf8)
    [System.IO.File]::WriteAllText($gitPath, $json, [System.Text.UTF8Encoding]::new($true))
    Assert-Comparison -Name 'UTF-8 BOM is significant' -ExpectedExitCode 1 -ExpectedText 'DIFFERENT'

    Assert-Comparison -Name 'Missing repository file' -ExpectedExitCode 2 -ExpectedText 'Comparison failed:' -RepositoryPath (Join-Path $testDirectory 'missing.json')
    Assert-Comparison -Name 'Directory is not a file' -ExpectedExitCode 2 -ExpectedText 'Comparison failed:' -RepositoryPath $testDirectory

    $mockUrl = 'https://github.com/example/pipelines/blob/feature%2Ftest/folder/Pipeline%20one.json'
    Assert-Comparison -Name 'GitHub identical bytes and encoded URL' -ExpectedExitCode 0 -ExpectedText 'MATCH' -RepositoryUrl $mockUrl -MockScenario 'match'
    Assert-Comparison -Name 'GitHub different bytes' -ExpectedExitCode 1 -ExpectedText 'DIFFERENT' -RepositoryUrl $mockUrl -MockScenario 'different'
    Assert-Comparison -Name 'GitHub HTTP error' -ExpectedExitCode 2 -ExpectedText 'Comparison failed:' -RepositoryUrl $mockUrl -MockScenario 'http-error'
    Assert-Comparison -Name 'GitHub timeout' -ExpectedExitCode 2 -ExpectedText 'Comparison failed:' -RepositoryUrl $mockUrl -MockScenario 'timeout'
    Assert-Comparison -Name 'Reject HTML instead of raw content' -ExpectedExitCode 2 -ExpectedText 'Comparison failed:' -RepositoryUrl $mockUrl -MockScenario 'html'
    Assert-Comparison -Name 'Reject repository root URL' -ExpectedExitCode 2 -ExpectedText 'GitUrl must be' -RepositoryUrl 'https://github.com/example/pipelines'
    Assert-Comparison -Name 'Reject external URL' -ExpectedExitCode 2 -ExpectedText 'GitUrl must be' -RepositoryUrl 'https://example.com/example/pipelines/blob/main/pipeline.json'
    Assert-Comparison -Name 'Reject HTTP URL' -ExpectedExitCode 2 -ExpectedText 'GitUrl must be' -RepositoryUrl 'http://github.com/example/pipelines/blob/main/pipeline.json'

    if ($IncludeGitHubIntegration) {
        $liveUrl = 'https://github.com/misantibanez/adf-compare-github/blob/main/PL_Ejemplo_2_Actividades.json'
        $downloadFixture = Join-Path $testDirectory 'download.json'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/misantibanez/adf-compare-github/main/PL_Ejemplo_2_Actividades.json' `
            -OutFile $downloadFixture -UseBasicParsing -TimeoutSec 60
        [System.IO.File]::Copy($downloadFixture, $adfPath, $true)
        Copy-Item -LiteralPath $adfPath -Destination $gitPath -Force
        Assert-Comparison -Name 'Real GitHub URL, identical bytes' -ExpectedExitCode 0 -ExpectedText 'MATCH' -RepositoryUrl $liveUrl
        [System.IO.File]::AppendAllText($adfPath, "`n", $utf8)
        Assert-Comparison -Name 'Real GitHub URL, different bytes' -ExpectedExitCode 1 -ExpectedText 'DIFFERENT' -RepositoryUrl $liveUrl
    }

    Remove-Item -LiteralPath $adfPath
    Assert-Comparison -Name 'Missing ADF export' -ExpectedExitCode 2 -ExpectedText 'Comparison failed:'
}
finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
