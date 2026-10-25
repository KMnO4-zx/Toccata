#!/bin/bash
# Build a local, ad-hoc signed macOS app with the keyboard collection helper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/apps/toccata-studio"
CACHE="$ROOT/.build"
mkdir -p "$CACHE/clang-cache" "$CACHE/swift-cache" "$CACHE/spm-cache" "$ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$CACHE/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/swift-cache"
"$ROOT/scripts/sync-assets.sh"

cargo build --manifest-path "$ROOT/Cargo.toml" --release --locked
swift build --package-path "$PACKAGE" --configuration release --disable-sandbox --cache-path "$CACHE/spm-cache"
BIN_DIR="$(swift build --package-path "$PACKAGE" --configuration release --disable-sandbox --cache-path "$CACHE/spm-cache" --show-bin-path)"
STAGING="$(mktemp -d "$ROOT/dist/.Toccata.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Toccata.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/toccata-studio" "$APP/Contents/MacOS/Toccata"
cp "$ROOT/target/release/toccata-core" "$APP/Contents/Helpers/toccata-core"
cp -R "$BIN_DIR/toccata-studio_toccata-studio.bundle" "$APP/Contents/Resources/"
cp "$PACKAGE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Toccata</string>
<key>CFBundleIdentifier</key><string>com.toccata.studio</string>
<key>CFBundleName</key><string>Toccata</string>
<key>CFBundleDisplayName</key><string>Toccata</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/toccata-core"
codesign --force --sign - "$APP"
rm -rf "$ROOT/dist/Toccata.app"
mv "$APP" "$ROOT/dist/Toccata.app"
echo "Built: $ROOT/dist/Toccata.app"
