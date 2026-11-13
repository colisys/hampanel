# Hampanel Windows installer: builds the Zig daemon, installs it as a Windows
# service and optionally installs the kernel companion driver.
# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [string]$Source = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$InstallDir = "$env:ProgramFiles\Hampanel",
    [string]$DataDir = "$env:ProgramData\hampanel",
    [int]$Port = 0,
    [string]$Endpoint = "",
    [string]$EntryPrefix = "",
    [string[]]$San = @(),
    [string]$OpenSslDir = "",
    [string]$ZigVersion = "0.14.1",
    [string]$ServiceName = "hampanel",
    [switch]$InstallDriver,
    [switch]$SkipBuild,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This installer must run from an elevated PowerShell session."
    }
}

function Write-Step([string]$Message) {
    Write-Host "[hampanel] $Message" -ForegroundColor Cyan
}

Assert-Administrator

if (-not $Endpoint) {
    $Endpoint = $env:COMPUTERNAME
}

$null = New-Item -ItemType Directory -Force -Path $InstallDir, $DataDir
$configPath = Join-Path $DataDir "config.json"
$tlsDir = Join-Path $DataDir "tls"
$enrollPath = Join-Path $DataDir "enroll.json"
$exePath = Join-Path $InstallDir "hampaneld.exe"

# ------------------------------------------------------------------ toolchain
$zig = (Get-Command zig -ErrorAction SilentlyContinue).Source
if (-not $zig) {
    $toolchain = Join-Path $env:ProgramData "hampanel\toolchain"
    $zigExe = Join-Path $toolchain "zig.exe"
    if (-not (Test-Path $zigExe)) {
        Write-Step "Downloading Zig $ZigVersion"
        $null = New-Item -ItemType Directory -Force -Path $toolchain
        $zip = Join-Path $env:TEMP "zig-windows.zip"
        Invoke-WebRequest -Uri "https://ziglang.org/download/$ZigVersion/zig-x86_64-windows-$ZigVersion.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $toolchain -Force
        $nested = Get-ChildItem -Path $toolchain -Recurse -Filter zig.exe | Select-Object -First 1
        if (-not $nested) { throw "Zig extraction failed" }
        $zig = $nested.FullName
    } else {
        $zig = $zigExe
    }
}
Write-Step "Using Zig: $zig"

# -------------------------------------------------------------------- openssl
if (-not $OpenSslDir) {
    if ($env:OPENSSL_DIR) { $OpenSslDir = $env:OPENSSL_DIR }
    elseif (Test-Path "$env:VCPKG_INSTALLATION_ROOT\installed\x64-windows") {
        $OpenSslDir = "$env:VCPKG_INSTALLATION_ROOT\installed\x64-windows"
    } else {
        throw "OpenSSL is required. Install it with: vcpkg install openssl:x64-windows, then pass -OpenSslDir <prefix>."
    }
}
if (-not (Test-Path (Join-Path $OpenSslDir "lib\libssl.lib"))) {
    throw "OpenSSL libraries not found under $OpenSslDir\lib. Expected libssl.lib and libcrypto.lib."
}

# ---------------------------------------------------------------------- build
if (-not $SkipBuild) {
    Write-Step "Compiling daemon (ReleaseSafe)"
    Push-Location (Join-Path $Source "daemon")
    try {
        & $zig build -Doptimize=ReleaseSafe "-Dopenssl-dir=$OpenSslDir"
        if ($LASTEXITCODE -ne 0) { throw "zig build failed" }
    } finally {
        Pop-Location
    }
}

$builtExe = Join-Path $Source "daemon\zig-out\bin\hampaneld.exe"
if (-not (Test-Path $builtExe)) { throw "Built binary not found: $builtExe" }
Copy-Item $builtExe $exePath -Force
Get-ChildItem -Path (Join-Path $OpenSslDir "bin") -Filter "*.dll" -ErrorAction SilentlyContinue |
    Copy-Item -Destination $InstallDir -Force

# --------------------------------------------------------------------- PKI
if (-not (Test-Path (Join-Path $tlsDir "ca.crt.pem"))) {
    Write-Step "Generating mutual-TLS PKI"
    $arguments = @(
        "init",
        "--config", $configPath,
        "--tls-dir", $tlsDir,
        "--data-dir", (Join-Path $DataDir "data"),
        "--enroll-file", $enrollPath,
        "--endpoint", $Endpoint
    )
    if ($Port -gt 0) { $arguments += @("--port", "$Port") }
    if ($EntryPrefix) { $arguments += @("--entry-prefix", $EntryPrefix) }
    foreach ($entry in $San) { $arguments += @("--san", $entry) }
    & $exePath @arguments
    if ($LASTEXITCODE -ne 0) { throw "hampaneld init failed" }
} else {
    Write-Step "Reusing existing PKI in $tlsDir"
    & $exePath enroll --config $configPath --out $enrollPath | Out-Null
}

# ------------------------------------------------------------------- service
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$binPath = "`"$exePath`" run --service --config `"$configPath`""
if (-not $service) {
    Write-Step "Registering Windows service $ServiceName"
    & sc.exe create $ServiceName binPath= $binPath start= auto DisplayName= "Hampanel Server Panel" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe create failed" }
    & sc.exe description $ServiceName "Hampanel server panel daemon (mutual TLS)" | Out-Null
} else {
    & sc.exe config $ServiceName binPath= $binPath start= auto | Out-Null
}

if (-not $NoStart) {
    Write-Step "Starting service"
    & sc.exe start $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    $service = Get-Service -Name $ServiceName
    if ($service.Status -ne "Running") {
        throw "Service is not running. Run `hampaneld.exe run --config $configPath` in a console to see startup errors."
    }
}

# ------------------------------------------------------------------- firewall
$effective = Get-Content $configPath -Raw | ConvertFrom-Json
$actualPort = [int]$effective.port
$actualPrefix = [string]$effective.entry_prefix
$ruleName = "Hampanel Panel ($actualPort)"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    Write-Step "Adding firewall rule for TCP $actualPort"
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $actualPort -Profile Any | Out-Null
}

# --------------------------------------------------------------------- driver
if ($InstallDriver) {
    $driverSource = Join-Path $PSScriptRoot "..\..\windows\driver\out\hampanel.sys"
    $driverTarget = Join-Path $InstallDir "hampanel.sys"
    if (-not (Test-Path $driverSource)) {
        Write-Warning "Driver binary not found at $driverSource. Build it with windows\driver\build.ps1."
    } else {
        Copy-Item $driverSource $driverTarget -Force
        $driverService = Get-Service -Name "HampanelDriver" -ErrorAction SilentlyContinue
        if (-not $driverService) {
            Write-Step "Registering kernel companion driver"
            & sc.exe create HampanelDriver type= kernel start= demand binPath= $driverTarget | Out-Null
        } else {
            & sc.exe config HampanelDriver binPath= $driverTarget | Out-Null
        }
        & sc.exe start HampanelDriver | Out-Null
        Write-Warning "Unsigned drivers require test signing or a production signature."
    }
}

Write-Host ""
Write-Step "Installed"
Write-Host "  binary:       $exePath"
Write-Host "  config:       $configPath"
Write-Host "  endpoint:     $($effective.endpoint)"
Write-Host "  entry prefix: $actualPrefix"
Write-Host "  enrollment:   $enrollPath"
Write-Host ""
Write-Host "Import the enrollment JSON into the Hampanel Flutter client."
