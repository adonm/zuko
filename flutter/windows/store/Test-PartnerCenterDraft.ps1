[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Capture', 'Verify')]
    [string] $Mode,

    [Parameter(Mandatory = $true)]
    [string] $InputDirectory,

    [Parameter(Mandatory = $true)]
    [string] $SnapshotPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$productId = $env:MSSTORE_PRODUCT_ID
if ([string]::IsNullOrWhiteSpace($productId)) {
    throw 'MSSTORE_PRODUCT_ID is required'
}
$inputPath = (Resolve-Path $InputDirectory).Path
$bundles = @(Get-ChildItem $inputPath -Filter *.msixbundle)
if ($bundles.Count -ne 1) {
    throw 'Expected exactly one local MSIXBundle'
}
$bundle = $bundles[0]
$bundleHash = (Get-FileHash $bundle.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

$PSNativeCommandUseErrorActionPreference = $false
$response = (& msstore submission get $productId 2>&1 | Out-String)
$lookupExitCode = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
if ($lookupExitCode -ne 0) {
    throw 'Partner Center submission lookup failed'
}
$jsonStart = $response.IndexOf('{')
$jsonEnd = $response.LastIndexOf('}')
if ($jsonStart -lt 0 -or $jsonEnd -le $jsonStart) {
    throw 'Partner Center submission lookup did not return JSON'
}
$submission = $response.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$submission.Id)) {
    throw 'Partner Center draft has no submission identity'
}
if ([string]$submission.Status -cne 'PendingCommit') {
    throw "Partner Center submission is not a draft: $($submission.Status)"
}
$packages = @($submission.ApplicationPackages)
if ($packages.Count -eq 0) {
    $packages = @($submission.Packages)
}
$packageNames = @($packages | ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace([string]$_.FileName)) {
        [string]$_.FileName
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$_.PackageUrl)) {
        Split-Path ([uri]$_.PackageUrl).AbsolutePath -Leaf
    }
})
if ($packageNames -cnotcontains $bundle.Name) {
    throw 'Partner Center draft does not contain the expected MSIXBundle'
}

function ConvertTo-CanonicalValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties.Name | Sort-Object)) {
            $ordered[$property] = ConvertTo-CanonicalValue $Value.$property
        }
        return $ordered
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $ordered[$key] = ConvertTo-CanonicalValue $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-CanonicalValue $_ })
    }
    return $Value
}

$canonicalSubmission = ConvertTo-CanonicalValue $submission | ConvertTo-Json -Depth 100 -Compress
$submissionBytes = [Text.Encoding]::UTF8.GetBytes($canonicalSubmission)
$submissionHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($submissionBytes)
).ToLowerInvariant()

if ($Mode -eq 'Capture') {
    [ordered]@{
        submissionId = [string]$submission.Id
        status = [string]$submission.Status
        bundleFile = $bundle.Name
        bundleSha256 = $bundleHash
        submissionSha256 = $submissionHash
    } | ConvertTo-Json | Set-Content $SnapshotPath -Encoding utf8
    Write-Host 'Captured exact Partner Center draft identity.'
    exit 0
}

$snapshot = Get-Content $SnapshotPath -Raw | ConvertFrom-Json
if ([string]$snapshot.submissionId -cne [string]$submission.Id -or
    [string]$snapshot.status -cne 'PendingCommit' -or
    [string]$snapshot.bundleFile -cne $bundle.Name -or
    [string]$snapshot.bundleSha256 -cne $bundleHash -or
    [string]$snapshot.submissionSha256 -cne $submissionHash) {
    throw 'Partner Center draft no longer matches the approved upload'
}
Write-Host 'Partner Center draft still matches the approved upload.'
