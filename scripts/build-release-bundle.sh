#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build a portable prebuilt Linux binary archive of Franca (backend + bridges + Rust Qt6/Kirigami UI).

set -euo pipefail

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
BUNDLE_NAME="Franca-${VERSION}-linux-${ARCH}"
STAGE_ROOT="$REPO_ROOT/build/release-bundle"
BUNDLE_DIR="$STAGE_ROOT/$BUNDLE_NAME"

if [ "$NO_BUILD" -eq 0 ]; then
    echo "==> Building Franca backend, bridges, discovery, and Rust UI"
    make -j"$JOBS"
fi

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR" "$OUTPUT_DIR"

echo "==> Staging Franca into $BUNDLE_DIR"
make install DESTDIR="$BUNDLE_DIR" PREFIX=/usr

# Flatten /usr into bundle root so extracting anywhere gives bin/, lib/, share/
if [ -d "$BUNDLE_DIR/usr" ]; then
    cp -a "$BUNDLE_DIR/usr/." "$BUNDLE_DIR/"
    rm -rf "$BUNDLE_DIR/usr"
fi

# Make the installed launcher fully relocatable (do not hardcode /usr)
cp -f "$REPO_ROOT/data/franca" "$BUNDLE_DIR/bin/franca"
cp -f "$REPO_ROOT/scripts/francamsg" "$BUNDLE_DIR/bin/francamsg"
chmod 755 "$BUNDLE_DIR/bin/franca" "$BUNDLE_DIR/bin/francamsg"

# Fix relative resources symlink inside lib/franca
ln -sfn "../../share/franca/resources" "$BUNDLE_DIR/lib/franca/resources"

# Include README & license
cp -f "$REPO_ROOT/README.md" "$BUNDLE_DIR/README.md"
[ -f "$REPO_ROOT/doc/GPL.txt" ] && cp -f "$REPO_ROOT/doc/GPL.txt" "$BUNDLE_DIR/LICENSE"

ARCHIVE_PATH="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
echo "==> Creating archive $ARCHIVE_PATH"
tar -C "$STAGE_ROOT" -czf "$ARCHIVE_PATH" "$BUNDLE_NAME"

(cd "$OUTPUT_DIR" && sha256sum "$(basename "$ARCHIVE_PATH")" > "$(basename "$ARCHIVE_PATH").sha256")
echo "==> Built prebuilt binary bundle: $ARCHIVE_PATH"
