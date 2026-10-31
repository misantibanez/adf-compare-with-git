#Requires -Version 5.1

function Get-GitHubRequestHeaders {
    param([string] $Accept = 'application/vnd.github+json')

    $headers = @{
        Accept = $Accept
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'adf-compare-with-git'
    }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($token) {
        $headers.Authorization = "Bearer $token"
    }
    return $headers
}

function Get-GitHubRepositoryFiles {
    param(
        [string] $RepoUrl,
        [string] $GitRef
    )

    $uri = $null
    if (-not [uri]::TryCreate($RepoUrl, [System.UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or
        $uri.AbsolutePath -notmatch '^/([^/]+)/([^/]+?)(?:\.git)?/?$') {
        throw [System.ArgumentException]::new('RepoUrl must be an HTTPS repository URL: https://github.com/OWNER/REPO.')
    }

    $owner = [uri]::EscapeDataString([uri]::UnescapeDataString($Matches[1]))
    $repository = [uri]::EscapeDataString([uri]::UnescapeDataString($Matches[2]))
    $apiUrl = "https://api.github.com/repos/$owner/$repository"
    $request = @{
        Headers = Get-GitHubRequestHeaders
        TimeoutSec = 60
        MaximumRedirection = 0
    }
    if ([string]::IsNullOrWhiteSpace($GitRef)) {
        $metadata = Invoke-RestMethod -Uri $apiUrl @request
        if ([string]::IsNullOrWhiteSpace($metadata.default_branch)) {
            throw [System.IO.InvalidDataException]::new('GitHub did not return a default branch.')
        }
        $GitRef = $metadata.default_branch
    }

    $reference = [uri]::EscapeDataString($GitRef)
    $commit = Invoke-RestMethod -Uri "$apiUrl/commits/$reference" @request
    if ($commit.sha -notmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$' -or
        $commit.commit.tree.sha -notmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$') {
        throw [System.IO.InvalidDataException]::new('GitHub did not return a valid commit and tree.')
    }
    $tree = Invoke-RestMethod -Uri "$apiUrl/git/trees/$($commit.commit.tree.sha)?recursive=1" @request
    if ($tree.truncated -isnot [bool] -or $tree.PSObject.Properties.Name -notcontains 'tree') {
        throw [System.IO.InvalidDataException]::new('GitHub did not return a valid repository tree.')
    }
    if ($tree.truncated) {
        throw [System.IO.InvalidDataException]::new('GitHub returned a truncated repository tree. Cannot safely search all files.')
    }

    $filesByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $tree.tree) {
        if ($item.type -eq 'blob' -and $item.mode -ne '120000' -and $item.path -like '*.json') {
            $name = ($item.path -split '/')[-1]
            if (-not $filesByName.ContainsKey($name)) {
                $filesByName[$name] = [System.Collections.Generic.List[string]]::new()
            }
            $filesByName[$name].Add($item.path)
        }
    }
    [pscustomobject]@{
        WebUrl = "https://github.com/$owner/$repository"
        Commit = $commit.sha
        FilesByName = $filesByName
    }
}
