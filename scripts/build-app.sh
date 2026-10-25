#!/bin/bash
# Build a local macOS app with the keyboard collection helper.
# Ad-hoc signing needs no keychain identity; a signing identity can be supplied explicitly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/apps/toccata-studio"
SIGN_IDENTITY="${TOCCATA_SIGN_IDENTITY:--}"
SIGN_REQUIREMENTS='=designated => identifier "com.toccata.studio"'
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/toccata-studio" "$APP/Contents/MacOS/Toccata"
cp "$ROOT/target/release/toccata-core" "$APP/Contents/MacOS/toccata-core"
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
<key>NSInputMonitoringUsageDescription</key><string>Toccata 需要监控键盘输入，以统计键盘活跃度、每个按键的使用次数和应用使用时长。键码和活动记录仅保存在本机。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$SIGN_IDENTITY" --identifier com.toccata.studio --requirements "$SIGN_REQUIREMENTS" "$APP/Contents/MacOS/toccata-core"
codesign --force --sign "$SIGN_IDENTITY" --requirements "$SIGN_REQUIREMENTS" "$APP"
rm -rf "$ROOT/dist/Toccata.app"
mv "$APP" "$ROOT/dist/Toccata.app"
echo "Built: $ROOT/dist/Toccata.app"
