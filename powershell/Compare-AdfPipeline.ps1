#Requires -Version 5.1
<#
.SYNOPSIS
Compares ADF pipeline files by exact bytes or normalized pipeline definition.
.DESCRIPTION
Returns exit code 0 for identical SHA-256 hashes, 1 for different hashes,
and 2 when a file cannot be read, downloaded or normalized.
ExactBytes is the default and does not parse JSON.
Use PassThru to return a structured result, including errors, for batch callers.
#>
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $AdfPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [ValidateNotNullOrEmpty()]
    [string] $GitPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'GitHub')]
    [ValidateNotNullOrEmpty()]
    [string] $GitUrl,

    [switch] $PassThru,

    [ValidateSet('ExactBytes', 'PipelineDefinition')]
    [string] $ComparisonMode = 'ExactBytes'
)

$ErrorActionPreference = 'Stop'
$downloadPath = $null
$exitCode = 2
$result = [pscustomobject]@{
    AdfPath   = $AdfPath
    GitPath   = $GitPath
    GitUrl    = $GitUrl
    AdfSHA256 = $null
    GitSHA256 = $null
    ComparisonMode = $ComparisonMode
    NormalizationVersion = $null
    AdfDefinitionSHA256 = $null
    GitDefinitionSHA256 = $null
    BytesIdentical = $null
    DefinitionIdentical = $null
    Identical = $null
    Result    = 'ERROR'
    Error     = $null
}

try {
    $paths = @($AdfPath)
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        $paths += $GitPath
    }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new("File not found or not a file: $path")
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'GitHub') {
        $uri = $null
        if (-not [uri]::TryCreate($GitUrl, [System.UriKind]::Absolute, [ref] $uri) -or
            $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or
            -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or
            $uri.AbsolutePath -notmatch '^/([^/]+)/([^/]+)/blob/([^/]+)/(.+\.json)$') {
            throw [System.ArgumentException]::new('GitUrl must be an HTTPS file URL: https://github.com/OWNER/REPO/blob/REF/PATH.json (no query string). Encode slashes in REF as %2F.')
        }

        $owner = [uri]::EscapeDataString([uri]::UnescapeDataString($Matches[1]))
        $repository = [uri]::EscapeDataString([uri]::UnescapeDataString($Matches[2]))
        $reference = [uri]::EscapeDataString([uri]::UnescapeDataString($Matches[3]))
        $filePath = ($Matches[4] -split '/' | ForEach-Object {
            [uri]::EscapeDataString([uri]::UnescapeDataString($_))
        }) -join '/'
        $apiUrl = "https://api.github.com/repos/$owner/$repository/contents/${filePath}?ref=$reference"
        . (Join-Path $PSScriptRoot 'GitHub.Helpers.ps1')
        $headers = Get-GitHubRequestHeaders -Accept 'application/vnd.github.raw+json'

        $downloadPath = [System.IO.Path]::GetTempFileName()
        $response = Invoke-WebRequest -Uri $apiUrl -Headers $headers -OutFile $downloadPath `
            -PassThru -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0
        $contentType = [string] ($response.Headers['Content-Type'] -join ',')
        if ($contentType -notmatch '^application/vnd\.github\.raw(\+json)?(?:;|$)') {
            throw [System.IO.InvalidDataException]::new('GitHub did not return raw file content. Verify that the URL points to a file, not a directory.')
        }
        $GitPath = $downloadPath
    }

    $adfHash = Get-FileHash -LiteralPath $AdfPath -Algorithm SHA256
    $gitHash = Get-FileHash -LiteralPath $GitPath -Algorithm SHA256
    $result.AdfPath = $adfHash.Path
    $result.GitPath = if ($GitUrl) { $null } else { $gitHash.Path }
    $result.AdfSHA256 = $adfHash.Hash
    $result.GitSHA256 = $gitHash.Hash
    $result.BytesIdentical = $adfHash.Hash -ceq $gitHash.Hash
    if ($ComparisonMode -eq 'PipelineDefinition') {
        if (-not ('AdfCompare.PipelineDefinition' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'PipelineDefinition.cs')
        }
        $result.NormalizationVersion = [AdfCompare.PipelineDefinition]::Version
        $result.AdfDefinitionSHA256 = [AdfCompare.PipelineDefinition]::HashFile($adfHash.Path)
        $result.GitDefinitionSHA256 = [AdfCompare.PipelineDefinition]::HashFile($gitHash.Path)
        $result.DefinitionIdentical = $result.AdfDefinitionSHA256 -ceq $result.GitDefinitionSHA256
        $result.Identical = $result.DefinitionIdentical
    }
    else {
        $result.Identical = $result.BytesIdentical
    }
    $result.Result = if ($result.Identical) { 'MATCH' } else { 'DIFFERENT' }
    $exitCode = if ($result.Identical) { 0 } else { 1 }
}
catch {
    $result.Error = $_.Exception.Message
    Write-Error -Message ("Comparison failed: {0}" -f $_.Exception.Message) -ErrorAction Continue
}
finally {
    if ($downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force
    }
}

if ($PassThru) {
    $result
}
elseif ($exitCode -ne 2) {
    $result | Format-List
}

exit $exitCode
