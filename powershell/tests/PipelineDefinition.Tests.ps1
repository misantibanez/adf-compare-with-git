#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $root 'PipelineDefinition.cs')
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('adf-definition-' + [guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($directory)
$firstPath = Join-Path $directory 'first.json'
$secondPath = Join-Path $directory 'second.json'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$base = '{"name":"pipeline1","properties":{"activities":[{"name":"Wait1","type":"Wait","dependsOn":[],"userProperties":[],"typeProperties":{"waitTimeInSeconds":1}}],"annotations":[],"lastPublishTime":"2026-10-02T15:56:56Z"},"type":"Microsoft.DataFactory/factories/pipelines"}'

function Assert-EqualDefinition {
    param([string] $Name, [string] $First, [string] $Second, [bool] $Expected = $true)

    [System.IO.File]::WriteAllText($firstPath, $First, $utf8)
    [System.IO.File]::WriteAllText($secondPath, $Second, $utf8)
    $firstHash = [AdfCompare.PipelineDefinition]::HashFile($firstPath)
    $secondHash = [AdfCompare.PipelineDefinition]::HashFile($secondPath)
    if (($firstHash -ceq $secondHash) -ne $Expected -or $firstHash -notmatch '^[A-F0-9]{64}$') {
        throw "${Name}: unexpected definition hash comparison."
    }
    Write-Output "PASS: $Name"
}

function Assert-InvalidDefinition {
    param([string] $Name, [string] $Json)

    [System.IO.File]::WriteAllText($firstPath, $Json, $utf8)
    $failed = $false
    try { $null = [AdfCompare.PipelineDefinition]::HashFile($firstPath) }
    catch { $failed = $true }
    if (-not $failed) { throw "${Name}: invalid JSON was accepted." }
    Write-Output "PASS: $Name"
}

try {
    $export = ('{"id":"/factories/other/pipelines/pipeline1","etag":"different",' + $base.Substring(1)).
        Replace('2026-10-02T15:56:56Z', '2030-01-01T10:00:00Z')
    Assert-EqualDefinition 'UI vs API metadata and publish time' $base $export
    $noMetadata = $base.Replace(',"type":"Microsoft.DataFactory/factories/pipelines"', '').
        Replace(',"lastPublishTime":"2026-10-02T15:56:56Z"', '')
    Assert-EqualDefinition 'Missing optional metadata' $base $noMetadata
    Assert-EqualDefinition 'Changed activity value' $base ($base.Replace('"waitTimeInSeconds":1', '"waitTimeInSeconds":2')) $false
    Assert-EqualDefinition 'Changed activity type is not metadata' $base ($base.Replace('"type":"Wait"', '"type":"Other"')) $false
    Assert-EqualDefinition 'Changed pipeline name' $base ($base.Replace('"pipeline1"', '"pipeline2"')) $false
    Assert-EqualDefinition 'Changed dependencies' $base ($base.Replace('"dependsOn":[]', '"dependsOn":[{"activity":"Another","dependencyConditions":["Succeeded"]}]')) $false
    Assert-EqualDefinition 'Additional unknown root field' $base ($base.Replace('{"name":', '{"future":true,"name":')) $false
    Assert-EqualDefinition 'Unknown properties are preserved' $base ($base.Replace('"annotations":[]', '"annotations":[],"future":{"x":1}')) $false
    Assert-EqualDefinition 'Empty API pipeline metric equals absent policy' `
        '{"name":"p","properties":{"activities":[],"policy":{"elapsedTimeMetric":{}}}}' `
        '{"name":"p","properties":{"activities":[]}}'
    Assert-EqualDefinition 'Empty pipeline policy equals absent policy' `
        '{"name":"p","properties":{"policy":{}}}' '{"name":"p","properties":{}}'
    Assert-EqualDefinition 'Empty metric removed without losing other policy fields' `
        '{"name":"p","properties":{"policy":{"elapsedTimeMetric":{},"future":1}}}' `
        '{"name":"p","properties":{"policy":{"future":1}}}'
    Assert-EqualDefinition 'Configured metric is preserved' `
        '{"name":"p","properties":{"policy":{"elapsedTimeMetric":{"duration":"00:01:00"}}}}' `
        '{"name":"p","properties":{}}' $false
    Assert-EqualDefinition 'Other policy values are preserved' `
        '{"name":"p","properties":{"policy":{"elapsedTimeMetric":{},"future":1}}}' `
        '{"name":"p","properties":{}}' $false
    Assert-EqualDefinition 'Null policy differs from absent' `
        '{"name":"p","properties":{"policy":null}}' '{"name":"p","properties":{}}' $false
    Assert-EqualDefinition 'Null metric differs from absent' `
        '{"name":"p","properties":{"policy":{"elapsedTimeMetric":null}}}' '{"name":"p","properties":{}}' $false
    Assert-EqualDefinition 'Activity policy is never removed' `
        '{"name":"p","properties":{"activities":[{"policy":{"elapsedTimeMetric":{}}}]}}' `
        '{"name":"p","properties":{"activities":[{}]}}' $false
    Assert-EqualDefinition 'Nested id, etag and lastPublishTime preserved' `
        '{"name":"p","properties":{"nested":{"id":"a","etag":"v","lastPublishTime":"one"}}}' `
        '{"name":"p","properties":{"nested":{"id":"b","etag":"v","lastPublishTime":"one"}}}' $false
    Assert-EqualDefinition 'Object property order' `
        '{"name":"p","properties":{"z":1,"a":{"b":true,"a":null}}}' `
        '{"properties":{"a":{"a":null,"b":true},"z":1},"name":"p"}'
    Assert-EqualDefinition 'Array order preserved' `
        '{"name":"p","properties":{"activities":[{"name":"a"},{"name":"b"}]}}' `
        '{"name":"p","properties":{"activities":[{"name":"b"},{"name":"a"}]}}' $false
    Assert-EqualDefinition 'Array shape preserved' '{"name":"p","properties":{"a":[]}}' '{"name":"p","properties":{"a":null}}' $false
    Assert-EqualDefinition 'Missing distinct from null' '{"name":"p","properties":{}}' '{"name":"p","properties":{"x":null}}' $false
    Assert-EqualDefinition 'String distinct from number' '{"name":"p","properties":{"x":"1"}}' '{"name":"p","properties":{"x":1}}' $false
    Assert-EqualDefinition 'Object property case preserved' '{"name":"p","properties":{"A":1,"a":2}}' '{"name":"p","properties":{"A":2,"a":1}}' $false
    Assert-EqualDefinition 'String whitespace preserved' '{"name":"p","properties":{"sql":"select  1"}}' '{"name":"p","properties":{"sql":"select 1"}}' $false
    Assert-EqualDefinition 'Date-like strings are not coerced' '{"name":"p","properties":{"date":"2026-01-01T00:00:00Z"}}' '{"name":"p","properties":{"date":"2026-01-01T01:00:00+01:00"}}' $false
    Assert-EqualDefinition 'Unicode and escape equivalence' '{"name":"p","properties":{"s":"\u0061\/\n"}}' "{`"name`":`"p`",`"properties`":{`"s`":`"a/\n`"}}"
    Assert-EqualDefinition 'Equivalent numeric notations' '{"name":"p","properties":{"x":1.00,"y":1e3,"z":-0}}' '{"name":"p","properties":{"x":1,"y":1000,"z":0.0}}'
    Assert-EqualDefinition 'Large integers never rounded' '{"name":"p","properties":{"x":9007199254740992}}' '{"name":"p","properties":{"x":9007199254740993}}' $false
    Assert-EqualDefinition 'Precise decimals never rounded' '{"name":"p","properties":{"x":0.1234567890123456789012345678901}}' '{"name":"p","properties":{"x":0.1234567890123456789012345678902}}' $false
    Assert-EqualDefinition 'Empty array distinct from singleton' '{"name":"p","properties":{"x":[]}}' '{"name":"p","properties":{"x":[null]}}' $false
    foreach ($case in @(
        @('Missing name', '{"properties":{}}'),
        @('Invalid properties', '{"name":"p","properties":[]}'),
        @('Invalid root type', '{"name":"p","properties":{},"type":"Other"}'),
        @('Duplicate keys', '{"name":"p","properties":{"a":1,"a":2}}'),
        @('Escaped duplicate keys', '{"name":"p","properties":{"a":1,"\u0061":2}}'),
        @('Trailing comma', '{"name":"p","properties":{"a":1,}}'),
        @('Trailing data', '{"name":"p","properties":{}} true'),
        @('Invalid number', '{"name":"p","properties":{"a":01}}'),
        @('Invalid JSON', '{bad json'),
        @('Exponent beyond supported range', '{"name":"p","properties":{"a":1e999999999999999999999}}')
    )) {
        Assert-InvalidDefinition $case[0] $case[1]
    }

    [System.IO.File]::WriteAllText($firstPath, $base, [System.Text.UTF8Encoding]::new($true))
    [System.IO.File]::WriteAllText($secondPath, ($export + "`r`n"), $utf8)
    $comparisonScript = Join-Path $root 'Compare-AdfPipeline.ps1'
    $result = & $comparisonScript -AdfPath $firstPath -GitPath $secondPath -ComparisonMode PipelineDefinition -PassThru
    if ($LASTEXITCODE -ne 0 -or $result.Result -ne 'MATCH' -or $result.BytesIdentical -ne $false -or
        $result.DefinitionIdentical -ne $true -or $result.AdfSHA256 -ceq $result.GitSHA256 -or
        $result.AdfDefinitionSHA256 -cne $result.GitDefinitionSHA256 -or
        $result.NormalizationVersion -cne 'PipelineDefinition-v2') {
        throw 'Individual normalized comparison did not preserve original hash evidence.'
    }
    Write-Output 'PASS: Individual mode, BOM, CRLF and original/normalized report hashes'
    $result = & $comparisonScript -AdfPath $firstPath -GitPath $secondPath -PassThru
    if ($LASTEXITCODE -ne 1 -or $result.Result -ne 'DIFFERENT' -or $result.DefinitionIdentical -ne $null) {
        throw 'ExactBytes default changed.'
    }
    Write-Output 'PASS: ExactBytes remains the default'
    [System.IO.File]::WriteAllText($secondPath, '{invalid', $utf8)
    $ErrorActionPreference = 'Continue'
    $result = & $comparisonScript -AdfPath $firstPath -GitPath $secondPath -ComparisonMode PipelineDefinition -PassThru 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 2 -or $result.Result -ne 'ERROR' -or -not $result.Error -or
        -not $result.AdfSHA256 -or -not $result.GitSHA256 -or $result.Identical -ne $null) {
        throw 'Invalid definitions must return ERROR and retain original file hashes.'
    }
    Write-Output 'PASS: Invalid JSON returns ERROR with original hash evidence'
}
finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
