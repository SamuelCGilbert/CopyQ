#!/bin/bash
# Builds CopyQ for Wayland (unofficial) as an AppImage.
# Run as root in a clean Ubuntu 24.04 container. The GitHub workflow
# .github/workflows/wayland-appimage.yml does this; to build it yourself:
#   docker run --rm -v "$PWD:/src" -w /src ubuntu:24.04 utils/appimage-wayland/build.sh
# Qt and the KDE Frameworks come from KDE neon's Ubuntu 24.04 archive, so the
# AppImage runs on Ubuntu 24.04 and newer (the official one needs 26.04).
# The AppImage ends up in the source folder.
set -euo pipefail

SRC=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${WORK:-/tmp/appimage-build}
VERSION=${VERSION:-$(sed -n 's/^set(copyq_version "\(.*\)")/\1/p' "$SRC/src/version.cmake" 2>/dev/null)-wayland}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
gpg --dearmor < "$SRC/utils/github/kde-neon-public.key" > /etc/apt/keyrings/neon.gpg
echo "deb [signed-by=/etc/apt/keyrings/neon.gpg] https://archive.neon.kde.org/user noble main" \
  > /etc/apt/sources.list.d/neon.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  g++ cmake ninja-build extra-cmake-modules file git wget zsync \
  libxfixes-dev libxtst-dev libwayland-dev libegl-dev \
  qt6-base-private-dev qt6-base-dev qt6-base-dev-tools qt6-tools-dev \
  qt6-tools-dev-tools qt6-l10n-tools qt6-declarative-dev qt6-svg-dev \
  qt6-wayland qt6-wayland-dev qt6-wayland-dev-tools \
  libqca-qt6-dev libqca-qt6-plugins qtkeychain-qt6-dev \
  libkf6notifications-dev kf6-kstatusnotifieritem-dev libkf6guiaddons-dev

# miniaudio 0.11.25, as in the official build
MINIAUDIO_COMMIT=9634bedb5b5a2ca38c1ee7108a9358a4e233f14d
curl -sSLo "$SRC/src/miniaudio.h" --fail --retry 3 \
  "https://raw.githubusercontent.com/mackron/miniaudio/$MINIAUDIO_COMMIT/miniaudio.h"
echo "ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89  $SRC/src/miniaudio.h" | sha256sum -c

mkdir -p "$WORK"
cd "$WORK"
fetch() { # name url sha256
  [ -f "$1" ] || wget -q -O "$1" "$2"
  echo "$3  $1" | sha256sum -c
  chmod +x "$1"
  # Clear the AppImage marker bytes, so a host with an AppImage handler
  # registered in binfmt_misc (such as AppImageLauncher) doesn't take over
  # running the tools inside the container
  printf '\0\0\0' | dd of="$1" bs=1 seek=8 conv=notrunc status=none
}
fetch linuxdeploy https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage \
  c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
fetch linuxdeploy-plugin-qt https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage \
  15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724
fetch linuxdeploy-plugin-appimage https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-appimage-x86_64.AppImage \
  992d502a248e14ab185448ddf6f6e7d25558cb84d4623c354c3af350c25fccb3
export PATH="$WORK:$PATH"
# Containers have no FUSE, so the tools unpack themselves instead of mounting
export APPIMAGE_EXTRACT_AND_RUN=1

cmake -S "$SRC" -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
  -DWITH_APPIMAGE=TRUE -DWITH_TESTS=OFF -DWITH_QCA_ENCRYPTION=TRUE -DWITH_NATIVE_NOTIFICATIONS=TRUE
cmake --build build

# Same steps as the official AppImage (.github/workflows/build-linux.yml)
export DESTDIR="$WORK/AppDir"
rm -rf "$DESTDIR"
cmake --install build
qt_plugins="$(qmake6 -query QT_INSTALL_PLUGINS)"
deps_only_flags=()
for dir in kf6/kwindowsystem wayland-shell-integration wayland-decoration-client \
    wayland-graphics-integration-client; do
  if [ -d "$qt_plugins/$dir" ]; then
    mkdir -p "$DESTDIR/usr/plugins/$dir"
    cp -a "$qt_plugins/$dir"/*.so "$DESTDIR/usr/plugins/$dir/"
    deps_only_flags+=(--deploy-deps-only "$DESTDIR/usr/plugins/$dir")
  fi
done
mkdir -p "$DESTDIR/usr/plugins/crypto"
cp -a "$(find /usr/lib -name 'libqca-ossl.so' -print -quit)" "$DESTDIR/usr/plugins/crypto/"
deps_only_flags+=(--deploy-deps-only "$DESTDIR/usr/plugins/crypto")

export EXTRA_QT_MODULES="svg;tls" EXTRA_PLATFORM_PLUGINS=libqwayland.so QMAKE=qmake6
export LDAI_OUTPUT="CopyQ-$VERSION-x86_64.AppImage"
export LDAI_UPDATE_INFORMATION="gh-releases-zsync|SamuelCGilbert|CopyQ|latest|CopyQ-*-x86_64.AppImage.zsync"
linuxdeploy --appdir "$DESTDIR" \
  --desktop-file "$DESTDIR/usr/share/applications/com.github.hluk.copyq.desktop" \
  --icon-file "$DESTDIR/usr/share/icons/hicolor/scalable/apps/copyq.svg" \
  --executable "$DESTDIR/usr/bin/copyq" \
  "${deps_only_flags[@]}" --plugin qt --output appimage

mv "$LDAI_OUTPUT" "$LDAI_OUTPUT.zsync" "$SRC/"
cd "$SRC"
sha256sum "$LDAI_OUTPUT" > "$LDAI_OUTPUT.sha256sum"
cat "$LDAI_OUTPUT.sha256sum"
