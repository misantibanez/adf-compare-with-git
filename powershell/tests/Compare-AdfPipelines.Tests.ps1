#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Worker,
    [string] $CsvPath,
    [string] $ReportPath,
    [string] $Delimiter = ',',
    [string] $RepoUrl,
    [string] $GitRef,
    [string] $RepositoryScenario
)

$ErrorActionPreference = 'Stop'
$batchScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Compare-AdfPipelines.ps1'
$json = '{"name":"pipeline1","properties":{"activities":[]}}'
$utf8 = [System.Text.UTF8Encoding]::new($false)

if ($Worker) {
    $script:treeRequests = 0
    function Invoke-RestMethod {
        param($Uri, $Headers, $TimeoutSec, $MaximumRedirection)

        if ($Headers.Accept -ne 'application/vnd.github+json' -or $MaximumRedirection -ne 0) {
            throw 'Unexpected metadata request headers or redirects.'
        }
        if ($RepositoryScenario -eq 'http-error') {
            throw [System.Net.WebException]::new('HTTP 403: repository access denied.')
        }
        if ($Uri -eq 'https://api.github.com/repos/example/pipelines') {
            return [pscustomobject]@{ default_branch = 'release/default' }
        }
        if ($Uri -eq 'https://api.github.com/repos/example/pipelines/commits/release%2Fdefault' -or
            $Uri -eq 'https://api.github.com/repos/example/pipelines/commits/feature%2Ftest') {
            return [pscustomobject]@{
                sha = ('a' * 40)
                commit = @{ tree = @{ sha = ('b' * 40) } }
            }
        }
        if ($Uri -eq "https://api.github.com/repos/example/pipelines/git/trees/$('b' * 40)?recursive=1") {
            $script:treeRequests++
            if ($script:treeRequests -ne 1) {
                throw 'Repository tree must only be fetched once per batch.'
            }
            return [pscustomobject]@{
                truncated = ($RepositoryScenario -eq 'truncated')
                tree = @(
                    [pscustomobject]@{ type = 'blob'; mode = '100644'; path = 'pipeline [matching],1.json' }
                    [pscustomobject]@{ type = 'blob'; mode = '100644'; path = 'folder one/pipeline different.json' }
                    [pscustomobject]@{ type = 'blob'; mode = '100644'; path = 'one/duplicate.json' }
                    [pscustomobject]@{ type = 'blob'; mode = '100644'; path = 'two/duplicate.json' }
                    [pscustomobject]@{ type = 'blob'; mode = '100644'; path = 'Case.json' }
                    [pscustomobject]@{ type = 'blob'; mode = '120000'; path = 'link.json' }
                    [pscustomobject]@{ type = 'tree'; mode = '040000'; path = 'directory.json' }
                )
            }
        }
        throw "Unexpected metadata URL: $Uri"
    }

    function Invoke-WebRequest {
        param($Uri, $Headers, $OutFile, [switch] $PassThru, [switch] $UseBasicParsing, $TimeoutSec, $MaximumRedirection)

        if ($Uri -eq 'https://api.github.com/repos/example/pipelines/contents/missing.json?ref=main') {
            throw [System.Net.WebException]::new('HTTP 404: file not found or access denied.')
        }
        $autoUrls = @(
            "https://api.github.com/repos/example/pipelines/contents/pipeline%20%5Bmatching%5D%2C1.json?ref=$('a' * 40)"
            "https://api.github.com/repos/example/pipelines/contents/folder%20one/pipeline%20different.json?ref=$('a' * 40)"
        )
        if ($Uri -ne 'https://api.github.com/repos/example/pipelines/contents/pipeline.json?ref=main' -and
            $autoUrls -cnotcontains $Uri) {
            throw "Unexpected request: $Uri"
        }
        [System.IO.File]::WriteAllText($OutFile, $json, $utf8)
        return @{ Headers = @{ 'Content-Type' = 'application/vnd.github.raw+json' } }
    }

    $options = @{}
    if ($RepoUrl) { $options.RepoUrl = $RepoUrl }
    if ($GitRef) { $options.GitRef = $GitRef }
    & $batchScript -CsvPath $CsvPath -ReportPath $ReportPath -Delimiter $Delimiter @options
    exit $LASTEXITCODE
}

$executable = (Get-Process -Id $PID).Path
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('adf-batch-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDirectory
$inputPath = Join-Path $testDirectory 'pipelines [input].csv'
$reportPath = Join-Path $testDirectory 'report [output].csv'
$matchingPath = Join-Path $testDirectory 'pipeline [matching],1.json'
$differentPath = Join-Path $testDirectory 'pipeline different.json'
$url = 'https://github.com/example/pipelines/blob/main/pipeline.json'

function Invoke-Batch {
    param(
        [string] $InputFile = $inputPath,
        [string] $OutputFile = $reportPath,
        [string] $Separator = ',',
        [string] $Repository,
        [string] $Reference,
        [string] $Scenario
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $arguments = @()
        if ($Repository) { $arguments += @('-RepoUrl', $Repository) }
        if ($Reference) { $arguments += @('-GitRef', $Reference) }
        if ($Scenario) { $arguments += @('-RepositoryScenario', $Scenario) }
        $output = & $executable -NoProfile -NonInteractive -File $PSCommandPath -Worker `
            -CsvPath $InputFile -ReportPath $OutputFile -Delimiter $Separator @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Assert-Batch {
    param(
        [string] $Name,
        [object[]] $Entries,
        [string[]] $ExpectedResults,
        [int] $ExpectedExitCode,
        [string] $Separator = ',',
        [string] $Repository,
        [string] $Reference,
        [string[]] $ExpectedGitUrls
    )

    $Entries | Export-Csv -LiteralPath $inputPath -NoTypeInformation -Encoding UTF8 -Delimiter $Separator[0]
    $execution = Invoke-Batch -Separator $Separator -Repository $Repository -Reference $Reference
    if ($execution.ExitCode -ne $ExpectedExitCode) {
        throw "${Name}: expected exit $ExpectedExitCode, got $($execution.ExitCode).`n$($execution.Output)"
    }
    $report = @(Import-Csv -LiteralPath $reportPath -Encoding UTF8 -Delimiter $Separator[0])
    if ($report.Count -ne $ExpectedResults.Count -or
        (($report.Result -join ',') -cne ($ExpectedResults -join ','))) {
        throw "${Name}: unexpected report rows/results.`n$($execution.Output)"
    }
    for ($index = 0; $index -lt $report.Count; $index++) {
        $row = $report[$index]
        $expectedUrl = if ($ExpectedGitUrls) { $ExpectedGitUrls[$index] } else { $Entries[$index].GitUrl }
        if ([int] $row.Row -ne $index + 2 -or $row.GitUrl -cne $expectedUrl) {
            throw "${Name}: row number or GitHub URL was not preserved."
        }
        if ($row.Result -eq 'ERROR') {
            if ([string]::IsNullOrWhiteSpace($row.Error) -or $row.Identical -eq 'True') {
                throw "${Name}: errors must be explicit, not successful comparisons."
            }
        }
        else {
            $expectedAdfHash = (Get-FileHash -LiteralPath $row.AdfPath -Algorithm SHA256).Hash
            $expectedGitHash = (Get-FileHash -LiteralPath $matchingPath -Algorithm SHA256).Hash
            if ($row.AdfSHA256 -cne $expectedAdfHash -or $row.GitSHA256 -cne $expectedGitHash -or
                $row.Identical -ne [string] ($row.Result -eq 'MATCH') -or $row.Error) {
                throw "${Name}: invalid hash, equality flag or error in report."
            }
        }
    }
    if (-not $execution.Output.Contains('MATCH:') -or -not $execution.Output.Contains('Report:')) {
        throw "${Name}: summary or report path missing."
    }
    Write-Output "PASS: $Name"
}

function Assert-Rejected {
    param(
        [string] $Name,
        [string] $InputFile = $inputPath,
        [string] $OutputFile = $reportPath,
        [string] $ExpectedError
    )

    $execution = Invoke-Batch -InputFile $InputFile -OutputFile $OutputFile
    if ($execution.ExitCode -ne 2 -or -not $execution.Output.Contains($ExpectedError)) {
        throw "${Name}: expected exit 2 and '$ExpectedError'.`n$($execution.Output)"
    }
    Write-Output "PASS: $Name"
}

try {
    [System.IO.File]::WriteAllText($matchingPath, $json, $utf8)
    [System.IO.File]::WriteAllText($differentPath, "$json`n", $utf8)
    $match = [pscustomobject]@{ AdfPath = $matchingPath; GitUrl = $url }
    $difference = [pscustomobject]@{ AdfPath = $differentPath; GitUrl = $url }
    $relative = [pscustomobject]@{ AdfPath = [System.IO.Path]::GetFileName($matchingPath); GitUrl = $url }

    Assert-Batch -Name 'All matches and relative path with comma/brackets' `
        -Entries @($match, $relative) -ExpectedResults @('MATCH', 'MATCH') -ExpectedExitCode 0
    Assert-Batch -Name 'Differences without errors' `
        -Entries @($match, $difference) -ExpectedResults @('MATCH', 'DIFFERENT') -ExpectedExitCode 1
    Assert-Batch -Name 'Single row and semicolon delimiter' `
        -Entries @($relative) -ExpectedResults @('MATCH') -ExpectedExitCode 0 -Separator ';'

    $mixedRows = @(
        $match
        $difference
        [pscustomobject]@{ AdfPath = 'missing.json'; GitUrl = $url }
        [pscustomobject]@{ AdfPath = $matchingPath; GitUrl = 'https://github.com/example/pipelines' }
        [pscustomobject]@{ AdfPath = $matchingPath; GitUrl = 'https://github.com/example/pipelines/blob/main/missing.json' }
        [pscustomobject]@{ AdfPath = ''; GitUrl = $url }
        [pscustomobject]@{ AdfPath = $matchingPath; GitUrl = '' }
        $match
    )
    Assert-Batch -Name 'Mixed results, missing fields, HTTP error and continuation' -Entries $mixedRows `
        -ExpectedResults @('MATCH', 'DIFFERENT', 'ERROR', 'ERROR', 'ERROR', 'ERROR', 'ERROR', 'MATCH') -ExpectedExitCode 2

    $match | Export-Csv -LiteralPath $inputPath -NoTypeInformation -Encoding UTF8
    $inputHash = (Get-FileHash -LiteralPath $inputPath).Hash
    Assert-Rejected -Name 'Protect input CSV' -OutputFile $inputPath -ExpectedError 'must not overwrite the input CSV'
    if ((Get-FileHash -LiteralPath $inputPath).Hash -cne $inputHash) {
        throw 'Input CSV was modified.'
    }
    Assert-Rejected -Name 'Protect source JSON' -OutputFile $matchingPath -ExpectedError 'must not overwrite an ADF source file'
    [pscustomobject]@{ AdfPath = [System.IO.Path]::GetFileName($matchingPath); GitUrl = '' } |
        Export-Csv -LiteralPath $inputPath -NoTypeInformation -Encoding UTF8
    Assert-Rejected -Name 'Protect relative source even when URL is missing' -OutputFile $matchingPath -ExpectedError 'must not overwrite an ADF source file'
    if ([System.IO.File]::ReadAllText($matchingPath) -cne $json) {
        throw 'Source JSON was modified.'
    }
    Assert-Rejected -Name 'Missing report directory' -OutputFile (Join-Path $testDirectory 'missing\report.csv') -ExpectedError 'existing directory'
    Assert-Rejected -Name 'Missing input CSV' -InputFile (Join-Path $testDirectory 'missing.csv') -ExpectedError 'missing.csv'

    [System.IO.File]::WriteAllText($inputPath, "AdfPath,GitUrl`r`n", $utf8)
    Assert-Rejected -Name 'Header-only CSV' -ExpectedError 'at least one data row'
    [System.IO.File]::WriteAllText($inputPath, '', $utf8)
    Assert-Rejected -Name 'Empty CSV' -ExpectedError 'at least one data row'
    [System.IO.File]::WriteAllText($inputPath, "Wrong,Columns`r`na,b`r`n", $utf8)
    Assert-Rejected -Name 'Invalid columns' -ExpectedError 'AdfPath and GitUrl columns'
    [System.IO.File]::WriteAllText($inputPath, "AdfPath;GitUrl`r`na;b`r`n", $utf8)
    Assert-Rejected -Name 'Wrong delimiter' -ExpectedError 'Check the delimiter'

    $repository = 'https://github.com/example/pipelines'
    $rootUrl = "$repository/blob/$('a' * 40)/pipeline%20%5Bmatching%5D%2C1.json"
    $nestedUrl = "$repository/blob/$('a' * 40)/folder%20one/pipeline%20different.json"
    $autoMatch = [pscustomobject]@{ AdfPath = $matchingPath }
    $autoDifference = [pscustomobject]@{ AdfPath = $differentPath }
    Assert-Batch -Name 'Repository URL, AdfPath-only CSV, recursive discovery and commit pinning' `
        -Entries @($autoMatch, $autoDifference) -ExpectedResults @('MATCH', 'DIFFERENT') `
        -ExpectedGitUrls @($rootUrl, $nestedUrl) -ExpectedExitCode 1 -Repository $repository
    Assert-Batch -Name 'Explicit branch with slash, git suffix and single row' `
        -Entries @($autoMatch) -ExpectedResults @('MATCH') -ExpectedGitUrls @($rootUrl) -ExpectedExitCode 0 `
        -Repository "$repository.git/" -Reference 'feature/test'
    Assert-Batch -Name 'Repository mode ignores stale GitUrl values' `
        -Entries @($match) -ExpectedResults @('MATCH') -ExpectedGitUrls @($rootUrl) -ExpectedExitCode 0 -Repository $repository

    $unresolved = foreach ($name in @('duplicate.json', 'case.json', 'link.json', 'directory.json', 'not-in-repo.json')) {
        $path = Join-Path $testDirectory $name
        [System.IO.File]::WriteAllText($path, $json, $utf8)
        [pscustomobject]@{ AdfPath = $path }
    }
    Assert-Batch -Name 'Duplicate and missing names are errors; later rows continue' `
        -Entries @($unresolved + $autoMatch) -ExpectedResults @('ERROR', 'ERROR', 'ERROR', 'ERROR', 'ERROR', 'MATCH') `
        -ExpectedGitUrls @('', '', '', '', '', $rootUrl) -ExpectedExitCode 2 -Repository $repository
    $report = @(Import-Csv -LiteralPath $reportPath)
    if (-not $report[0].Error.Contains('Multiple JSON files') -or -not $report[0].Error.Contains('one/duplicate.json') -or
        -not $report[0].Error.Contains('two/duplicate.json') -or -not $report[1].Error.Contains('case-sensitive')) {
        throw 'Ambiguous or case-sensitive discovery errors lack details.'
    }

    $autoMatch | Export-Csv -LiteralPath $inputPath -NoTypeInformation -Encoding UTF8
    foreach ($scenario in @('http-error', 'truncated')) {
        if (Test-Path -LiteralPath $reportPath) {
            Remove-Item -LiteralPath $reportPath -Force
        }
        $execution = Invoke-Batch -Repository $repository -Scenario $scenario
        $expectedError = if ($scenario -eq 'truncated') { 'truncated repository tree' } else { 'repository access denied' }
        if ($execution.ExitCode -ne 2 -or -not $execution.Output.Contains($expectedError) -or
            (Test-Path -LiteralPath $reportPath)) {
            throw "Discovery $scenario must fail explicitly without a success report.`n$($execution.Output)"
        }
        Write-Output "PASS: Repository discovery $scenario"
    }
    $execution = Invoke-Batch -Repository 'https://example.com/example/pipelines'
    if ($execution.ExitCode -ne 2 -or -not $execution.Output.Contains('RepoUrl must be')) {
        throw 'External repository URLs must be rejected.'
    }
    Write-Output 'PASS: Reject external repository host'
    $execution = Invoke-Batch -Reference 'feature/test'
    if ($execution.ExitCode -ne 2 -or -not $execution.Output.Contains('GitRef requires RepoUrl')) {
        throw 'GitRef must require RepoUrl.'
    }
    Write-Output 'PASS: GitRef requires repository URL'

    $templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'pipelines-template.csv'
    $template = @(Import-Csv -LiteralPath $templatePath)
    if ($template.Count -lt 1 -or $template[0].PSObject.Properties.Name -notcontains 'AdfPath') {
        throw 'The supplied template does not have the required columns and sample row.'
    }
    Write-Output 'PASS: Fillable template columns and example'
}
finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
