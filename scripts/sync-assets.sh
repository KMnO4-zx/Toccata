#!/bin/bash
# 把 shared/ 下的布局与主题同步进各 App 的 SwiftPM Resources。
# shared/ 是唯一事实来源；改完布局/主题后跑一次本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."

OVERLAY_RES="apps/toccata-overlay/Resources"
STUDIO_RES="apps/toccata-studio/Resources"

mkdir -p "$OVERLAY_RES/Layout" "$OVERLAY_RES/Themes" "$STUDIO_RES/Layout" "$STUDIO_RES/Themes"
cp shared/layout/*.json "$OVERLAY_RES/Layout/"
cp shared/theme/*.json "$OVERLAY_RES/Themes/"
cp shared/layout/*.json "$STUDIO_RES/Layout/"
cp shared/theme/*.json "$STUDIO_RES/Themes/"

echo "synced: layout + themes -> overlay & studio Resources"
