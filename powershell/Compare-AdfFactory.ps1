#Requires -Version 5.1
<#
.SYNOPSIS
Exports published ADF pipeline responses and compares them with GitHub.
.DESCRIPTION
Requires Azure CLI 2.54+ and an authenticated identity with read access to ADF.
Returns 0 for all matches, 1 for differences, or 2 for any error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $FactoryResourceId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $RepoUrl,

    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory = '.\adf-comparison',

    [ValidateNotNullOrEmpty()]
    [string] $GitRef,

    [ValidateSet(',', ';')]
    [string] $Delimiter = ',',

    [ValidateSet('ExactBytes', 'PipelineDefinition')]
    [string] $ComparisonMode = 'ExactBytes'
)

$ErrorActionPreference = 'Stop'
$script:armToken = $null
$script:armTokenExpiry = [System.DateTimeOffset]::MinValue

function Get-ArmRequestHeaders {
    if ($script:armTokenExpiry -le [System.DateTimeOffset]::UtcNow.AddMinutes(5)) {
        $tokenJson = & az account get-access-token --subscription $subscriptionId `
            --resource 'https://management.azure.com/' --output json
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new('Azure authentication failed. Run az login with an identity that can read the specified factory.')
        }
        try {
            $token = ($tokenJson -join "`n") | ConvertFrom-Json
        }
        catch {
            throw [System.IO.InvalidDataException]::new('Azure CLI did not return valid access-token JSON. Run az login again.')
        }
        $expiry = 0L
        if ([string]::IsNullOrWhiteSpace($token.accessToken) -or
            -not [long]::TryParse([string] $token.expires_on, [ref] $expiry)) {
            throw [System.IO.InvalidDataException]::new('Azure CLI did not return an access token and expires_on. Azure CLI 2.54+ is required.')
        }
        $script:armTokenExpiry = [System.DateTimeOffset]::FromUnixTimeSeconds($expiry)
        if ($script:armTokenExpiry -le [System.DateTimeOffset]::UtcNow) {
            throw [System.InvalidOperationException]::new('Azure CLI returned an expired token. Run az login again.')
        }
        $script:armToken = $token.accessToken
    }

    return @{
        Authorization = "Bearer $script:armToken"
        Accept = 'application/json'
    }
}

try {
    if ($FactoryResourceId -notmatch '^/subscriptions/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/resourceGroups/([^/]+)/providers/Microsoft\.DataFactory/factories/([a-z0-9][a-z0-9-]{1,61}[a-z0-9])/?$') {
        throw [System.ArgumentException]::new('FactoryResourceId must identify an Azure Data Factory: /subscriptions/GUID/resourceGroups/GROUP/providers/Microsoft.DataFactory/factories/FACTORY.')
    }
    $subscriptionId = $Matches[1]
    $resourceGroup = $Matches[2]
    $factoryName = $Matches[3]
    $encodedGroup = [uri]::EscapeDataString($resourceGroup)
    $encodedFactory = [uri]::EscapeDataString($factoryName)
    $factoryUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$encodedGroup/providers/Microsoft.DataFactory/factories/$encodedFactory"
    $listUrl = "$factoryUrl/pipelines?api-version=2018-06-01"
    $listPath = ([uri] $listUrl).AbsolutePath
    $pageUrl = $listUrl
    $visitedPages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $pipelineNames = [System.Collections.Generic.List[string]]::new()
    $uniqueNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    do {
        $pageUri = $null
        if (-not [uri]::TryCreate($pageUrl, [System.UriKind]::Absolute, [ref] $pageUri) -or
            $pageUri.Scheme -ne 'https' -or $pageUri.Host -ne 'management.azure.com' -or
            -not $pageUri.IsDefaultPort -or $pageUri.UserInfo -or $pageUri.Fragment -or
            $pageUri.AbsolutePath -ne $listPath) {
            throw [System.IO.InvalidDataException]::new('ADF returned an invalid pagination URL. Only the same factory on management.azure.com is allowed.')
        }
        if (-not $visitedPages.Add($pageUri.AbsoluteUri)) {
            throw [System.IO.InvalidDataException]::new('ADF returned a repeated pagination URL.')
        }
        $page = Invoke-RestMethod -Uri $pageUri.AbsoluteUri -Headers (Get-ArmRequestHeaders) `
            -TimeoutSec 60 -MaximumRedirection 0
        if ($page.value -isnot [System.Array]) {
            throw [System.IO.InvalidDataException]::new('ADF did not return a pipeline list in value.')
        }
        foreach ($pipeline in $page.value) {
            $name = $pipeline.name
            if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
                $name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                $name.EndsWith('.') -or $name.EndsWith(' ') -or $name.Length -gt 250 -or
                $name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                throw [System.IO.InvalidDataException]::new("ADF returned a pipeline name that cannot be safely exported on Windows: '$name'.")
            }
            if (-not $uniqueNames.Add($name)) {
                throw [System.IO.InvalidDataException]::new("Duplicate pipeline name or Windows filename collision: '$name'.")
            }
            $pipelineNames.Add($name)
        }
        $pageUrl = $page.nextLink
    } while (-not [string]::IsNullOrWhiteSpace($pageUrl))

    if ($pipelineNames.Count -eq 0) {
        throw [System.InvalidOperationException]::new('No published pipelines were found. There is nothing to export or compare.')
    }

    $outputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $runName = '{0}-{1}-{2}' -f $factoryName, (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $outputRoot $runName
    $exportsDirectory = Join-Path $runDirectory 'exports'
    $null = [System.IO.Directory]::CreateDirectory($exportsDirectory)
    $manifestPath = Join-Path $runDirectory 'pipelines.csv'
    $exportStatusPath = Join-Path $runDirectory 'export-status.csv'
    $reportPath = Join-Path $runDirectory 'comparison-results.csv'
    Write-Host "Factory: $factoryName | Published pipelines: $($pipelineNames.Count)"
    Write-Host "Run directory: $runDirectory"
    if ($ComparisonMode -eq 'ExactBytes') {
        Write-Warning 'Exact-byte comparison: exported responses include ARM metadata and original response formatting. Equivalent pipeline logic may still produce DIFFERENT.'
    }
    else {
        Write-Host 'PipelineDefinition: comparing normalized definitions; exported response bytes remain unchanged.'
    }

    $exportResults = @(foreach ($name in $pipelineNames) {
        $exportPath = Join-Path $exportsDirectory "$name.json"
        $temporaryPath = $null
        $exportError = $null
        try {
            $encodedName = [uri]::EscapeDataString($name)
            $pipelineUrl = "$factoryUrl/pipelines/${encodedName}?api-version=2018-06-01"
            $temporaryPath = [System.IO.Path]::GetTempFileName()
            $response = Invoke-WebRequest -Uri $pipelineUrl -Headers (Get-ArmRequestHeaders) `
                -OutFile $temporaryPath -PassThru -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0
            $contentType = [string] ($response.Headers['Content-Type'] -join ',')
            if ($contentType -notmatch '^application/json(?:;|$)') {
                throw [System.IO.InvalidDataException]::new('ADF did not return application/json.')
            }
            $definition = [System.IO.File]::ReadAllText($temporaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($definition.name -cne $name -or $definition.properties -isnot [pscustomobject]) {
                throw [System.IO.InvalidDataException]::new("ADF did not return the expected pipeline definition for '$name'.")
            }
            # Inspecting the definition must not reserialize or change the downloaded bytes.
            [System.IO.File]::Move($temporaryPath, $exportPath)
        }
        catch {
            $exportError = $_.Exception.Message
            Write-Warning ("Export failed for '{0}': {1}" -f $name, $exportError)
        }
        finally {
            if ($temporaryPath -and [System.IO.File]::Exists($temporaryPath)) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
        [pscustomobject]@{
            PipelineName = $name
            AdfPath = $exportPath
            Result = if ($exportError) { 'ERROR' } else { 'EXPORTED' }
            Error = $exportError
        }
    })

    $exportResults | Select-Object AdfPath |
        Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter[0]
    $exportResults |
        Export-Csv -LiteralPath $exportStatusPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter[0]
    Write-Host "Generated template: $manifestPath"
    Write-Host "Export status: $exportStatusPath"

    $comparisonOptions = @{
        CsvPath = $manifestPath
        RepoUrl = $RepoUrl
        ReportPath = $reportPath
        Delimiter = $Delimiter
        ComparisonMode = $ComparisonMode
    }
    if ($GitRef) {
        $comparisonOptions.GitRef = $GitRef
    }
    & (Join-Path $PSScriptRoot 'Compare-AdfPipelines.ps1') @comparisonOptions
    $comparisonExitCode = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw [System.IO.IOException]::new('Comparison did not produce a report. Exports and their status remain in the run directory.')
    }
    $report = @(Import-Csv -LiteralPath $reportPath -Encoding UTF8 -Delimiter $Delimiter[0])
    if ($report.Count -ne $exportResults.Count) {
        throw [System.IO.InvalidDataException]::new('The comparison report does not contain every listed pipeline.')
    }
    $exportFailures = @($exportResults | Where-Object Result -eq 'ERROR').Count
    if ($exportFailures -gt 0) {
        for ($index = 0; $index -lt $report.Count; $index++) {
            if ($exportResults[$index].Result -eq 'ERROR') {
                $report[$index].Result = 'ERROR'
                $report[$index].Error = "ADF export failed: $($exportResults[$index].Error)"
            }
        }
        $report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter[0]
        exit 2
    }
    exit $comparisonExitCode
}
catch {
    Write-Error -Message ("ADF workflow failed: {0}" -f $_.Exception.Message) -ErrorAction Continue
    exit 2
}
finally {
    $script:armToken = $null
}
