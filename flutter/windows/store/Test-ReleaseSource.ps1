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
    throw 'Release version must match vX.Y.Z'
}

$head = (git rev-parse HEAD).Trim()
if ($head -cne $ExpectedSha) {
    throw 'The checkout does not match the source selected by this workflow run'
}

Write-Host "Release source $ExpectedSha matches $Tag."
