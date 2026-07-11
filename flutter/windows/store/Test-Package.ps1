[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Tag,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSha,

    [Parameter(Mandatory = $true)]
    [string] $InputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-RequiredEnvironmentValue([string] $Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -cne $value.Trim()) {
        throw "Protected value $Name is missing or malformed"
    }
    return $value
}

function Get-WindowsSdkTool([string] $Name) {
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $tool = Get-ChildItem $sdkRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "x64/$Name" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($tool)) { throw "Windows SDK tool is unavailable: $Name" }
    return $tool
}

function Test-ExtractedPackage([string] $Directory, [string] $SemanticVersion, [string] $PackageVersion) {
    [xml]$manifest = Get-Content (Join-Path $Directory 'AppxManifest.xml') -Raw
    $ns = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
    $ns.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $ns.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
    $ns.AddNamespace('rescap', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities')
    $ns.AddNamespace('build', 'http://schemas.microsoft.com/developer/appx/2015/build')
    $identity = $manifest.SelectSingleNode('/f:Package/f:Identity', $ns)
    $application = $manifest.SelectSingleNode('/f:Package/f:Applications/f:Application', $ns)
    $buildItem = $manifest.SelectSingleNode('/f:Package/build:Metadata/build:Item[@Name="MSStoreCLIAppId"]', $ns)
    $checks = @{
        identityName = @($identity.GetAttribute('Name'), $env:MSSTORE_PACKAGE_IDENTITY_NAME)
        publisher = @($identity.GetAttribute('Publisher'), $env:MSSTORE_PACKAGE_PUBLISHER)
        version = @($identity.GetAttribute('Version'), $PackageVersion)
        architecture = @($identity.GetAttribute('ProcessorArchitecture'), 'x64')
        displayName = @($manifest.SelectSingleNode('/f:Package/f:Properties/f:DisplayName', $ns).InnerText, $env:MSSTORE_PACKAGE_DISPLAY_NAME)
        publisherDisplayName = @($manifest.SelectSingleNode('/f:Package/f:Properties/f:PublisherDisplayName', $ns).InnerText, $env:MSSTORE_PUBLISHER_DISPLAY_NAME)
        logicalApplicationId = @($application.GetAttribute('Id'), 'dev.adonm.zuko')
        productId = @($buildItem.GetAttribute('Value'), $env:MSSTORE_PRODUCT_ID)
    }
    foreach ($name in $checks.Keys) {
        if ([string]$checks[$name][0] -cne [string]$checks[$name][1]) {
            throw "Extracted package has an unexpected $name"
        }
    }
    if ($null -eq $manifest.SelectSingleNode('/f:Package/f:Capabilities/rescap:Capability[@Name="runFullTrust"]', $ns)) {
        throw 'Extracted package lacks runFullTrust capability'
    }
    $exe = Get-Item (Join-Path $Directory 'zuko.exe')
    $versionInfo = $exe.VersionInfo
    $parts = @($versionInfo.FileMajorPart, $versionInfo.FileMinorPart, $versionInfo.FileBuildPart, $versionInfo.FilePrivatePart)
    $expectedParts = @([int]($SemanticVersion.Split('.')[0]), [int]($SemanticVersion.Split('.')[1]), [int]($SemanticVersion.Split('.')[2]), 0)
    for ($index = 0; $index -lt 4; $index++) {
        if ($parts[$index] -ne $expectedParts[$index]) {
            throw 'zuko.exe file version does not match the Flutter release version'
        }
    }
}

& (Join-Path $PSScriptRoot 'Test-ReleaseSource.ps1') -Tag $Tag -ExpectedSha $ExpectedSha
foreach ($name in @(
    'MSSTORE_PRODUCT_ID',
    'MSSTORE_PACKAGE_IDENTITY_NAME',
    'MSSTORE_PACKAGE_PUBLISHER',
    'MSSTORE_PACKAGE_FAMILY_NAME',
    'MSSTORE_PACKAGE_DISPLAY_NAME',
    'MSSTORE_PUBLISHER_DISPLAY_NAME'
)) {
    $null = Get-RequiredEnvironmentValue $name
}

if ($Tag -cnotmatch '^v([0-9]+)\.([0-9]+)\.([0-9]+)$') { throw 'Tag must match vX.Y.Z' }
$major = [int]$Matches[1]
$minor = [int]$Matches[2]
$patch = [int]$Matches[3]
$semanticVersion = "$major.$minor.$patch"
$packageVersion = "$($major + 1).$minor.$patch.0"
$flutterBuild = $major * 1000000 + $minor * 1000 + $patch

$inputPath = (Resolve-Path $InputDirectory).Path
$msixes = @(Get-ChildItem $inputPath -Filter *.msix)
$bundles = @(Get-ChildItem $inputPath -Filter *.msixbundle)
if ($msixes.Count -ne 1 -or $bundles.Count -ne 1) {
    throw 'Expected exactly one MSIX and one MSIXBundle'
}
$metadataPath = Join-Path $inputPath 'package-metadata.json'
$metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
$metadataChecks = @{
    tag = @($metadata.tag, $Tag)
    commit = @($metadata.commit, $ExpectedSha)
    semanticVersion = @($metadata.semanticVersion, $semanticVersion)
    flutterBuildNumber = @($metadata.flutterBuildNumber, $flutterBuild)
    windowsExecutableVersion = @($metadata.windowsExecutableVersion, "$semanticVersion.0")
    packageVersion = @($metadata.packageVersion, $packageVersion)
    logicalApplicationId = @($metadata.logicalApplicationId, 'dev.adonm.zuko')
    productId = @($metadata.productId, $env:MSSTORE_PRODUCT_ID)
    packageIdentityName = @($metadata.packageIdentityName, $env:MSSTORE_PACKAGE_IDENTITY_NAME)
    packagePublisher = @($metadata.packagePublisher, $env:MSSTORE_PACKAGE_PUBLISHER)
    packageFamilyName = @($metadata.packageFamilyName, $env:MSSTORE_PACKAGE_FAMILY_NAME)
}
foreach ($name in $metadataChecks.Keys) {
    if ([string]$metadataChecks[$name][0] -cne [string]$metadataChecks[$name][1]) {
        throw "Package metadata has an unexpected $name"
    }
}

$makeappx = Get-WindowsSdkTool 'makeappx.exe'
$signtool = Get-WindowsSdkTool 'signtool.exe'
foreach ($package in @($msixes[0], $bundles[0])) {
    $sidecar = "$($package.FullName).sha256"
    $expectedHash = ((Get-Content $sidecar -Raw) -split '\s+')[0]
    $actualHash = (Get-FileHash $package.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedHash -cne $actualHash) { throw "Checksum failed for $($package.Name)" }
    & $signtool verify /pa /all /v $package.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signature verification failed for $($package.Name)" }
}

$extractRoot = Join-Path $env:RUNNER_TEMP "zuko-store-verify-$([guid]::NewGuid())"
try {
    $msixExtract = Join-Path $extractRoot 'msix'
    $bundleExtract = Join-Path $extractRoot 'bundle'
    $bundleMsixExtract = Join-Path $extractRoot 'bundle-msix'
    New-Item $msixExtract, $bundleExtract, $bundleMsixExtract -ItemType Directory -Force | Out-Null
    & $makeappx unpack /p $msixes[0].FullName /d $msixExtract
    if ($LASTEXITCODE -ne 0) { throw 'Unable to unpack MSIX for validation' }
    Test-ExtractedPackage $msixExtract $semanticVersion $packageVersion
    & $makeappx unbundle /p $bundles[0].FullName /d $bundleExtract
    if ($LASTEXITCODE -ne 0) { throw 'Unable to unbundle MSIXBundle for validation' }
    $innerPackages = @(Get-ChildItem $bundleExtract -Filter *.msix -Recurse)
    if ($innerPackages.Count -ne 1) { throw 'MSIXBundle does not contain exactly one package' }
    & $makeappx unpack /p $innerPackages[0].FullName /d $bundleMsixExtract
    if ($LASTEXITCODE -ne 0) { throw 'Unable to unpack bundled MSIX for validation' }
    Test-ExtractedPackage $bundleMsixExtract $semanticVersion $packageVersion
} finally {
    Remove-Item $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'MSIX checksums, signatures, identity mapping, and versions are valid.'
