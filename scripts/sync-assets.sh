#!/bin/bash
# 把 shared/ 下的键盘布局和应用版本同步进 Studio 的 SwiftPM Resources。
# shared/ 是源文件目录；改完布局或版本后跑一次本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh

STUDIO_RES="apps/toccata-studio/Resources"

mkdir -p "$STUDIO_RES/Layout"
cp shared/layout/*.json "$STUDIO_RES/Layout/"
cp shared/app-version.json "$STUDIO_RES/app-version.json"

echo "synced: keyboard layout and app version -> studio Resources"
