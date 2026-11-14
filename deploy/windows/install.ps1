# Hampanel Windows installer: builds the Zig daemon, installs it as a Windows
# service and optionally installs the kernel companion driver.
# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$InstallDir = "$env:ProgramFiles\Hampanel",
    [string]$DataDir = "$env:ProgramData\hampanel",
    [int]$Port = 0,
    [string]$Endpoint = "",
    [string]$EntryPrefix = "",
    [string[]]$San = @(),
    [string]$OpenSslDir = "",
    [string]$ZigVersion = "0.17.1",
    [string]$ServiceName = "hampanel",
    [ValidateSet("binary", "source")]
    [string]$Mode = "binary",
    [string]$Channel = "",
    [string]$Repo = "colisys/hampanel",
    [string]$Ref = "",
    [string]$ReleaseBase = "",
    [string]$SourceBase = "",
    [string]$GithubMirror = "",
    [string]$Binary = "",
    [switch]$InstallDriver,
    [switch]$SkipBuild,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

# Mirrors are often shielded by Cloudflare; default agents get 403.
$script:UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

function Mirror-Url([string]$Url) {
    if (-not $GithubMirror) { return $Url }
    $base = $GithubMirror.Trim().TrimEnd("/")
    if ($Url -eq $base -or $Url.StartsWith("$base/")) { return $Url }
    return "$base/$Url"
}

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

# ------------------------------------------------------------------- install
$builtExe = ""
if ($Mode -eq "binary") {
    if (-not $Channel) { $Channel = "stable" }
    if (-not $ReleaseBase) {
        if ($Channel -eq "stable" -or $Channel -eq "latest") {
            $ReleaseBase = "https://github.com/$Repo/releases/latest/download"
        } else {
            $ReleaseBase = "https://github.com/$Repo/releases/download/$Channel"
        }
    }
    if (-not $explicitReleaseBase) { $ReleaseBase = Mirror-Url $ReleaseBase }
    $asset = "hampanel-daemon-windows-x86_64.zip"
    $tmp = Join-Path $env:TEMP "hampanel-release"
    $null = New-Item -ItemType Directory -Force -Path $tmp
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/version.txt" -OutFile (Join-Path $tmp "version.txt") -UserAgent $script:UserAgent
    } catch {
        throw "no release found for channel $Channel; use -Channel nightly for prereleases or publish a stable tag"
    }
    $zipPath = Join-Path $tmp $asset
    $sumsPath = Join-Path $tmp "SHA256SUMS.txt"
    Write-Step "Downloading $ReleaseBase/$asset"
    Invoke-WebRequest -Uri "$ReleaseBase/$asset" -OutFile $zipPath -UserAgent $script:UserAgent
    Invoke-WebRequest -Uri "$ReleaseBase/SHA256SUMS.txt" -OutFile $sumsPath -UserAgent $script:UserAgent
    $line = Get-Content $sumsPath | Where-Object {
        (($_ -split '\s+')[1] -replace '^\*', '') -eq $asset
    } | Select-Object -First 1
    if (-not $line) { throw "checksum for $asset is not published" }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) { throw "checksum mismatch for $asset" }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $tmp -Force
    $builtExe = if ($Binary) { $Binary } else { Join-Path $tmp "hampaneld.exe" }
    if (-not (Test-Path $builtExe)) { throw "downloaded binary not found: $builtExe" }
    Get-ChildItem -Path $tmp -Filter "*.dll" -ErrorAction SilentlyContinue |
        Copy-Item -Destination $InstallDir -Force
} else {
    if (-not $Source) {
        if (-not $Channel -and -not $Ref) {
            throw "source builds require -Channel stable|nightly or -Ref <tag|branch>"
        }
        $ref = $Ref
        if (-not $ref) {
            if ($Channel -eq "nightly") {
                $ref = "nightly"
            } elseif ($Channel -eq "stable" -or $Channel -eq "latest") {
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                    -Headers @{ "Accept" = "application/vnd.github+json"; "User-Agent" = $script:UserAgent }
                $ref = $release.tag_name
                if (-not $ref) { throw "no stable release tag found; pass -Ref <tag>" }
            } else {
                throw "unknown channel $Channel; use stable, nightly or -Ref <tag|branch>"
            }
        }
        if ($SourceBase) {
            $srcUrl = "$($SourceBase.TrimEnd('/'))/$ref.tar.gz"
        } elseif ($ref -match '^v?\d+\.\d+\.\d+') {
            $srcUrl = "https://github.com/$Repo/archive/refs/tags/$ref.tar.gz"
        } else {
            $srcUrl = "https://github.com/$Repo/archive/refs/heads/$ref.tar.gz"
        }
        if (-not $SourceBase) { $srcUrl = Mirror-Url $srcUrl }
        $srcTmp = Join-Path $env:TEMP "hampanel-src"
        Remove-Item -Recurse -Force $srcTmp -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Force -Path $srcTmp
        $tgz = Join-Path $env:TEMP "hampanel-src.tar.gz"
        Write-Step "Downloading source $srcUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $srcUrl -OutFile $tgz -UserAgent $script:UserAgent
        tar -xzf $tgz -C $srcTmp --strip-components=1
        if ($LASTEXITCODE -ne 0) { throw "source extraction failed" }
        $Source = $srcTmp
    }

    # ---------------------------------------------------------------- toolchain
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

    # ------------------------------------------------------------------ openssl
    if (-not $OpenSslDir) {
        if ($env:OPENSSL_DIR) {
            $OpenSslDir = $env:OPENSSL_DIR
        } else {
            $vcpkg = Get-Command vcpkg -ErrorAction SilentlyContinue
            $vcpkgRoot = if ($env:VCPKG_INSTALLATION_ROOT) { $env:VCPKG_INSTALLATION_ROOT } elseif ($vcpkg) { Split-Path $vcpkg.Source } else { "" }
            if ($vcpkgRoot) {
                if (-not (Test-Path "$vcpkgRoot\installed\x64-windows\lib\libssl.lib")) {
                    if (-not $vcpkg) { throw "OpenSSL is missing and vcpkg is not installed. Install vcpkg or pass -OpenSslDir <prefix>." }
                    Write-Step "Installing OpenSSL with vcpkg"
                    & vcpkg install openssl:x64-windows
                    if ($LASTEXITCODE -ne 0) { throw "vcpkg install openssl:x64-windows failed" }
                }
                $OpenSslDir = "$vcpkgRoot\installed\x64-windows"
            }
        }
        if (-not $OpenSslDir) {
            throw "OpenSSL is required for source builds. Install vcpkg (https://vcpkg.io) or pass -OpenSslDir <prefix>."
        }
    }
    if (-not (Test-Path (Join-Path $OpenSslDir "lib\libssl.lib"))) {
        throw "OpenSSL libraries not found under $OpenSslDir\lib. Expected libssl.lib and libcrypto.lib."
    }

    # -------------------------------------------------------------------- build
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
    Get-ChildItem -Path (Join-Path $OpenSslDir "bin") -Filter "*.dll" -ErrorAction SilentlyContinue |
        Copy-Item -Destination $InstallDir -Force
}

Copy-Item $builtExe $exePath -Force

# --------------------------------------------------------------------- PKI
if (-not (Test-Path (Join-Path $tlsDir "ca.crt.pem"))) {
    Write-Step "Generating mutual-TLS PKI"
    $arguments = @(
        "init",
        "--config", $configPath,
        "--tls-dir", $tlsDir,
        "--data-dir", (Join-Path $DataDir "data"),
        "--enroll-file", $enrollPath,
        "--endpoint", $Endpoint,
        "--install-mode", $Mode,
        "--update-channel", $Channel,
        "--update-repo", $Repo,
        "--service-name", $ServiceName
    )
    if ($Port -gt 0) { $arguments += @("--port", "$Port") }
    if ($EntryPrefix) { $arguments += @("--entry-prefix", $EntryPrefix) }
    foreach ($entry in $San) { $arguments += @("--san", $entry) }
    & $exePath @arguments
    if ($LASTEXITCODE -ne 0) { throw "hampaneld init failed" }
} else {
    Write-Step "Reusing existing PKI in $tlsDir"
    & $exePath init --config $configPath --tls-dir $tlsDir --data-dir (Join-Path $DataDir "data") `
        --enroll-file $enrollPath --endpoint $Endpoint --install-mode $Mode `
        --update-channel $Channel --update-repo $Repo --service-name $ServiceName | Out-Null
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

# --------------------------------------------------------------- update check
if ($Mode -eq "binary") {
    Write-Step "Enabling daily update check"
    & $exePath update --install-schedule --config $configPath | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not install the update check." }
} else {
    & $exePath update --remove-schedule --config $configPath | Out-Null
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
