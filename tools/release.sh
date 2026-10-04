#!/usr/bin/env bash
# 一次产出可分发的 wslb.exe 先打网络发行版 再把它和 agent 一起编进管理器
#   tools/release.sh [版本号]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${1:-0.2.0}
export ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR:-$HOME/.cache/zig-local/wslb}

cd "$HERE"
zig build -Drelease=true -Dversion="$VERSION" -p zig-out/release
bash tools/build-netdistro.sh zig-out/release/bin/wslb-agent dist
zig build -Drelease=true -Dversion="$VERSION" -Dnetdistro=dist/wslb-net.tar.gz -p zig-out/release
cp zig-out/release/bin/wslb.exe "dist/wslb-$VERSION.exe"
sha256sum "dist/wslb-$VERSION.exe" | tee "dist/wslb-$VERSION.exe.sha256"
