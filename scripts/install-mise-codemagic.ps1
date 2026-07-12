$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$version = "2026.7.5"
$expected = "0ccdde5cd132a4d1f5078bef2bbc49275f803ba672121446f0b7429a48d59df9"
$archive = "mise-v$version-windows-x64.zip"
$url = "https://github.com/jdx/mise/releases/download/v$version/$archive"
$binDirectory = Join-Path $HOME ".local/bin"
$bin = Join-Path $binDirectory "mise.exe"
$gitRoot = Split-Path (Split-Path (Get-Command git).Source -Parent) -Parent
$gitBin = Join-Path $gitRoot "bin"
$bash = Join-Path $gitBin "bash.exe"

if (-not (Test-Path $bash)) {
    throw "Git Bash is missing: $bash"
}

New-Item -ItemType Directory -Force $binDirectory | Out-Null
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
$expanded = "$temporary-expanded"
try {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $temporary
    $actual = (Get-FileHash -Algorithm SHA256 $temporary).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "mise SHA-256 is $actual, expected $expected"
    }
    Expand-Archive -Path $temporary -DestinationPath $expanded
    $downloaded = Get-ChildItem -Path $expanded -Filter mise.exe -Recurse | Select-Object -First 1
    if ($null -eq $downloaded) {
        throw "mise.exe is missing from $archive"
    }
    Copy-Item -Force $downloaded.FullName $bin
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $temporary
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $expanded
}

$env:PATH = "$binDirectory;$gitBin;$env:PATH"
if (-not [string]::IsNullOrWhiteSpace($env:CM_ENV)) {
    "PATH=$env:PATH" | Add-Content -Encoding utf8 $env:CM_ENV
}

& $bin --version | Select-String -SimpleMatch $version
& $bin trust (Join-Path $PWD "mise.toml")
& $bin install rust zig just "http:flutter"
& $bin exec -- rustc --version
& $bin exec -- zig version
& $bin exec -- flutter --version
