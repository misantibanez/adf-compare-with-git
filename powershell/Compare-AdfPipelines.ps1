#Requires -Version 5.1
<#
.SYNOPSIS
Compares CSV-listed ADF files against explicit GitHub URLs or a repository.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $CsvPath,

    [ValidateNotNullOrEmpty()]
    [string] $ReportPath = '.\comparison-results.csv',

    [ValidateSet(',', ';')]
    [string] $Delimiter = ',',

    [ValidateNotNullOrEmpty()]
    [string] $RepoUrl,

    [ValidateNotNullOrEmpty()]
    [string] $GitRef,

    [ValidateSet('ExactBytes', 'PipelineDefinition')]
    [string] $ComparisonMode = 'ExactBytes'
)

$ErrorActionPreference = 'Stop'

try {
    if ($GitRef -and -not $RepoUrl) {
        throw [System.ArgumentException]::new('GitRef requires RepoUrl.')
    }
    $csvFile = Get-Item -LiteralPath $CsvPath
    if ($csvFile -isnot [System.IO.FileInfo]) {
        throw [System.ArgumentException]::new('CsvPath must point to a CSV file.')
    }
    $reportFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
    if ($reportFullPath -eq $csvFile.FullName) {
        throw [System.ArgumentException]::new('ReportPath must not overwrite the input CSV.')
    }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $reportFullPath) -PathType Container) -or
        (Test-Path -LiteralPath $reportFullPath -PathType Container)) {
        throw [System.ArgumentException]::new('ReportPath must be a file in an existing directory.')
    }

    $rows = @(Import-Csv -LiteralPath $csvFile.FullName -Delimiter $Delimiter[0] -Encoding UTF8)
    if ($rows.Count -eq 0) {
        throw [System.ArgumentException]::new('The CSV must contain at least one data row.')
    }
    $columns = $rows[0].PSObject.Properties.Name
    if ($RepoUrl -and $columns -notcontains 'AdfPath') {
        throw [System.ArgumentException]::new('The CSV must contain an AdfPath column. Check the delimiter.')
    }
    if (-not $RepoUrl -and ($columns -notcontains 'AdfPath' -or $columns -notcontains 'GitUrl')) {
        throw [System.ArgumentException]::new('The CSV must contain AdfPath and GitUrl columns. Check the delimiter.')
    }

    $entries = for ($index = 0; $index -lt $rows.Count; $index++) {
        $entry = [pscustomobject]@{
            Row = $index + 2
            AdfPath = $rows[$index].AdfPath
            GitUrl = if ($RepoUrl) { $null } else { $rows[$index].GitUrl }
            Error = $null
        }
        try {
            if ([string]::IsNullOrWhiteSpace($entry.AdfPath)) {
                throw [System.ArgumentException]::new('AdfPath is required for every row.')
            }
            $path = $entry.AdfPath
            if (-not [System.IO.Path]::IsPathRooted($path)) {
                $path = Join-Path $csvFile.DirectoryName $path
            }
            $entry.AdfPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
            if (-not $RepoUrl -and [string]::IsNullOrWhiteSpace($entry.GitUrl)) {
                throw [System.ArgumentException]::new('GitUrl is required for every row.')
            }
        }
        catch {
            $entry.Error = $_.Exception.Message
        }
        $entry
    }
    foreach ($entry in $entries) {
        if ($entry.AdfPath -eq $reportFullPath) {
            throw [System.ArgumentException]::new('ReportPath must not overwrite an ADF source file.')
        }
    }

    if ($RepoUrl) {
        . (Join-Path $PSScriptRoot 'GitHub.Helpers.ps1')
        $repositoryFiles = Get-GitHubRepositoryFiles -RepoUrl $RepoUrl -GitRef $GitRef
        Write-Host "Repository snapshot: $($repositoryFiles.Commit)"
    }

    $results = foreach ($entry in $entries) {
        $comparison = $null
        try {
            if ($entry.Error) {
                throw [System.ArgumentException]::new($entry.Error)
            }
            if ($RepoUrl) {
                $name = [System.IO.Path]::GetFileName($entry.AdfPath)
                if (-not $repositoryFiles.FilesByName.ContainsKey($name)) {
                    throw [System.IO.FileNotFoundException]::new("No JSON named '$name' was found in the repository (case-sensitive search).")
                }
                $candidates = $repositoryFiles.FilesByName[$name]
                if ($candidates.Count -ne 1) {
                    throw [System.ArgumentException]::new("Multiple JSON files named '$name' were found: $($candidates -join ', '). Use explicit GitUrl mode to select one.")
                }
                $remotePath = ($candidates[0] -split '/' | ForEach-Object {
                    [uri]::EscapeDataString($_)
                }) -join '/'
                $entry.GitUrl = "$($repositoryFiles.WebUrl)/blob/$($repositoryFiles.Commit)/$remotePath"
            }
            $comparison = & (Join-Path $PSScriptRoot 'Compare-AdfPipeline.ps1') `
                -AdfPath $entry.AdfPath -GitUrl $entry.GitUrl -ComparisonMode $ComparisonMode -PassThru
        }
        catch {
            $comparison = [pscustomobject]@{
                AdfSHA256 = $null
                GitSHA256 = $null
                Identical = $null
                Result = 'ERROR'
                Error = $_.Exception.Message
            }
        }
        if ($comparison.Result -eq 'ERROR') {
            Write-Warning ("Row {0}: {1}" -f $entry.Row, $comparison.Error)
        }
        [pscustomobject]@{
            Row = $entry.Row
            AdfPath = $entry.AdfPath
            GitUrl = $entry.GitUrl
            AdfSHA256 = $comparison.AdfSHA256
            GitSHA256 = $comparison.GitSHA256
            ComparisonMode = $ComparisonMode
            NormalizationVersion = $comparison.NormalizationVersion
            AdfDefinitionSHA256 = $comparison.AdfDefinitionSHA256
            GitDefinitionSHA256 = $comparison.GitDefinitionSHA256
            BytesIdentical = $comparison.BytesIdentical
            DefinitionIdentical = $comparison.DefinitionIdentical
            Identical = $comparison.Identical
            Result = $comparison.Result
            Error = $comparison.Error
        }
    }

    $results | Export-Csv -LiteralPath $reportFullPath -Delimiter $Delimiter[0] -NoTypeInformation -Encoding UTF8
    $results | Format-Table Row, Result, AdfPath -AutoSize
    $matches = @($results | Where-Object Result -eq 'MATCH').Count
    $differences = @($results | Where-Object Result -eq 'DIFFERENT').Count
    $errors = @($results | Where-Object Result -eq 'ERROR').Count
    Write-Host "MATCH: $matches | DIFFERENT: $differences | ERROR: $errors"
    Write-Host "Report: $reportFullPath"

    if ($errors -gt 0) {
        exit 2
    }
    if ($differences -gt 0) {
        exit 1
    }
    exit 0
}
catch {
    Write-Error -Message ("Batch comparison failed: {0}" -f $_.Exception.Message) -ErrorAction Continue
    exit 2
}
