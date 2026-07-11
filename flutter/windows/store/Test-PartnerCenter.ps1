[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$required = @(
    'MSSTORE_PRODUCT_ID',
    'MSSTORE_PACKAGE_IDENTITY_NAME',
    'MSSTORE_PACKAGE_PUBLISHER',
    'MSSTORE_PACKAGE_FAMILY_NAME',
    'MSSTORE_PACKAGE_DISPLAY_NAME',
    'MSSTORE_PUBLISHER_DISPLAY_NAME',
    'MSSTORE_TENANT_ID',
    'MSSTORE_SELLER_ID',
    'MSSTORE_CLIENT_ID',
    'MSSTORE_CLIENT_SECRET'
)
foreach ($name in $required) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -cne $value.Trim()) {
        throw "Protected value $name is missing or malformed"
    }
}

msstore settings --enableTelemetry false | Out-Null
msstore reconfigure `
    --tenantId $env:MSSTORE_TENANT_ID `
    --sellerId $env:MSSTORE_SELLER_ID `
    --clientId $env:MSSTORE_CLIENT_ID `
    --clientSecret $env:MSSTORE_CLIENT_SECRET | Out-Null

# Capture the response so portal-assigned values are compared, not printed.
$PSNativeCommandUseErrorActionPreference = $false
$response = (& msstore apps get $env:MSSTORE_PRODUCT_ID 2>&1 | Out-String)
$lookupExitCode = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
if ($lookupExitCode -ne 0) {
    throw 'Partner Center application lookup failed'
}
$jsonStart = $response.IndexOf('{')
$jsonEnd = $response.LastIndexOf('}')
if ($jsonStart -lt 0 -or $jsonEnd -le $jsonStart) {
    throw 'Partner Center application lookup did not return JSON'
}
$app = $response.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json

$expected = @{
    Id = $env:MSSTORE_PRODUCT_ID
    PrimaryName = $env:MSSTORE_PACKAGE_DISPLAY_NAME
    PackageIdentityName = $env:MSSTORE_PACKAGE_IDENTITY_NAME
    PublisherName = $env:MSSTORE_PACKAGE_PUBLISHER
    PackageFamilyName = $env:MSSTORE_PACKAGE_FAMILY_NAME
}
foreach ($property in $expected.Keys) {
    if ([string]$app.$property -cne $expected[$property]) {
        throw "Partner Center $property does not match the protected value"
    }
}

Write-Host 'Protected Partner Center product and package identity match.'
