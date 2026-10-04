# shellcheck shell=bash
# Alpine minirootfs 加 nftables 网络发行版和集成测试共用
#   alpine_root <目录> <下载缓存目录>   目录里没有 nft 时下载 校验 解包 装 nftables

ALPINE_VERSION=3.24.2
ALPINE_BRANCH=v3.24
ALPINE_SHA256=c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677
ALPINE_PACKAGES=(nftables)

alpine_root() {
  local root=$1 cache=$2 tarball
  [[ -x $root/usr/sbin/nft ]] && return 0
  tarball=$cache/alpine-minirootfs-$ALPINE_VERSION-x86_64.tar.gz
  if [[ ! -f $tarball ]]; then
    mkdir -p "$cache"
    curl -fsSL --retry 3 -o "$tarball.part" \
      "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/x86_64/alpine-minirootfs-$ALPINE_VERSION-x86_64.tar.gz"
    echo "$ALPINE_SHA256  $tarball.part" | sha256sum -c --quiet -
    mv "$tarball.part" "$tarball"
  fi
  rm -rf "$root"
  mkdir -p "$root"
  # 用户命名空间里只映射了 root 保留属主会失败 打包时统一成 root
  unshare -rm sh -c '
    set -e
    tar --no-same-owner -xzf "$1" -C "$2"
    cp /etc/resolv.conf "$2/etc/resolv.conf"
    shift 2
    chroot "$0" /sbin/apk add --no-cache --quiet "$@"
  ' "$root" "$tarball" "$root" "${ALPINE_PACKAGES[@]}"
}

# 在宿主上直接运行 rootfs 里的 nft 经它自带的 musl 加载器
alpine_nft_wrapper() {
  local root=$1 out=$2
  cat >"$out" <<WRAP
#!/bin/sh
exec "$root/lib/ld-musl-x86_64.so.1" --library-path "$root/lib:$root/usr/lib" "$root/usr/sbin/nft" "\$@"
WRAP
  chmod +x "$out"
}
