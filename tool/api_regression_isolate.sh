#!/bin/bash
# Usage: sudo bash tool/api_regression_isolate.sh ABSOLUTE_NEW_DIRECTORY
# No business socket, host filesystem, or external network enters the chroot.
set -euo pipefail
base=$1
[[ $base = /* && ! -e $base ]] || exit 2
mkdir -p "$base/root/work/fake" "$base/root/dev" "$base/root/proc" "$base/root/tmp"
root=$base/root
# Synthetic account database only; never copy host users or authorized keys.
mkdir -p "$root/etc" "$root/root/.ssh"
printf 'root:x:0:0:Regression:/root:/bin/sh\n' > "$root/etc/passwd"
printf '127.0.0.1 localhost\n' > "$root/etc/hosts"
printf 'root:x:0:\n' > "$root/etc/group"
touch "$root/root/.ssh/authorized_keys"
touch "$root/dev/null"
copy_binary() {
  local bin=$1
  mkdir -p "$root$(dirname "$bin")"; cp -L "$bin" "$root$bin"
  ldd "$bin" | awk '/=> \/|^\s*\// {for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | while read -r lib; do
    mkdir -p "$root$(dirname "$lib")"; cp -L "$lib" "$root$lib"
  done
}
copy_binary /bin/tar
ln -s /bin/tar "$root/work/fake/tar"
copy_binary /bin/sh
copy_binary /usr/bin/python3
copy_binary /usr/bin/openssl
copy_binary "$(pwd)/daemon/zig-out/bin/hampaneld"
cp daemon/zig-out/bin/hampaneld "$root/work/hampaneld"
cp tool/api_regression.py "$root/work/test.py"
cp daemon/src/api/mod.zig "$root/work/routes.zig"
cp tool/api_regression_fake.py "$root/work/fake-engine.py"
chmod +x "$root/work/fake-engine.py"
mkdir -p "$root/usr/lib"
cp -a /usr/lib/python3* "$root/usr/lib/"
# Extension modules may have extra dependencies not reported by python's ldd.
find "$root/usr/lib" -name '*.so' | while read -r mod; do
 (ldd "$mod" 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | while read -r lib; do
  [[ -e "$lib" ]] || continue
  mkdir -p "$root$(dirname "$lib")"; cp -Ln "$lib" "$root$lib"
 done
done
printf '#!/bin/sh\necho "fake dependency unavailable: $0 $*" >&2\nexit 42\n' > "$root/work/fake/deny"
chmod +x "$root/work/fake/deny"
for name in docker podman docker-compose podman-compose systemctl nginx caddy curl wget git bash crontab ufw nft iptables service nix apt apt-get yum dnf reboot shutdown; do
 cp "$root/work/fake/deny" "$root/work/fake/$name"
done
ln -s /usr/bin/openssl "$root/work/fake/openssl"
# Namespace capability is tested before any daemon starts. chroot contains no engines.
export HAMPANEL_ISOLATED=1
unshare --mount --net --pid --fork --kill-child bash -c '
 set -e
 mount --make-rprivate /
 ip link set lo up
 mount -t proc proc "$1/proc"
 mount --bind /dev/null "$1/dev/null"
 mkdir -p "$1/dev/pts"
 mount -t devpts -o newinstance,ptmxmode=0666 devpts "$1/dev/pts"
 ln -s pts/ptmx "$1/dev/ptmx"
 exec chroot "$1" /usr/bin/python3 /work/test.py
' _ "$root"
