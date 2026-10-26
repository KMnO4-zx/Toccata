#!/bin/bash
# 把 shared/layout/ 下的键盘布局同步进 Studio 的 SwiftPM Resources。
# shared/layout/ 是唯一事实来源；改完布局后跑一次本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."

STUDIO_RES="apps/toccata-studio/Resources"

mkdir -p "$STUDIO_RES/Layout"
cp shared/layout/*.json "$STUDIO_RES/Layout/"

echo "synced: keyboard layout -> studio Resources"
