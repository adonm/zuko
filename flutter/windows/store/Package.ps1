[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Tag,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSha,

    [Parameter(Mandatory = $true)]
    [string] $BuildDirectory,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

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
    if ([string]::IsNullOrWhiteSpace($tool)) {
        throw "Windows SDK tool is unavailable: $Name"
    }
    return $tool
}

function New-Logo([string] $Source, [string] $Destination, [int] $Size) {
    Add-Type -AssemblyName System.Drawing
    $image = [System.Drawing.Image]::FromFile($Source)
    try {
        $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.Clear([System.Drawing.Color]::Transparent)
                $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.DrawImage($image, 0, 0, $Size, $Size)
            } finally {
                $graphics.Dispose()
            }
            $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $bitmap.Dispose()
        }
    } finally {
        $image.Dispose()
    }
}

& (Join-Path $PSScriptRoot 'Test-ReleaseTag.ps1') -Tag $Tag -ExpectedSha $ExpectedSha

$config = Get-Content (Join-Path $PSScriptRoot 'store-config.json') -Raw | ConvertFrom-Json
if ($config.logicalApplicationId -cne 'dev.adonm.zuko' -or
    $config.architecture -cne 'x64' -or
    $config.versionMapping -cne 'major-plus-one.minor.patch.0') {
    throw 'Windows Store package mapping is not the expected dev.adonm.zuko mapping'
}

if ($Tag -cnotmatch '^v([0-9]+)\.([0-9]+)\.([0-9]+)$') {
    throw 'Tag must match vX.Y.Z'
}
$major = [int]$Matches[1]
$minor = [int]$Matches[2]
$patch = [int]$Matches[3]
$semanticVersion = "$major.$minor.$patch"
$storeMajor = $major + 1
if ($storeMajor -gt 65535 -or $minor -gt 65535 -or $patch -gt 65535) {
    throw 'Release version cannot be represented as a Microsoft Store package version'
}
$storeVersion = "$storeMajor.$minor.$patch.0"

$cargo = Get-Content (Join-Path $root 'Cargo.toml') -Raw
$cargoVersion = [regex]::Match($cargo, '(?m)^version = "([0-9]+\.[0-9]+\.[0-9]+)"$').Groups[1].Value
$pubspec = Get-Content (Join-Path $root 'flutter/pubspec.yaml') -Raw
$flutterMatch = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$')
$expectedFlutterBuild = $major * 1000000 + $minor * 1000 + $patch
if ($cargoVersion -cne $semanticVersion -or
    -not $flutterMatch.Success -or
    $flutterMatch.Groups[1].Value -cne $semanticVersion -or
    [int]$flutterMatch.Groups[2].Value -ne $expectedFlutterBuild) {
    throw 'Tag, Cargo, and Flutter versions do not match the release mapping'
}

$productId = Get-RequiredEnvironmentValue 'MSSTORE_PRODUCT_ID'
$identityName = Get-RequiredEnvironmentValue 'MSSTORE_PACKAGE_IDENTITY_NAME'
$publisher = Get-RequiredEnvironmentValue 'MSSTORE_PACKAGE_PUBLISHER'
$null = Get-RequiredEnvironmentValue 'MSSTORE_PACKAGE_FAMILY_NAME'
$displayName = Get-RequiredEnvironmentValue 'MSSTORE_PACKAGE_DISPLAY_NAME'
$publisherDisplayName = Get-RequiredEnvironmentValue 'MSSTORE_PUBLISHER_DISPLAY_NAME'
$pfxBase64 = Get-RequiredEnvironmentValue 'MSSTORE_SIGNING_PFX_BASE64'
$pfxPassword = Get-RequiredEnvironmentValue 'MSSTORE_SIGNING_PFX_PASSWORD'

$buildPath = (Resolve-Path $BuildDirectory).Path
if (-not (Test-Path (Join-Path $buildPath 'zuko.exe'))) {
    throw 'Flutter Windows release does not contain zuko.exe'
}
$outputPath = Join-Path $root $OutputDirectory
$staging = Join-Path $env:RUNNER_TEMP 'zuko-msix-staging'
$bundleInput = Join-Path $env:RUNNER_TEMP 'zuko-msix-bundle-input'
foreach ($path in @($outputPath, $staging, $bundleInput)) {
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $path -ItemType Directory -Force | Out-Null
}
Copy-Item "$buildPath/*" $staging -Recurse -Force
Get-ChildItem $staging -Filter *.pdb -Recurse | Remove-Item -Force

$assets = New-Item (Join-Path $staging 'Assets') -ItemType Directory -Force
$logo = Join-Path $root 'flutter/assets/zuko-logo.png'
New-Logo $logo (Join-Path $assets 'StoreLogo.png') 50
New-Logo $logo (Join-Path $assets 'Square150x150Logo.png') 150
New-Logo $logo (Join-Path $assets 'Square44x44Logo.png') 44

[xml]$manifest = Get-Content (Join-Path $PSScriptRoot 'AppxManifest.xml.in') -Raw
$ns = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
$ns.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$ns.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
$ns.AddNamespace('build', 'http://schemas.microsoft.com/developer/appx/2015/build')
$identity = $manifest.SelectSingleNode('/f:Package/f:Identity', $ns)
$identity.SetAttribute('Name', $identityName)
$identity.SetAttribute('Publisher', $publisher)
$identity.SetAttribute('Version', $storeVersion)
$identity.SetAttribute('ProcessorArchitecture', $config.architecture)
$manifest.SelectSingleNode('/f:Package/f:Properties/f:DisplayName', $ns).InnerText = $displayName
$manifest.SelectSingleNode('/f:Package/f:Properties/f:PublisherDisplayName', $ns).InnerText = $publisherDisplayName
$manifest.SelectSingleNode('/f:Package/f:Dependencies/f:TargetDeviceFamily', $ns).SetAttribute('MinVersion', $config.minimumWindowsVersion)
$manifest.SelectSingleNode('/f:Package/f:Dependencies/f:TargetDeviceFamily', $ns).SetAttribute('MaxVersionTested', $config.maximumWindowsVersionTested)
$application = $manifest.SelectSingleNode('/f:Package/f:Applications/f:Application', $ns)
$application.SetAttribute('Id', $config.logicalApplicationId)
$application.SelectSingleNode('uap:VisualElements', $ns).SetAttribute('DisplayName', $displayName)
$manifest.SelectSingleNode('/f:Package/build:Metadata/build:Item[@Name="MSStoreCLIAppId"]', $ns).SetAttribute('Value', $productId)
$manifest.Save((Join-Path $staging 'AppxManifest.xml'))

$makeappx = Get-WindowsSdkTool 'makeappx.exe'
$signtool = Get-WindowsSdkTool 'signtool.exe'
$msix = Join-Path $outputPath "Zuko-$Tag-x64.msix"
$bundle = Join-Path $outputPath "Zuko-$Tag-x64.msixbundle"
& $makeappx pack /o /h SHA256 /d $staging /p $msix
if ($LASTEXITCODE -ne 0) { throw 'MakeAppx failed to create the MSIX' }
Copy-Item $msix (Join-Path $bundleInput (Split-Path $msix -Leaf))
& $makeappx bundle /o /bv $storeVersion /d $bundleInput /p $bundle
if ($LASTEXITCODE -ne 0) { throw 'MakeAppx failed to create the MSIXBundle' }

$pfxPath = Join-Path $env:RUNNER_TEMP 'zuko-store-signing.pfx'
$imported = @()
try {
    try {
        [IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($pfxBase64))
    } catch {
        throw 'MSSTORE_SIGNING_PFX_BASE64 is not valid base64'
    }
    $securePassword = ConvertTo-SecureString $pfxPassword -AsPlainText -Force
    $imported = @(Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation Cert:\CurrentUser\My -Password $securePassword)
    $certificate = @($imported | Where-Object HasPrivateKey | Select-Object -First 1)
    if ($certificate.Count -ne 1) { throw 'Signing PFX does not contain one usable private key' }
    $certificate = $certificate[0]
    if ($certificate.Subject -cne $publisher) {
        throw 'Signing certificate subject does not exactly match MSSTORE_PACKAGE_PUBLISHER'
    }
    if ($certificate.NotBefore -gt [DateTime]::Now -or $certificate.NotAfter -le [DateTime]::Now) {
        throw 'Signing certificate is not currently valid'
    }
    $codeSigningEku = @($certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId.Value -eq '1.3.6.1.5.5.7.3.3' })
    if ($codeSigningEku.Count -eq 0) { throw 'Signing certificate lacks the code-signing EKU' }

    foreach ($package in @($msix, $bundle)) {
        & $signtool sign /fd SHA256 /sha1 $certificate.Thumbprint /s My `
            /tr http://timestamp.digicert.com /td SHA256 $package
        if ($LASTEXITCODE -ne 0) { throw 'SignTool failed to sign a package' }
        & $signtool verify /pa /all /v $package
        if ($LASTEXITCODE -ne 0) { throw 'SignTool failed to verify a package signature' }
    }
} finally {
    Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
    foreach ($certificate in $imported) {
        Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }
}

foreach ($package in @($msix, $bundle)) {
    $hash = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path $package -Leaf)" | Set-Content "$package.sha256" -Encoding utf8 -NoNewline
}

$metadata = [ordered]@{
    tag = $Tag
    commit = $ExpectedSha
    semanticVersion = $semanticVersion
    flutterBuildNumber = $expectedFlutterBuild
    windowsExecutableVersion = "$semanticVersion.0"
    packageVersion = $storeVersion
    logicalApplicationId = $config.logicalApplicationId
    architecture = $config.architecture
    productId = $productId
    packageIdentityName = $identityName
    packagePublisher = $publisher
    packageFamilyName = $env:MSSTORE_PACKAGE_FAMILY_NAME
    packageDisplayName = $displayName
    publisherDisplayName = $publisherDisplayName
}
$metadata | ConvertTo-Json | Set-Content (Join-Path $outputPath 'package-metadata.json') -Encoding utf8

& (Join-Path $PSScriptRoot 'Test-Package.ps1') `
    -Tag $Tag `
    -ExpectedSha $ExpectedSha `
    -InputDirectory $outputPath

Write-Host "Created and verified signed MSIX and MSIXBundle for $Tag."
