$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

if ($args.Count -ne 1) { throw "usage: package-windows-release.ps1 <vX.Y.Z>" }
$tag = $args[0]

New-Item -ItemType Directory -Force dist/windows | Out-Null
$archive = "dist/windows/zuko-windows-$tag-x86_64.zip"
Compress-Archive -Path flutter/build/windows/x64/runner/Release/* -DestinationPath $archive
$hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
"$hash  $(Split-Path -Leaf $archive)" | Set-Content -NoNewline "$archive.sha256"
