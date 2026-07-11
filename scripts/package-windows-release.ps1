param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Tag
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

New-Item -ItemType Directory -Force dist/windows | Out-Null
$archive = "dist/windows/zuko-windows-$Tag-x86_64.zip"
Compress-Archive -Path flutter/build/windows/x64/runner/Release/* -DestinationPath $archive
$hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
"$hash  $(Split-Path -Leaf $archive)" | Set-Content -NoNewline "$archive.sha256"
