[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Tag,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSha
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if ($Tag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
    throw 'Tag must match vX.Y.Z'
}

$head = (git rev-parse HEAD).Trim()
$tagCommit = (git rev-parse "$Tag`^{commit}").Trim()
if ($head -cne $ExpectedSha -or $tagCommit -cne $ExpectedSha) {
    throw 'The checkout, release tag, and expected commit do not match'
}

$remoteRefs = @{}
foreach ($line in @(git ls-remote origin "refs/tags/$Tag" "refs/tags/$Tag`^{}")) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2) {
        $remoteRefs[$parts[1]] = $parts[0]
    }
}
$peeledName = "refs/tags/$Tag`^{}"
$tagName = "refs/tags/$Tag"
$remoteSha = if ($remoteRefs.ContainsKey($peeledName)) {
    $remoteRefs[$peeledName]
} elseif ($remoteRefs.ContainsKey($tagName)) {
    $remoteRefs[$tagName]
} else {
    $null
}
if ([string]::IsNullOrWhiteSpace($remoteSha) -or $remoteSha -cne $ExpectedSha) {
    throw 'The remote tag is missing or moved after the workflow started'
}

Write-Host "Release tag and commit are immutable for this run."
