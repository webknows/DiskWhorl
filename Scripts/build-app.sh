#!/bin/zsh
# Builds DiskWhorl.app from the Swift package and signs it ad hoc for local use.
#
# Usage:  Scripts/build-app.sh [--install] [--universal]
#   --install    also copy the app to ~/Applications
#   --universal  build for both Apple silicon and Intel (requires Xcode, not only
#                the Command Line Tools); the default builds for this Mac only
#
# Optional environment variables:
#   BUNDLE_ID   bundle identifier (default: local.diskwhorl.DiskWhorl)
#   VERSION     marketing version (default: 1.0)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/DiskWhorl.app"
BUNDLE_ID="${BUNDLE_ID:-local.diskwhorl.DiskWhorl}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

INSTALL=0
ARCH_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift was not found. Install Xcode from the App Store, or the Command Line Tools with:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

echo "▸ Compiling (release)…"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/DiskWhorl"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/DiskWhorl"

echo "▸ Rendering icon…"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
ICON_ENTRY=""
if "$BINARY" --render-iconset "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
  ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "  (icon generation skipped)"
fi
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DiskWhorl</string>
  <key>CFBundleDisplayName</key><string>DiskWhorl</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>DiskWhorl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  ${ICON_ENTRY}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Released under the MIT License.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSDesktopFolderUsageDescription</key><string>DiskWhorl measures the size of files on your Desktop. It does not read their contents.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DiskWhorl measures the size of files in Documents. It does not read their contents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DiskWhorl measures the size of files in Downloads. It does not read their contents.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>DiskWhorl measures how space is used on removable disks.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>DiskWhorl measures how space is used on network volumes.</string>
  <key>NSAppleEventsUsageDescription</key><string>DiskWhorl uses the system authentication dialog to run administrator scans you request.</string>
</dict>
</plist>
PLIST

echo "▸ Signing ad hoc…"
codesign --force --sign - --timestamp=none "$APP"

if [[ $INSTALL -eq 1 ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DiskWhorl.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "✓ Installed to ~/Applications/DiskWhorl.app"
else
  echo "✓ Built build/DiskWhorl.app"
fi
