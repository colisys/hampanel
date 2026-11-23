#!/usr/bin/env bash
# Hampanel remote bootstrap: build the Zig daemon on this machine, install it,
# generate the mutual-TLS PKI and start the service.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.17.1}"
SOURCE_DIR=""
PREFIX="/usr/local"
CONFIG_DIR="/etc/hampanel"
DATA_DIR="/var/lib/hampanel"
TLS_DIR=""
ENROLL_FILE=""
PORT=""
ENDPOINT=""
SANS=()
ENTRY_PREFIX=""
ENTRY_PREFIX_SET=0
NO_SYSTEMD=0
NO_START=0
SERVICE_NAME="hampanel"
PREFIX_EXPLICIT=0
CONFIG_EXPLICIT=0
DATA_EXPLICIT=0
TLS_EXPLICIT=0
ENROLL_EXPLICIT=0
MODE="source"
BINARY_FILE=""
INSTALL_MODE="source"
UPDATE_CHANNEL="stable"
UPDATE_REPO="colisys/hampanel"
MIRROR=""

log() { printf '[hampanel] %s\n' "$*" >&2; }
fail() { printf '[hampanel] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_DIR="${2:?}"; shift 2 ;;
    --prefix) PREFIX="${2:?}"; PREFIX_EXPLICIT=1; shift 2 ;;
    --config-dir) CONFIG_DIR="${2:?}"; CONFIG_EXPLICIT=1; shift 2 ;;
    --data-dir) DATA_DIR="${2:?}"; DATA_EXPLICIT=1; shift 2 ;;
    --tls-dir) TLS_DIR="${2:?}"; TLS_EXPLICIT=1; shift 2 ;;
    --enroll-file) ENROLL_FILE="${2:?}"; ENROLL_EXPLICIT=1; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --entry-prefix) ENTRY_PREFIX="${2:-}"; ENTRY_PREFIX_SET=1; shift 2 ;;
    --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
    --san) SANS+=("${2:?}"); shift 2 ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --service-name) SERVICE_NAME="${2:?}"; shift 2 ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --binary-file) BINARY_FILE="${2:?}"; shift 2 ;;
    --install-mode) INSTALL_MODE="${2:?}"; shift 2 ;;
    --update-channel) UPDATE_CHANNEL="${2:?}"; shift 2 ;;
    --update-repo) UPDATE_REPO="${2:?}"; shift 2 ;;
    --mirror) MIRROR="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ -n "$SOURCE_DIR" ]] || fail "--source is required"
[[ "$MODE" == "binary" || "$MODE" == "source" ]] || fail "--mode must be binary or source"
if [[ "$MODE" == "source" && ! -d "$SOURCE_DIR/daemon" ]]; then
  fail "$SOURCE_DIR does not look like the Hampanel repository"
fi
if [[ "$MODE" == "binary" ]]; then
  [[ -n "$BINARY_FILE" && -f "$BINARY_FILE" ]] || fail "--binary-file is required in binary mode"
  INSTALL_MODE="binary"
fi
[[ -n "$ENDPOINT" ]] || fail "--endpoint HOST:PORT is required"
[[ -z "$TLS_DIR" ]] && TLS_DIR="$CONFIG_DIR/tls"
[[ -z "$ENROLL_FILE" ]] && ENROLL_FILE="$CONFIG_DIR/enroll.json"

ROOT=0
if [[ "$(id -u)" == "0" ]]; then ROOT=1; fi
if [[ "$NO_SYSTEMD" == "0" && "$ROOT" == "0" ]]; then
  fail "installing a systemd service requires root (use --prefix and --no-systemd for a user install)"
fi

if [[ "$ROOT" == "0" ]]; then
  [[ "$PREFIX_EXPLICIT" == "0" ]] && PREFIX="${HOME}/.local"
  [[ "$CONFIG_EXPLICIT" == "0" ]] && CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hampanel"
  [[ "$DATA_EXPLICIT" == "0" ]] && DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/hampanel"
  [[ "$TLS_EXPLICIT" == "0" ]] && TLS_DIR="$CONFIG_DIR/tls"
  [[ "$ENROLL_EXPLICIT" == "0" ]] && ENROLL_FILE="$CONFIG_DIR/enroll.json"
fi

# ---------------------------------------------------------------- toolchain
detect_zig_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv6l) echo "arm" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
}

detect_libc() {
  if ldd --version 2>&1 | grep -qi musl; then echo "musl"; else echo "gnu"; fi
}

find_zig() {
  if command -v zig >/dev/null 2>&1; then
    command -v zig
    return
  fi
  local base
  if [[ "$ROOT" == "1" ]]; then
    base="/opt/hampanel/toolchain"
  else
    base="${HOME}/.local/share/hampanel/toolchain"
  fi
  if [[ -x "$base/zig" ]]; then
    echo "$base/zig"
    return
  fi
  return 1
}

install_zig() {
  local arch base url tmp
  arch="$(detect_zig_arch)"
  if [[ "$ROOT" == "1" ]]; then
    base="/opt/hampanel/toolchain"
  else
    base="${HOME}/.local/share/hampanel/toolchain"
  fi
  mkdir -p "$base"
  url="https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"
  log "downloading Zig ${ZIG_VERSION} (${arch}-linux)"
  tmp="$(mktemp -d)"
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp/zig.tar.xz" ||
    fail "failed to download $url"
  tar -xJf "$tmp/zig.tar.xz" -C "$base" --strip-components=1
  rm -rf "$tmp"
}

mirror_host() {
  case "$1" in
    aliyun) echo "mirrors.aliyun.com" ;;
    tencent) echo "mirrors.cloud.tencent.com" ;;
    ustc) echo "mirrors.ustc.edu.cn" ;;
    tuna) echo "mirrors.tuna.tsinghua.edu.cn" ;;
    custom:*) echo "${1#custom:}" | sed 's|^https\?://||' | cut -d/ -f1 ;;
    http://*|https://*) echo "${1#*://}" | cut -d/ -f1 ;;
    *) echo "" ;;
  esac
}

configure_package_mirror() {
  [[ -n "${MIRROR:-}" ]] || return 0
  [[ "$ROOT" == "1" ]] || { log "package mirror needs root; keeping default sources"; return 0; }
  local host
  host="$(mirror_host "$MIRROR")"
  [[ -n "$host" ]] || { log "unknown mirror preset '$MIRROR'; keeping default sources"; return 0; }
  log "using package mirror ${host}"
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/ubuntu.sources; do
    [[ -f "$f" ]] || continue
    sed -i "s|deb.debian.org|${host}|g; s|security.debian.org|${host}|g; s|archive.ubuntu.com|${host}|g; s|security.ubuntu.com|${host}|g" "$f"
  done
  if [[ -f /etc/apk/repositories ]]; then
    sed -i "s|dl-cdn.alpinelinux.org|${host}|g" /etc/apk/repositories
  fi
}

ensure_runtime_libs() {
  [[ "$ROOT" == "1" ]] || return 0
  if ldconfig -p 2>/dev/null | grep -q 'libssl\.so\.3'; then
    return
  fi
  configure_package_mirror
  log "installing runtime libraries"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq libssl3 ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q openssl-libs ca-certificates >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q openssl-libs ca-certificates >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache libssl3 ca-certificates >/dev/null
  fi
}

ensure_openssl() {
  if [[ -f /usr/include/openssl/ssl.h ]] || pkg-config --exists openssl 2>/dev/null; then
    return
  fi
  [[ "$ROOT" == "1" ]] || fail "OpenSSL development headers are missing; install libssl-dev/openssl-devel"
  log "installing OpenSSL development headers"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq libssl-dev curl xz-utils ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q openssl-devel curl xz ca-certificates >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q openssl-devel curl xz ca-certificates >/dev/null
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install libopenssl-devel curl xz >/dev/null
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm openssl curl xz >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache openssl-dev curl xz >/dev/null
  else
    fail "no supported package manager; install OpenSSL development headers manually"
  fi
}

mkdir -p "$PREFIX/bin" "$CONFIG_DIR" "$DATA_DIR" "$TLS_DIR"
BIN="$PREFIX/bin/hampaneld"

if [[ "$MODE" == "source" ]]; then
  ZIG="$(find_zig || true)"
  if [[ -z "$ZIG" ]]; then
    install_zig
    ZIG="$(find_zig || true)"
  fi
  [[ -n "$ZIG" ]] || fail "Zig toolchain not available"
  log "using ${ZIG} ($("$ZIG" version))"
  configure_package_mirror
  ensure_openssl

  # ------------------------------------------------------------------ build
  BUILD_ROOT="/opt/hampanel/build"
  if [[ "$ROOT" == "0" ]]; then BUILD_ROOT="${HOME}/.local/share/hampanel/build"; fi
  mkdir -p "$BUILD_ROOT"
  BUILD_DIR="$BUILD_ROOT/src"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  log "staging source into ${BUILD_DIR}"
  (cd "$SOURCE_DIR" && tar --exclude=.git --exclude=.zig-cache --exclude=zig-out --exclude=app -cf - .) |
    tar -xf - -C "$BUILD_DIR"

  log "compiling daemon (ReleaseSafe)"
  (cd "$BUILD_DIR/daemon" && "$ZIG" build -Doptimize=ReleaseSafe)

  install -m 0755 "$BUILD_DIR/daemon/zig-out/bin/hampaneld" "$BIN"
else
  ensure_runtime_libs
  log "installing prebuilt daemon from ${BINARY_FILE}"
  install -m 0755 "$BINARY_FILE" "$BIN"
  RISK_SRC="$(dirname "$BINARY_FILE")/hampanel-risk"
  if [[ -f "$RISK_SRC" ]]; then
    install -m 0755 "$RISK_SRC" "$PREFIX/bin/hampanel-risk"
  fi
fi

# Optional CO-RE backend. Release archives supply the object; source installs
# build it when BPF clang is available. Never mount bpffs or change boot args.
if [[ "$ROOT" == "1" ]]; then
  tamper_assets="$SOURCE_DIR/daemon/libexec"
  if [[ "$MODE" == "source" ]]; then tamper_assets="$BUILD_DIR/daemon/libexec"; fi
  if [[ -f "$tamper_assets/tamper_lsm.py" ]]; then
    obj="$tamper_assets/tamper.bpf.o"
    if [[ ! -f "$obj" && -f "$tamper_assets/tamper.bpf.c" ]] && command -v clang >/dev/null; then
      clang -O2 -g -target bpfel -c "$tamper_assets/tamper.bpf.c" -o "$obj" || log "optional BPF object build failed"
    fi
    if [[ -s "$obj" ]]; then
      install -d -m 0755 /usr/libexec/hampanel
      install -m 0644 "$obj" "$tamper_assets/tamper_lsm.py" /usr/libexec/hampanel/
    fi
  fi
fi

# Private FTPS files are optional in older release archives. Never enable or
# start the dedicated unit during installation; initialization is explicit.
if [[ "$ROOT" == "1" && "$NO_SYSTEMD" == "0" ]]; then
  ASSETS="$SOURCE_DIR"
  if [[ "$MODE" == "source" ]]; then ASSETS="$BUILD_DIR"; fi
  if [[ -f "$ASSETS/daemon/libexec/pure_ftpd.py" && -f "$ASSETS/deploy/hampanel-pure-ftpd.service" ]]; then
    if ! id -u hampanel-ftps >/dev/null 2>&1; then
      useradd --system --no-create-home --home-dir /var/lib/hampanel-ftps --shell /usr/sbin/nologin hampanel-ftps
    fi
    install -d -m 0711 -o root -g root /var/lib/hampanel-ftps
    install -d -m 0755 /usr/local/libexec/hampanel
    install -m 0755 "$ASSETS/daemon/libexec/pure_ftpd.py" /usr/local/libexec/hampanel/pure_ftpd.py
    install -m 0644 "$ASSETS/deploy/hampanel-pure-ftpd.service" /etc/systemd/system/hampanel-pure-ftpd.service
    systemctl daemon-reload
  else
    log "private FTPS assets missing from archive; skipping optional unit"
  fi
fi

# ClamAV helper must run as a dedicated non-root identity, not the daemon.
if [[ "$ROOT" == "1" ]]; then
  ASSETS="$SOURCE_DIR"
  if [[ "$MODE" == "source" ]]; then ASSETS="$BUILD_DIR"; fi
  if [[ -f "$ASSETS/tool/clamav.py" ]]; then
    install -d -m 0755 /usr/libexec/hampanel
    install -m 0755 "$ASSETS/tool/clamav.py" /usr/libexec/hampanel/clamav.py
    if ! getent passwd hampanel-clamav >/dev/null; then
      useradd --system --home-dir /var/lib/hampanel-clamav --shell /usr/sbin/nologin hampanel-clamav
    fi
    install -d -m 0700 -o hampanel-clamav -g "$(id -gn hampanel-clamav)" /var/lib/hampanel-clamav
  fi
fi

# ---------------------------------------------------------------- initialize
SAN_ARGS=()
for san in ${SANS[@]+"${SANS[@]}"}; do
  SAN_ARGS+=(--san "$san")
done

if [[ ! -f "$TLS_DIR/ca.crt.pem" ]]; then
  log "generating PKI, random entry prefix and enrollment bundle"
else
  log "existing PKI found, reusing certificates"
fi
INIT_ARGS=(init
  --config "$CONFIG_DIR/config.json"
  --tls-dir "$TLS_DIR"
  --data-dir "$DATA_DIR"
  --enroll-file "$ENROLL_FILE"
  --endpoint "$ENDPOINT"
  --install-mode "$INSTALL_MODE"
  --update-channel "$UPDATE_CHANNEL"
  --update-repo "$UPDATE_REPO"
  --service-name "$SERVICE_NAME")
if [[ -n "$PORT" ]]; then INIT_ARGS+=(--port "$PORT"); fi
if [[ -n "$MIRROR" ]]; then INIT_ARGS+=(--github-mirror "$MIRROR"); fi
if [[ "$ENTRY_PREFIX_SET" == "1" ]]; then INIT_ARGS+=(--entry-prefix "$ENTRY_PREFIX"); fi
if [[ ${#SANS[@]} -gt 0 ]]; then
  for san in "${SANS[@]}"; do INIT_ARGS+=(--san "$san"); done
fi
"$BIN" "${INIT_ARGS[@]}"

ACTUAL_ENDPOINT="$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ENROLL_FILE" | head -n1)"
ACTUAL_PREFIX="$(sed -n 's/.*"entry_prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ENROLL_FILE" | head -n1)"

# ------------------------------------------------------------------ service
if [[ "$NO_SYSTEMD" == "0" ]]; then
  UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
  log "installing systemd unit ${UNIT}"
  cat >"$UNIT" <<EOF
[Unit]
Description=Hampanel server panel daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} run --config ${CONFIG_DIR}/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if [[ "$NO_START" == "0" ]]; then
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      log "service ${SERVICE_NAME} is running"
    else
      log "service failed to start; inspect: journalctl -u ${SERVICE_NAME} -n 100"
    fi
  fi
fi

# --------------------------------------------------------------- update check
if [[ "$INSTALL_MODE" == "binary" ]]; then
  log "enabling daily update check"
  "$BIN" update --install-schedule --config "$CONFIG_DIR/config.json" ||
    log "warning: could not install the update check"
else
  "$BIN" update --remove-schedule --config "$CONFIG_DIR/config.json" >/dev/null 2>&1 || true
fi

# ----------------------------------------------------------------- firewall
# The daemon is useless if the port is unreachable, so open it in whatever
# firewall the host manages (ufw / firewalld). Best effort, never fatal.
open_panel_port() {
  local port
  port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$CONFIG_DIR/config.json" 2>/dev/null | head -n1)"
  [[ -n "$port" ]] || { log "could not read panel port; skipping firewall setup"; return 0; }

  local priv=""
  if [[ "$(id -u)" != "0" ]]; then
    if sudo -n true 2>/dev/null; then priv="sudo -n"; else
      log "no root/sudo: open TCP ${port} manually"; return 0
    fi
  fi

  if command -v ufw >/dev/null 2>&1 && $priv ufw status 2>/dev/null | grep -q "Status: active"; then
    if $priv ufw allow "${port}/tcp" >/dev/null 2>&1; then
      log "opened TCP ${port} in ufw"
    else
      log "warning: failed to add ufw rule for TCP ${port}"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && $priv firewall-cmd --state >/dev/null 2>&1; then
    if $priv firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 &&
       $priv firewall-cmd --reload >/dev/null 2>&1; then
      log "opened TCP ${port} in firewalld"
    else
      log "warning: failed to add firewalld rule for TCP ${port}"
    fi
  else
    log "no active ufw/firewalld detected; ensure TCP ${port} is reachable"
  fi
}
open_panel_port

chmod 600 "$ENROLL_FILE" 2>/dev/null || true
log "binary:      ${BIN}"
log "install mode: ${INSTALL_MODE}"
log "config:      ${CONFIG_DIR}/config.json"
log "endpoint:    ${ACTUAL_ENDPOINT:-unknown}"
log "entry prefix: ${ACTUAL_PREFIX:-<disabled>}"
log "enrollment:  ${ENROLL_FILE}"
if [[ "$NO_SYSTEMD" == "1" ]]; then
  log "run manually: ${BIN} run --config ${CONFIG_DIR}/config.json"
fi
