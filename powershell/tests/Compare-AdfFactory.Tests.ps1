#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Worker,
    [string] $Scenario = 'match',
    [string] $OutputDirectory,
    [string] $FactoryResourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/test-group/providers/Microsoft.DataFactory/factories/test-factory',
    [string] $Delimiter = ','
)

$ErrorActionPreference = 'Stop'
$workflow = Join-Path (Split-Path -Parent $PSScriptRoot) 'Compare-AdfFactory.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$oneJson = "{`r`n  `"id`": `"arm-resource-one`", `"name`": `"PL [One]`", `"type`": `"Microsoft.DataFactory/factories/pipelines`", `"etag`": `"version-one`",`r`n  `"properties`": { `"activities`": [], `"policy`": { `"elapsedTimeMetric`": {} } }`r`n}`r`n"
$twoJson = '{"id":"arm-resource-two","name":"PL_Two","type":"Microsoft.DataFactory/factories/pipelines","etag":"version-two","properties":{"activities":[]}}'
[byte[]] $oneBytes = $utf8Bom.GetPreamble() + $utf8Bom.GetBytes($oneJson)
[byte[]] $twoBytes = $utf8.GetBytes($twoJson)
$factoryUrl = 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/test-group/providers/Microsoft.DataFactory/factories/test-factory'
$listUrl = "$factoryUrl/pipelines?api-version=2018-06-01"

if ($Worker) {
    $global:adfFactoryTestTokenRequests = 0
    $global:adfFactoryTestDownloadPaths = [System.Collections.Generic.List[string]]::new()
    $env:GH_TOKEN = 'fake-github-token'

    function az {
        $global:adfFactoryTestTokenRequests++
        $arguments = $args -join ' '
        if ($arguments -notlike 'account get-access-token *' -or
            $arguments -notlike '*--subscription 11111111-2222-3333-4444-555555555555*' -or
            $arguments -notlike '*--resource https://management.azure.com/*') {
            throw 'Unexpected Azure CLI arguments.'
        }
        if ($Scenario -eq 'auth-error') {
            $global:LASTEXITCODE = 1
            return
        }
        $global:LASTEXITCODE = 0
        $expiry = [System.DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
        if ($Scenario -eq 'expired-token') {
            $expiry = [System.DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds()
        }
        elseif ($Scenario -eq 'refresh-token' -and $global:adfFactoryTestTokenRequests -eq 1) {
            $expiry = [System.DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds()
        }
        @{ accessToken = 'fake-arm-token'; expires_on = $expiry } | ConvertTo-Json -Compress
    }

    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)

        if ($MaximumRedirection -ne 0) {
            throw 'HTTP redirects must be disabled.'
        }
        if ($Uri -like 'https://management.azure.com/*') {
            if ($Headers.Authorization -cne 'Bearer fake-arm-token') {
                throw 'Expected an ARM token for Azure requests.'
            }
            if ($Scenario -eq 'list-error') {
                throw [System.Net.WebException]::new('HTTP 403: ADF list access denied.')
            }
            if ($Uri -eq $listUrl) {
                if ($Scenario -eq 'empty') {
                    return [pscustomobject]@{ value = @() }
                }
                if ($Scenario -eq 'invalid-page') {
                    return [pscustomobject]@{ unexpected = @() }
                }
                $nextLink = "$listUrl&page=2"
                if ($Scenario -eq 'unsafe-nextlink') {
                    $nextLink = 'https://example.com/collect'
                }
                elseif ($Scenario -eq 'other-factory-nextlink') {
                    $nextLink = $nextLink.Replace('test-factory/pipelines', 'another-factory/pipelines')
                }
                elseif ($Scenario -eq 'pagination-loop') {
                    $nextLink = $listUrl
                }
                $name = if ($Scenario -eq 'unsafe-name') { '..\escape' } else { 'PL [One]' }
                return [pscustomobject]@{ value = @([pscustomobject]@{ name = $name }); nextLink = $nextLink }
            }
            if ($Uri -eq "$listUrl&page=2") {
                $name = if ($Scenario -eq 'duplicate-name') { 'pl [one]' } else { 'PL_Two' }
                return [pscustomobject]@{ value = @([pscustomobject]@{ name = $name }) }
            }
            throw "Unexpected Azure list request: $Uri"
        }
        if ($Headers.Authorization -cne 'Bearer fake-github-token') {
            throw 'ARM tokens must not be sent to GitHub.'
        }
        if ($Scenario -eq 'github-error') {
            throw [System.Net.WebException]::new('HTTP 403: GitHub access denied.')
        }
        if ($Uri -eq 'https://api.github.com/repos/example/pipelines') {
            return [pscustomobject]@{ default_branch = 'main' }
        }
        if ($Uri -eq 'https://api.github.com/repos/example/pipelines/commits/main') {
            return [pscustomobject]@{ sha = ('a' * 40); commit = @{ tree = @{ sha = ('b' * 40) } } }
        }
        if ($Uri -eq "https://api.github.com/repos/example/pipelines/git/trees/$('b' * 40)?recursive=1") {
            return [pscustomobject]@{
                truncated = $false
                tree = @(
                    [pscustomobject]@{ type = 'blob'; mode = '100644'; path = 'pipelines/PL [One].json' }
                    [pscustomobject]@{ type = 'blob'; mode = '100644'; path = 'PL_Two.json' }
                )
            }
        }
        throw "Unexpected GitHub metadata request: $Uri"
    }

    function Invoke-WebRequest {
        param($Uri, $Headers, $OutFile, [switch] $PassThru, [switch] $UseBasicParsing, $TimeoutSec, $MaximumRedirection)

        if ($MaximumRedirection -ne 0) {
            throw 'HTTP redirects must be disabled.'
        }
        $global:adfFactoryTestDownloadPaths.Add($OutFile)
        if ($Uri -like 'https://management.azure.com/*') {
            if ($Headers.Authorization -cne 'Bearer fake-arm-token') {
                throw 'Expected an ARM token for Azure downloads.'
            }
            $decodedUri = [uri]::UnescapeDataString($Uri)
            if ($decodedUri -eq "$factoryUrl/pipelines/PL [One]?api-version=2018-06-01") {
                [System.IO.File]::WriteAllBytes($OutFile, $oneBytes)
                if ($Scenario -eq 'export-error') {
                    throw [System.Net.WebException]::new('HTTP 500: pipeline export failed.')
                }
                if ($Scenario -eq 'invalid-json') {
                    [System.IO.File]::WriteAllText($OutFile, '{bad json', $utf8)
                }
                if ($Scenario -eq 'wrong-name') {
                    [System.IO.File]::WriteAllText($OutFile, '{"name":"Wrong","properties":{}}', $utf8)
                }
            }
            elseif ($decodedUri -eq "$factoryUrl/pipelines/PL_Two?api-version=2018-06-01") {
                [System.IO.File]::WriteAllBytes($OutFile, $twoBytes)
            }
            else {
                throw "Unexpected Azure download request: $Uri"
            }
            $contentType = if ($Scenario -eq 'html' -and $decodedUri.Contains('PL [One]')) { 'text/html' } else { 'application/json; charset=utf-8' }
            return @{ Headers = @{ 'Content-Type' = $contentType } }
        }
        if ($Headers.Authorization -cne 'Bearer fake-github-token') {
            throw 'ARM tokens must not be sent to GitHub downloads.'
        }
        $decodedUri = [uri]::UnescapeDataString($Uri)
        if ($decodedUri -eq "https://api.github.com/repos/example/pipelines/contents/pipelines/PL [One].json?ref=$('a' * 40)") {
            [System.IO.File]::WriteAllBytes($OutFile, $oneBytes)
        }
        elseif ($decodedUri -eq "https://api.github.com/repos/example/pipelines/contents/PL_Two.json?ref=$('a' * 40)") {
            $bytes = if ($Scenario -eq 'different') { $twoBytes + [byte] 10 } else { $twoBytes }
            [System.IO.File]::WriteAllBytes($OutFile, $bytes)
        }
        else {
            throw "Unexpected GitHub download request: $Uri"
        }
        if ($Scenario -like 'definition-*') {
            $name = if ($decodedUri.Contains('PL [One]')) { 'PL [One]' } else { 'PL_Two' }
            $uiJson = '{"name":"' + $name + '","properties":{"lastPublishTime":"2030-01-01T00:00:00Z","activities":[]}}'
            if ($Scenario -eq 'definition-different' -and $name -eq 'PL_Two') {
                $uiJson = $uiJson.Replace('"activities":[]', '"activities":[{"name":"new","type":"Wait","typeProperties":{"waitTimeInSeconds":2}}]')
            }
            if ($Scenario -eq 'definition-invalid' -and $name -eq 'PL [One]') {
                $uiJson = '{invalid'
            }
            [System.IO.File]::WriteAllText($OutFile, $uiJson, $utf8)
        }
        return @{ Headers = @{ 'Content-Type' = 'application/vnd.github.raw+json' } }
    }

    $mode = if ($Scenario -like 'definition-*') { 'PipelineDefinition' } else { 'ExactBytes' }
    & $workflow -FactoryResourceId $FactoryResourceId -RepoUrl 'https://github.com/example/pipelines' `
        -OutputDirectory $OutputDirectory -Delimiter $Delimiter -ComparisonMode $mode
    $workflowExitCode = $LASTEXITCODE
    foreach ($path in $global:adfFactoryTestDownloadPaths) {
        if ([System.IO.File]::Exists($path)) {
            Write-Error 'A temporary download was not removed.' -ErrorAction Continue
            exit 99
        }
    }
    if ($Scenario -eq 'refresh-token' -and $global:adfFactoryTestTokenRequests -ne 2) {
        Write-Error 'Expected exactly one token refresh.' -ErrorAction Continue
        exit 99
    }
    exit $workflowExitCode
}

$executable = (Get-Process -Id $PID).Path
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('adf-factory-tests-' + [guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($testDirectory)

function Invoke-WorkflowTest {
    param(
        [string] $Name,
        [int] $ExpectedExitCode,
        [string[]] $ExpectedResults,
        [string] $ExpectedError,
        [string] $ResourceId = $FactoryResourceId,
        [string] $Separator = ','
    )

    $outputRoot = Join-Path $testDirectory $Name
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $executable -NoProfile -NonInteractive -File $PSCommandPath -Worker -Scenario $Name `
            -FactoryResourceId $ResourceId -OutputDirectory $outputRoot -Delimiter $Separator 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne $ExpectedExitCode) {
        throw "${Name}: expected exit $ExpectedExitCode, got $exitCode.`n$output"
    }
    if ($output.Contains('fake-arm-token') -or $output.Contains('fake-github-token')) {
        throw "${Name}: credentials were logged."
    }
    if ($ExpectedError -and -not $output.Contains($ExpectedError)) {
        throw "${Name}: expected error '$ExpectedError'.`n$output"
    }
    if ($ExpectedResults) {
        $runs = @(Get-ChildItem -LiteralPath $outputRoot -Directory)
        if ($runs.Count -ne 1) {
            throw "${Name}: expected a unique run directory."
        }
        $run = $runs[0].FullName
        $manifest = @(Import-Csv -LiteralPath (Join-Path $run 'pipelines.csv') -Delimiter $Separator[0])
        $status = @(Import-Csv -LiteralPath (Join-Path $run 'export-status.csv') -Delimiter $Separator[0])
        $report = @(Import-Csv -LiteralPath (Join-Path $run 'comparison-results.csv') -Delimiter $Separator[0])
        if ($manifest.Count -ne 2 -or $manifest[0].PSObject.Properties.Name.Count -ne 1 -or
            $manifest[0].PSObject.Properties.Name -notcontains 'AdfPath' -or $status.Count -ne 2 -or
            ($report.Result -join ',') -cne ($ExpectedResults -join ',')) {
            throw "${Name}: incomplete or invalid generated CSV files.`n$output"
        }
        for ($index = 0; $index -lt 2; $index++) {
            if ($report[$index].AdfPath -cne $manifest[$index].AdfPath) {
                throw "${Name}: manifest and report paths disagree."
            }
            if ($ExpectedResults[$index] -eq 'ERROR') {
                if ($Name -eq 'definition-invalid') {
                    if ($status[$index].Result -ne 'EXPORTED' -or -not $report[$index].Error -or
                        $report[$index].ComparisonMode -ne 'PipelineDefinition' -or
                        -not $report[$index].AdfSHA256 -or -not $report[$index].GitSHA256 -or
                        -not (Test-Path -LiteralPath $manifest[$index].AdfPath)) {
                        throw "${Name}: normalization errors must preserve the exported files and raw hashes."
                    }
                }
                elseif ($status[$index].Result -ne 'ERROR' -or
                    -not $report[$index].Error.StartsWith('ADF export failed:') -or
                    (Test-Path -LiteralPath $manifest[$index].AdfPath)) {
                    throw "${Name}: export error or partial file was not handled correctly."
                }
            }
            else {
                $bytes = [System.IO.File]::ReadAllBytes($manifest[$index].AdfPath)
                $expectedBytes = if ($index -eq 0) { $oneBytes } else { $twoBytes }
                if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($expectedBytes)) {
                    throw "${Name}: the original response bytes (including metadata, BOM and CRLF) were changed."
                }
                $hash = (Get-FileHash -LiteralPath $manifest[$index].AdfPath -Algorithm SHA256).Hash
                if ($report[$index].AdfSHA256 -cne $hash -or
                    $report[$index].Identical -ne [string] ($ExpectedResults[$index] -eq 'MATCH') -or
                    -not $report[$index].GitUrl.Contains("/blob/$('a' * 40)/")) {
                    throw "${Name}: invalid hashes, equality flag or pinned GitHub URL."
                }
                if ($Name -like 'definition-*') {
                    if ($report[$index].ComparisonMode -cne 'PipelineDefinition' -or
                        $report[$index].NormalizationVersion -cne 'PipelineDefinition-v2' -or
                        $report[$index].BytesIdentical -ne 'False' -or
                        $report[$index].DefinitionIdentical -ne [string] ($ExpectedResults[$index] -eq 'MATCH') -or
                        $report[$index].AdfDefinitionSHA256 -notmatch '^[A-F0-9]{64}$' -or
                        (($report[$index].AdfDefinitionSHA256 -ceq $report[$index].GitDefinitionSHA256) -ne
                            ($ExpectedResults[$index] -eq 'MATCH'))) {
                        throw "${Name}: normalized mode did not propagate through factory, batch and individual comparison."
                    }
                }
            }
        }
    }
    elseif (Test-Path -LiteralPath $outputRoot) {
        if ($Name -ne 'github-error') {
            throw "${Name}: listing/authentication failures should not produce export folders."
        }
        $run = @(Get-ChildItem -LiteralPath $outputRoot -Directory)[0].FullName
        if (-not (Test-Path -LiteralPath (Join-Path $run 'export-status.csv')) -or
            (Test-Path -LiteralPath (Join-Path $run 'comparison-results.csv'))) {
            throw "${Name}: successful exports should remain without a misleading final report."
        }
    }
    Write-Output "PASS: $Name"
}

try {
    Invoke-WorkflowTest -Name 'match' -ExpectedExitCode 0 -ExpectedResults @('MATCH', 'MATCH')
    Invoke-WorkflowTest -Name 'definition-match' -ExpectedExitCode 0 -ExpectedResults @('MATCH', 'MATCH')
    Invoke-WorkflowTest -Name 'definition-different' -ExpectedExitCode 1 -ExpectedResults @('MATCH', 'DIFFERENT')
    Invoke-WorkflowTest -Name 'definition-invalid' -ExpectedExitCode 2 -ExpectedResults @('ERROR', 'MATCH')
    Invoke-WorkflowTest -Name 'different' -ExpectedExitCode 1 -ExpectedResults @('MATCH', 'DIFFERENT') -Separator ';'
    Invoke-WorkflowTest -Name 'refresh-token' -ExpectedExitCode 0 -ExpectedResults @('MATCH', 'MATCH')
    foreach ($scenario in @('export-error', 'invalid-json', 'wrong-name', 'html')) {
        Invoke-WorkflowTest -Name $scenario -ExpectedExitCode 2 -ExpectedResults @('ERROR', 'MATCH')
    }
    Invoke-WorkflowTest -Name 'auth-error' -ExpectedExitCode 2 -ExpectedError 'authentication'
    Invoke-WorkflowTest -Name 'expired-token' -ExpectedExitCode 2 -ExpectedError 'expired'
    Invoke-WorkflowTest -Name 'list-error' -ExpectedExitCode 2 -ExpectedError '403'
    Invoke-WorkflowTest -Name 'invalid-page' -ExpectedExitCode 2 -ExpectedError 'pipeline list'
    Invoke-WorkflowTest -Name 'unsafe-nextlink' -ExpectedExitCode 2 -ExpectedError 'pagination'
    Invoke-WorkflowTest -Name 'other-factory-nextlink' -ExpectedExitCode 2 -ExpectedError 'pagination'
    Invoke-WorkflowTest -Name 'pagination-loop' -ExpectedExitCode 2 -ExpectedError 'pagination'
    Invoke-WorkflowTest -Name 'duplicate-name' -ExpectedExitCode 2 -ExpectedError 'collision'
    Invoke-WorkflowTest -Name 'unsafe-name' -ExpectedExitCode 2 -ExpectedError 'safely'
    Invoke-WorkflowTest -Name 'empty' -ExpectedExitCode 2 -ExpectedError 'published'
    Invoke-WorkflowTest -Name 'invalid-resource-id' -ExpectedExitCode 2 -ExpectedError 'FactoryResourceId' `
        -ResourceId '/subscriptions/not-a-guid/resourceGroups/group/providers/Microsoft.Storage/storageAccounts/account'
    Invoke-WorkflowTest -Name 'github-error' -ExpectedExitCode 2 -ExpectedError 'report'
}
finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
