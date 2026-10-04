#!/usr/bin/env bash
# 组装网络发行版 wslb-net 的 rootfs
#   tools/build-netdistro.sh <wslb-agent> <输出目录>
# 产物 wslb-net.tar.gz 供 wsl --import  wslb-net.lock 记录包版本
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=alpine.sh
. "$HERE/alpine.sh"

SINGBOX_VERSION=1.14.2
# 官方 -musl 包是静态链接 默认包依赖 glibc 在 Alpine 里跑不起来
SINGBOX_SHA256=8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297

AGENT=$(realpath "${1:?用法 build-netdistro.sh <wslb-agent> <输出目录>}")
OUT=$(realpath -m "${2:?缺少输出目录}")
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/wslb-build
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$CACHE" "$OUT"
asset=sing-box-$SINGBOX_VERSION-linux-amd64-musl.tar.gz
if [[ ! -f $CACHE/$asset ]]; then
  curl -fsSL --retry 3 -o "$CACHE/$asset.part" \
    "https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/$asset"
  mv "$CACHE/$asset.part" "$CACHE/$asset"
fi
echo "$SINGBOX_SHA256  $CACHE/$asset" | sha256sum -c --quiet -
tar -xzf "$CACHE/$asset" -C "$WORK"

# 每次从干净的 minirootfs 开始 不复用测试缓存
root=$WORK/root
alpine_root "$root" "$CACHE"

install -D -m 0755 "$AGENT" "$root/usr/local/bin/wslb-agent"
install -D -m 0755 "$WORK/sing-box-$SINGBOX_VERSION-linux-amd64-musl/sing-box" "$root/usr/local/lib/wslb/sing-box"
mkdir -p "$root/etc/wslb"

# 解析都走 sing-box 的 DNS 劫持 这里的地址只是让查询进隧道
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0 timeout:2 attempts:2\n' >"$root/etc/resolv.conf"
cat >"$root/etc/wsl.conf" <<'CONF'
# wslb-net 只运行出口守护进程
[boot]
command = /usr/local/bin/wslb-agent start

[automount]
enabled = false
mountFsTab = false

[interop]
enabled = false
appendWindowsPath = false

[network]
generateResolvConf = false
generateHosts = false
hostname = wslb-net

[user]
default = root

[time]
useWindowsTimezone = false
CONF

{
  echo "alpine $ALPINE_VERSION"
  echo "sing-box $SINGBOX_VERSION $SINGBOX_SHA256"
  echo "wslb-agent $("$AGENT" version | awk '{print $2}') $(sha256sum "$AGENT" | awk '{print $1}')"
  unshare -rm chroot "$root" /sbin/apk info -v 2>/dev/null | sort
} >"$OUT/wslb-net.lock"

# 用户命名空间里文件属主显示为 0 打包时按数字写入
unshare -rm tar --numeric-owner --owner=0 --group=0 -czf "$OUT/wslb-net.tar.gz" -C "$root" .
ls -la "$OUT/wslb-net.tar.gz"
