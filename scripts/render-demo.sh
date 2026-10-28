#!/bin/bash
# Render the real SwiftUI views with isolated fictional data for the README.
set -euo pipefail
DEMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_PACKAGE="$DEMO_ROOT/apps/toccata-studio"
DEMO_BUILD="$DEMO_ROOT/.build/demo"
DEMO_APP="$DEMO_BUILD/Toccata Demo.app"
DEMO_OUTPUT="${1:-$DEMO_ROOT/images}"

"$DEMO_ROOT/scripts/sync-assets.sh"
swift build --package-path "$DEMO_PACKAGE" --scratch-path "$DEMO_BUILD/swift" \
  -c release -Xswiftc -DTOCCATA_DEMO
DEMO_BIN="$(swift build --package-path "$DEMO_PACKAGE" --scratch-path "$DEMO_BUILD/swift" \
  -c release -Xswiftc -DTOCCATA_DEMO --show-bin-path)"
mkdir -p "$DEMO_APP/Contents/MacOS" "$DEMO_APP/Contents/Resources" "$DEMO_OUTPUT"
cp "$DEMO_BIN/toccata-studio" "$DEMO_APP/Contents/MacOS/ToccataDemo"
ditto "$DEMO_BIN/toccata-studio_toccata-studio.bundle" \
  "$DEMO_APP/Contents/Resources/toccata-studio_toccata-studio.bundle"
cat > "$DEMO_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ToccataDemo</string>
<key>CFBundleIdentifier</key><string>com.toccata.demo</string>
<key>CFBundleName</key><string>Toccata Demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$DEMO_APP"
"$DEMO_APP/Contents/MacOS/ToccataDemo" "$DEMO_OUTPUT"
