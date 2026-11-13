#!/bin/bash
# Builds MacROOT.app for x86_64 and wraps it in MacROOT-Installer.pkg
#
# Usage:   ./Packaging/build_installer.sh
# Options (environment variables):
#   APP_SIGN_ID   "Developer ID Application: …"   (default: ad-hoc "-")
#   PKG_SIGN_ID   "Developer ID Installer: …"     (default: unsigned pkg)
#   VERSION       package version                  (default: 1.0)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
VERSION="${VERSION:-1.2}"
APP_SIGN_ID="${APP_SIGN_ID:--}"
PKGROOT="$BUILD/pkgroot"
OUT="$ROOT/MacROOT-Installer.pkg"

echo "▶ Building MacROOT.app (Release, x86_64)…"
rm -rf "$BUILD"
xcodebuild -project MacROOT.xcodeproj -scheme MacROOT -configuration Release \
    -arch x86_64 ONLY_ACTIVE_ARCH=NO -derivedDataPath "$BUILD/dd" \
    CODE_SIGN_IDENTITY="$APP_SIGN_ID" CODE_SIGN_STYLE=Manual \
    build | tail -n 25

APP="$BUILD/dd/Build/Products/Release/MacROOT.app"
[ -d "$APP" ] || { echo "✗ Build did not produce $APP"; exit 1; }

echo "▶ Staging payload…"
mkdir -p "$PKGROOT/Applications"
ditto "$APP" "$PKGROOT/Applications/MacROOT.app"
codesign --force --deep --sign "$APP_SIGN_ID" "$PKGROOT/Applications/MacROOT.app"
lipo -archs "$PKGROOT/Applications/MacROOT.app/Contents/MacOS/MacROOT"

echo "▶ Building component package…"
chmod +x Packaging/scripts/postinstall
pkgbuild --root "$PKGROOT" \
         --identifier com.pine.MacROOT \
         --version "$VERSION" \
         --install-location / \
         --scripts Packaging/scripts \
         "$BUILD/MacROOT-component.pkg"

echo "▶ Building installer…"
SIGN_ARGS=()
if [ -n "${PKG_SIGN_ID:-}" ]; then SIGN_ARGS=(--sign "$PKG_SIGN_ID"); fi
productbuild --distribution Packaging/distribution.xml \
             --resources Packaging/resources \
             --package-path "$BUILD" \
             --version "$VERSION" \
             ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
             "$OUT"

echo "✓ Done: $OUT"
echo "  Unsigned/ad-hoc installers: right-click ▸ Open the first time, or run:"
echo "  xattr -d com.apple.quarantine \"$OUT\""
