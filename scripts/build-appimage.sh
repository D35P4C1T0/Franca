#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build a self-contained Franca AppImage bundling the Rust Qt6/Kirigami UI,
# Carla audio engine, plugin bridges, discovery tools, and Qt/QML runtime libraries.

set -euo pipefail

export APPIMAGE_EXTRACT_AND_RUN=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ARCH="${ARCH:-$(uname -m)}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
VERSION="${VERSION:-$(sed -n 's/^VERSION[[:space:]]*:=[[:space:]]*//p' Makefile | head -n1)}"
[ -n "$VERSION" ] || VERSION="2.6.0-alpha1"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
NO_BUILD=0

for arg in "$@"; do
    case "$arg" in
        --arch=*)       ARCH="${arg#*=}" ;;
        --version=*)    VERSION="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --no-build)     NO_BUILD=1 ;;
        -h|--help)
            printf 'Usage: %s [--arch=x86_64] [--version=X.Y.Z] [--output-dir=dist] [--no-build]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

VERSION="${VERSION#v}"
TOOLS_DIR="$REPO_ROOT/build/appimage-tools"
BUILD_DIR="$REPO_ROOT/build/appimage"
APPDIR="$BUILD_DIR/Franca.AppDir"
OUTPUT_PATH="$OUTPUT_DIR/Franca-${VERSION}-${ARCH}.AppImage"

mkdir -p "$TOOLS_DIR" "$OUTPUT_DIR"

download_tool() {
    local url="$1"
    local dest="$2"
    if [ ! -x "$dest" ]; then
        echo "==> Downloading $(basename "$dest")"
        curl -fL --retry 3 -o "$dest.part" "$url"
        chmod +x "$dest.part"
        mv "$dest.part" "$dest"
    fi
}

LINUXDEPLOY="$TOOLS_DIR/linuxdeploy-${ARCH}.AppImage"
LINUXDEPLOY_QT="$TOOLS_DIR/linuxdeploy-plugin-qt-${ARCH}.AppImage"
APPIMAGETOOL="$TOOLS_DIR/appimagetool-${ARCH}.AppImage"

download_tool "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage" "$LINUXDEPLOY"
download_tool "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${ARCH}.AppImage" "$LINUXDEPLOY_QT"
download_tool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage" "$APPIMAGETOOL"

if [ "$NO_BUILD" -eq 0 ]; then
    echo "==> Building Franca backend, bridges, discovery, and Rust UI"
    make -j"$JOBS"
fi

[ -x "$REPO_ROOT/bin/franca-ui" ] || { echo "ERROR: bin/franca-ui not found. Run 'make' first." >&2; exit 1; }

echo "==> Preparing AppDir at $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"

make install DESTDIR="$APPDIR" PREFIX=/usr

# Ensure desktop file & icon are at the AppDir root and standard paths
cp -f "$REPO_ROOT/data/desktop/franca.desktop" "$APPDIR/franca.desktop"
cp -f "$REPO_ROOT/resources/256x256/franca.png" "$APPDIR/franca.png"
ln -sf "franca.png" "$APPDIR/.DirIcon"

# Locate qmake6 for linuxdeploy-plugin-qt
if [ -z "${QMAKE:-}" ]; then
    for cand in qmake6 /usr/lib/qt6/bin/qmake /usr/bin/qmake6; do
        if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
            QMAKE="$cand"
            break
        fi
    done
fi
export QMAKE="${QMAKE:-qmake6}"
export QML_SOURCES_PATHS="$REPO_ROOT/source/frontend-rs/qml"
export EXTRA_QT_PLUGINS="wayland-shell-integration;wayland-decoration-client;iconengines;imageformats;platformthemes"

echo "==> Running linuxdeploy + Qt6 plugin (QMAKE=$QMAKE)"
# The strip bundled with linuxdeploy cannot read RELR relocations in newer libraries.
NO_STRIP=1 PATH="$TOOLS_DIR:$PATH" "$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/lib/franca/franca-ui" \
    --library "$APPDIR/usr/lib/franca/libcarla_standalone2.so" \
    --library "$APPDIR/usr/lib/franca/libcarla_utils.so" \
    --desktop-file "$APPDIR/usr/share/applications/franca.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/franca.png" \
    --plugin qt

# Ensure KDE Kirigami QML module is bundled even if qmlimportscanner missed transitive KF6 imports
for sys_qml in /usr/lib/x86_64-linux-gnu/qt6/qml /usr/lib64/qt6/qml /usr/lib/qt6/qml; do
    if [ -d "$sys_qml/org/kde/kirigami" ]; then
        mkdir -p "$APPDIR/usr/qml/org/kde"
        if [ ! -d "$APPDIR/usr/qml/org/kde/kirigami" ]; then
            cp -a "$sys_qml/org/kde/kirigami" "$APPDIR/usr/qml/org/kde/"
        fi
        # Bundle shared libraries needed by Kirigami QML plugins
        find "$APPDIR/usr/qml/org/kde/kirigami" -name '*.so' -print0 | while IFS= read -r -d '' qso; do
            ldd "$qso" 2>/dev/null | awk '/=> \// {print $3}' | while IFS= read -r dep; do
                base="$(basename "$dep")"
                case "$base" in
                    libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libstdc++.so*|libgcc_s.so*|libGL*.so*|libEGL*.so*|libdrm.so*|libwayland-client.so*|libX11.so*|libxcb*.so*|libjack*.so*|libasound.so*|libpipewire*.so*)
                        continue
                        ;;
                esac
                [ -e "$APPDIR/usr/lib/$base" ] || cp -L "$dep" "$APPDIR/usr/lib/$base" 2>/dev/null || true
            done
        done
        break
    fi
done

# Never bundle host audio server / GPU driver libs inside the AppImage
for remove_pat in "libjack.so*" "libpipewire-*.so*" "libasound.so*" "libGL.so*" "libGLX.so*" "libEGL.so*" "libdrm.so*"; do
    rm -f "$APPDIR"/usr/lib/$remove_pat 2>/dev/null || true
done

# Write custom AppRun supporting PipeWire-JACK detection and KDE/Fusion style fallback
rm -f "$APPDIR/AppRun"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

export FRANCA_LIBDIR="$HERE/usr/lib/franca"
export FRANCA_DATADIR="$HERE/usr/share/franca"
export PATH="$FRANCA_LIBDIR:$HERE/usr/bin:$PATH"

if [ "${1:-}" = "msg" ]; then
    shift
    exec "$HERE/usr/bin/francamsg" "$@"
fi

export QT_PLUGIN_PATH="$HERE/usr/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QML_IMPORT_PATH="$HERE/usr/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
export QML2_IMPORT_PATH="$HERE/usr/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

# Keep bundled libs searchable after host PipeWire-JACK libraries
APP_LD="$HERE/usr/lib:$FRANCA_LIBDIR"

if [ -n "${XDG_RUNTIME_DIR:-}" ] && ls "$XDG_RUNTIME_DIR"/pipewire-* >/dev/null 2>&1; then
    for pw_dir in /usr/lib/pipewire-0.3/jack /usr/lib64/pipewire-0.3/jack /usr/lib/x86_64-linux-gnu/pipewire-0.3/jack; do
        if [ -d "$pw_dir" ]; then
            APP_LD="$pw_dir:$APP_LD"
        fi
    done
fi

export LD_LIBRARY_PATH="$APP_LD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Fall back to Qt Fusion style if org.kde.desktop QML style is not bundled or installed
if [ -z "${QT_QUICK_CONTROLS_STYLE:-}" ]; then
    if [ ! -d "$HERE/usr/qml/org/kde/desktop" ] && [ ! -d "/usr/lib/qt6/qml/org/kde/desktop" ] && [ ! -d "/usr/lib/x86_64-linux-gnu/qt6/qml/org/kde/desktop" ]; then
        export QT_QUICK_CONTROLS_STYLE="Fusion"
    fi
fi

exec "$FRANCA_LIBDIR/franca-ui" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

echo "==> Packaging AppImage: $OUTPUT_PATH"
ARCH="$ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUTPUT_PATH"
chmod 755 "$OUTPUT_PATH"

(cd "$OUTPUT_DIR" && sha256sum "$(basename "$OUTPUT_PATH")" > "$(basename "$OUTPUT_PATH").sha256")
echo "==> Built AppImage: $OUTPUT_PATH"
