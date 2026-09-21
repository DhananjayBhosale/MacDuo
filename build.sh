#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${MACDUO_BUILD_DIR:-${LIDFLOW_BUILD_DIR:-.build}}"
BUILD_ARCH="${MACDUO_ARCH:-${LIDFLOW_ARCH:-arm64}}"
case "$BUILD_ARCH" in
  arm64) DEFAULT_OUTPUT_DIR="build" ;;
  x86_64) DEFAULT_OUTPUT_DIR="build-intel" ;;
  *) printf 'Unsupported build architecture: %s\n' "$BUILD_ARCH" >&2; exit 2 ;;
esac
OUTPUT_DIR="${MACDUO_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
swift build -c release --scratch-path "$BUILD_DIR" --arch "$BUILD_ARCH"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --arch "$BUILD_ARCH" --show-bin-path)"
SIGNING_IDENTITY="${MACDUO_SIGNING_IDENTITY:-${LIDFLOW_SIGNING_IDENTITY:-}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  if [[ -f signing-identity.txt ]]; then
    SIGNING_IDENTITY="$(cat signing-identity.txt)"
  else
    SIGNING_IDENTITY="-"
  fi
fi
mkdir -p "$OUTPUT_DIR"
APP="$(cd "$OUTPUT_DIR" && pwd)/Mac Duo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacDuo" "$APP/Contents/MacOS/MacDuo"
# Remove debug symbols containing local build paths before signing the app.
xcrun strip -S "$APP/Contents/MacOS/MacDuo"
# L10n loads this resource bundle from the packaged app Resources directory.
# Ship translations inside the app so it remains relocatable.
ditto --norsrc --noextattr "$BIN_DIR/MacDuo_MacDuo.bundle" "$APP/Contents/Resources/MacDuo_MacDuo.bundle"
for localization in Sources/MacDuo/Resources/*.lproj; do
  locale="$(basename "$localization")"
  mkdir -p "$APP/Contents/Resources/$locale"
  cp "$localization/InfoPlist.strings" "$APP/Contents/Resources/$locale/InfoPlist.strings"
done
cp Resources/MacDuoMark.png Resources/MacDuo.icns "$APP/Contents/Resources/"
cp ATTRIBUTION.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>ja</string></array>
<key>CFBundleName</key><string>Mac Duo</string>
<key>CFBundleDisplayName</key><string>Mac Duo</string>
<key>CFBundleIdentifier</key><string>local.lidflow.mac</string>
<key>CFBundleExecutable</key><string>MacDuo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>MacDuo</string>
<key>CFBundleShortVersionString</key><string>0.1.15</string>
<key>CFBundleVersion</key><string>17</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Mac Duo displays a temporary, animated copy of your desktop as you move the lid. Frames stay in memory on this Mac.</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.lidflow.mac "$APP"
codesign --verify --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
printf 'Built %s\n' "$APP"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  printf 'Ad-hoc development build. Use a consistent Apple Development identity to preserve Screen Recording access across updates.\n'
fi
