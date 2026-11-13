#!/usr/bin/env bash
# Hampanel Linux installer.
#
# Installs either a published release binary (default) or builds from source.
# Binary installs enable the built-in update channel; source installs do not.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

REPO="${HAMPANEL_REPO:-colisys/hampanel}"
CHANNEL="${HAMPANEL_CHANNEL:-stable}"
RELEASE_BASE="${HAMPANEL_RELEASE_BASE:-}"
MODE="binary"
REF=""
ENDPOINT=""
PORT=""
ENTRY_PREFIX=""
ENTRY_PREFIX_SET=0
SANS=()
PREFIX=""
CONFIG_DIR=""
DATA_DIR=""
TLS_DIR=""
ENROLL_FILE=""
SERVICE_NAME="hampanel"
NO_START=0
NO_SYSTEMD=0

log() { printf '[hampanel-install] %s\n' "$*" >&2; }
fail() { printf '[hampanel-install] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Hampanel Linux installer

Usage:
  hampanel-install-linux.sh --endpoint HOST [options]

  --mode binary|source   install a release binary (default) or build from source
  --channel stable|nightly   binary release channel (default: stable)
  --ref <branch|tag>     source ref for --mode source (default: nightly)
  --repo <owner/repo>    GitHub repository (default: colisys/hampanel)
  --endpoint <host>      public endpoint host (port optional)
  --port <port>          daemon port (default: random free port)
  --entry-prefix <path>  secret entry prefix (default: random /token)
  --san <host|ip>        extra certificate SAN (repeatable)
  --prefix <dir>         install prefix (default: /usr/local)
  --config-dir <dir>     configuration directory (default: /etc/hampanel)
  --data-dir <dir>       data directory (default: /var/lib/hampanel)
  --tls-dir <dir>        PKI directory (default: <config-dir>/tls)
  --enroll-file <path>   enrollment bundle path (default: <config-dir>/enroll.json)
  --service-name <name>  systemd unit name (default: hampanel)
  --no-systemd           do not install a systemd unit
  --no-start             install without starting the service
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --channel) CHANNEL="${2:?}"; shift 2 ;;
    --ref) REF="${2:?}"; shift 2 ;;
    --repo) REPO="${2:?}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --entry-prefix) ENTRY_PREFIX="${2:-}"; ENTRY_PREFIX_SET=1; shift 2 ;;
    --san) SANS+=("${2:?}"); shift 2 ;;
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --config-dir) CONFIG_DIR="${2:?}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:?}"; shift 2 ;;
    --tls-dir) TLS_DIR="${2:?}"; shift 2 ;;
    --enroll-file) ENROLL_FILE="${2:?}"; shift 2 ;;
    --service-name) SERVICE_NAME="${2:?}"; shift 2 ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    --no-start) NO_START=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ "$MODE" == "binary" || "$MODE" == "source" ]] || fail "--mode must be binary or source"
[[ -n "$ENDPOINT" ]] || fail "--endpoint is required"

for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BOOTSTRAP_ARGS=(--endpoint "$ENDPOINT")
if [[ -n "$PORT" ]]; then BOOTSTRAP_ARGS+=(--port "$PORT"); fi
if [[ "$ENTRY_PREFIX_SET" == "1" ]]; then BOOTSTRAP_ARGS+=(--entry-prefix "$ENTRY_PREFIX"); fi
for san in ${SANS[@]+"${SANS[@]}"}; do BOOTSTRAP_ARGS+=(--san "$san"); done
if [[ -n "$PREFIX" ]]; then BOOTSTRAP_ARGS+=(--prefix "$PREFIX"); fi
if [[ -n "$CONFIG_DIR" ]]; then BOOTSTRAP_ARGS+=(--config-dir "$CONFIG_DIR"); fi
if [[ -n "$DATA_DIR" ]]; then BOOTSTRAP_ARGS+=(--data-dir "$DATA_DIR"); fi
if [[ -n "$TLS_DIR" ]]; then BOOTSTRAP_ARGS+=(--tls-dir "$TLS_DIR"); fi
if [[ -n "$ENROLL_FILE" ]]; then BOOTSTRAP_ARGS+=(--enroll-file "$ENROLL_FILE"); fi
if [[ "$NO_SYSTEMD" == "1" ]]; then BOOTSTRAP_ARGS+=(--no-systemd); fi
if [[ "$NO_START" == "1" ]]; then BOOTSTRAP_ARGS+=(--no-start); fi
if [[ "$SERVICE_NAME" != "hampanel" ]]; then BOOTSTRAP_ARGS+=(--service-name "$SERVICE_NAME"); fi

release_base() {
  if [[ -n "$RELEASE_BASE" ]]; then
    echo "$RELEASE_BASE"
    return
  fi
  if [[ "$1" == "stable" || "$1" == "latest" ]]; then
    echo "https://github.com/${REPO}/releases/latest/download"
  else
    echo "https://github.com/${REPO}/releases/download/$1"
  fi
}

verify_checksum() {
  local asset="$1" sums="$2" file="$3" expected actual
  expected="$(awk -v a="$asset" '$2==a || $2=="*"a {print $1; exit}' "$sums")"
  [[ -n "$expected" ]] || fail "checksum for $asset not published"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "checksum mismatch for $asset"
  log "verified checksum for $asset"
}

if [[ "$MODE" == "binary" ]]; then
  BASE="$(release_base "$CHANNEL")"
  asset="hampanel-daemon-linux-x86_64.tar.gz"
  log "downloading ${BASE}/${asset}"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/$asset" "$BASE/$asset" ||
    fail "failed to download $asset"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt" ||
    fail "failed to download SHA256SUMS.txt"
  verify_checksum "$asset" "$TMP/SHA256SUMS.txt" "$TMP/$asset"

  mkdir -p "$TMP/pkg"
  tar -xzf "$TMP/$asset" -C "$TMP/pkg"
  [[ -f "$TMP/pkg/bootstrap.sh" ]] || fail "release archive is missing bootstrap.sh"
  [[ -x "$TMP/pkg/hampaneld" ]] || chmod 0755 "$TMP/pkg/hampaneld"

  bash "$TMP/pkg/bootstrap.sh" \
    --source "$TMP/pkg" \
    --mode binary \
    --binary-file "$TMP/pkg/hampaneld" \
    --install-mode binary \
    --update-channel "$CHANNEL" \
    --update-repo "$REPO" \
    "${BOOTSTRAP_ARGS[@]}"
else
  REF="${REF:-nightly}"
  if [[ "$REF" == v* || "$REF" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    src_url="https://github.com/${REPO}/archive/refs/tags/${REF}.tar.gz"
  else
    src_url="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"
  fi
  log "downloading source ${src_url}"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/src.tar.gz" "$src_url" ||
    fail "failed to download source archive"
  mkdir -p "$TMP/src"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" --strip-components=1
  [[ -f "$TMP/src/deploy/bootstrap.sh" ]] || fail "source archive is missing deploy/bootstrap.sh"

  bash "$TMP/src/deploy/bootstrap.sh" \
    --source "$TMP/src" \
    --mode source \
    --install-mode source \
    --update-channel "$CHANNEL" \
    --update-repo "$REPO" \
    "${BOOTSTRAP_ARGS[@]}"
fi
