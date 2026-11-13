# Build the Hampanel Windows kernel companion driver.
# Requires Visual Studio 2022 + WDK 10.
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio 2022 with the C++ workload."
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if (-not $vsPath) { throw "Visual Studio installation not found." }

$msbuild = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $msbuild)) { throw "MSBuild not found at $msbuild" }

& $msbuild (Join-Path $root "hampanel_driver.vcxproj") /m /p:Configuration=Release /p:Platform=x64
if ($LASTEXITCODE -ne 0) { throw "Driver build failed." }

$outDir = Join-Path $root "out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$candidates = @(
    (Join-Path $root "x64\Release\hampanel.sys"),
    (Join-Path $root "x64\Release\hampanel\hampanel.sys")
)
$built = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $built) { throw "hampanel.sys was not produced." }

Copy-Item $built (Join-Path $outDir "hampanel.sys") -Force
Write-Host "[driver] output: $outDir\hampanel.sys"
