#!/usr/bin/env bash
# Package the Flutter Linux client bundle as a single AppImage.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

name=hampanel
version=$(sed -n 's/^version:[[:space:]]*\([^+ ]*\).*/\1/p' "$repo_root/app/pubspec.yaml" | head -n1)
version=${version:-0.1.0}
bundle="$repo_root/app/build/linux/x64/release/bundle"
output=""
icon="$repo_root/app/windows/runner/resources/app_icon.ico"
cache="${HAMPANEL_PACKAGE_CACHE:-$repo_root/app/build/packaging/cache}"
arch=${ARCH:-x86_64}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --bundle <dir>    Flutter Linux bundle directory (default: app/build/linux/x64/release/bundle)
  --output <file>   Output AppImage path (default: app/build/packaging/<name>-<version>-<arch>.AppImage)
  --version <ver>   Version embedded in the AppImage filename (default: pubspec version)
  --name <name>     Application/binary name (default: hampanel)
  --icon <file>     PNG or ICO icon used for the desktop entry (default: Windows app icon)
  --cache <dir>     Download cache for appimagetool (default: app/build/packaging/cache)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) bundle=${2:?}; shift 2 ;;
    --output) output=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --name) name=${2:?}; shift 2 ;;
    --icon) icon=${2:?}; shift 2 ;;
    --cache) cache=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$bundle" ]] || { echo "bundle directory not found: $bundle" >&2; exit 1; }
[[ -x "$bundle/$name" ]] || { echo "executable not found: $bundle/$name" >&2; exit 1; }

output=${output:-$repo_root/app/build/packaging/$name-$version-$arch.AppImage}
mkdir -p "$(dirname "$output")" "$cache"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
appdir="$workdir/AppDir"

mkdir -p "$appdir/usr/bin"
cp -a "$bundle/." "$appdir/usr/bin/"

cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/hampanel" "$@"
EOF
chmod 0755 "$appdir/AppRun"

cat > "$appdir/$name.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Hampanel
Comment=Hampanel server panel client
Exec=$name
Icon=$name
Terminal=false
Categories=Network;
StartupWMClass=work.dawncall.hampanel
X-AppImage-Version=$version
EOF

if [[ "$icon" == *.png ]]; then
  cp "$icon" "$appdir/$name.png"
elif command -v magick >/dev/null 2>&1; then
  magick "${icon}[0]" -resize 256x256 "$appdir/$name.png"
elif command -v convert >/dev/null 2>&1; then
  convert "${icon}[0]" -resize 256x256 "$appdir/$name.png"
else
  echo "need ImageMagick (magick/convert) to convert $icon, or pass --icon <png>" >&2
  exit 1
fi
ln -sf "$name.png" "$appdir/.DirIcon"

tool="$cache/appimagetool-$arch.AppImage"
if [[ ! -x "$tool" ]]; then
  echo "downloading appimagetool..." >&2
  curl -fsSL -o "$tool" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$arch.AppImage"
  chmod 0755 "$tool"
fi

rm -f "$output"
ARCH="$arch" APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --no-appstream "$appdir" "$output"
chmod 0755 "$output"

echo "$output"
