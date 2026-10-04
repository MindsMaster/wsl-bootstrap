#!/usr/bin/env bash
# 用户发行版安装流程测试 把官方 WSL 镜像解包到临时目录 chroot 进去运行 provision
# 需要 uidmap 提供 newuidmap dpkg 改属主到非 root 用户时才不会失败
# apt 走宿主网络 运行前宿主网络必须已受保护 provision 自己也会检查
#   tests/provision.sh <ubuntu|debian> [wslb-agent]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/wslb-test

declare -A IMAGE_URL=(
  [ubuntu]=https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-wsl-amd64.wsl
  [debian]=https://salsa.debian.org/debian/WSL/-/jobs/9606244/artifacts/raw/Debian_WSL_AMD64_v1.26.0.0.wsl
)
declare -A IMAGE_SHA256=(
  [ubuntu]=48d56724b5c8e60f24893e83e73bbb58c60b3ca22fba3da977075420acd54104
  [debian]=5ec7dc68216e75d1d4d4761474e99d8461a98d316537110314b137122a879e0f
)

if [[ ${1:-} != --inner ]]; then
  DISTRO=${1:?用法 tests/provision.sh <ubuntu|debian> [wslb-agent]}
  [[ -n ${IMAGE_URL[$DISTRO]:-} ]] || { echo "未知发行版 $DISTRO" >&2; exit 2; }
  BIN=$(realpath "${2:-$HERE/../zig-out/bin/wslb-agent}")
  command -v newuidmap >/dev/null || { echo "缺少 newuidmap 先 sudo apt install uidmap" >&2; exit 1; }
  image=$CACHE/$DISTRO.wsl
  if [[ ! -f $image ]]; then
    mkdir -p "$CACHE"
    curl -fsSL --retry 3 -o "$image.part" "${IMAGE_URL[$DISTRO]}"
    echo "${IMAGE_SHA256[$DISTRO]}  $image.part" | sha256sum -c --quiet -
    mv "$image.part" "$image"
  fi
  export WSLB_TEST_BIN=$BIN WSLB_TEST_IMAGE=$image WSLB_TEST_DISTRO=$DISTRO
  # 完整 uid 映射 但不新建网络命名空间 apt 要联网
  exec unshare --map-auto --map-root-user --mount bash "$0" --inner
fi

WORK=$(mktemp -d)
ROOT=$WORK/root
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \e[32m✔\e[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \e[31m✘\e[0m %s\n' "$*"; }
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
cleanup() {
  umount -l "$ROOT/proc" "$ROOT/dev" "$ROOT/sys" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
in_root() { chroot "$ROOT" "$@"; }

mkdir -p "$ROOT"
# 设备节点在用户命名空间里建不了 /dev 随后整个绑定挂载
tar -xzf "$WSLB_TEST_IMAGE" -C "$ROOT" --exclude="./dev/*" --exclude="dev/*"
for d in proc dev sys; do
  mount --rbind "/$d" "$ROOT/$d"
done
# 解包后的 resolv.conf 指向不存在的 systemd-resolved 先借宿主的
rm -f "$ROOT/etc/resolv.conf"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
install -m 0755 "$WSLB_TEST_BIN" "$ROOT/usr/local/bin/wslb-agent"

echo "provision $WSLB_TEST_DISTRO"
if printf 'test-password\n' | in_root /usr/local/bin/wslb-agent provision --user alice --password-stdin \
  --timezone America/Los_Angeles --locale ja_JP.UTF-8 --firefox --gpu NVIDIA --hide-claude >"$WORK/log.txt" 2>&1; then
  ok "provision 成功"
else
  bad "provision 失败"
  tail -40 "$WORK/log.txt" | sed 's/^/    /'
fi
grep '^==>' "$WORK/log.txt" | sed 's/^/    /'

echo "结果"
check "uid 1000 是 alice" bash -c "grep -q '^alice:x:1000:' '$ROOT/etc/passwd'"
check "alice 在 sudo 组" bash -c "grep -q '^sudo:.*alice' '$ROOT/etc/group'"
check "wsl.conf 开 systemd 默认 alice" bash -c "grep -q 'systemd=true' '$ROOT/etc/wsl.conf' && grep -q 'default=alice' '$ROOT/etc/wsl.conf'"
check "wsl.conf 不再生成 resolv.conf" grep -q 'generateResolvConf=false' "$ROOT/etc/wsl.conf"
check "wsl.conf 时区不跟 Windows" grep -q 'useWindowsTimezone=false' "$ROOT/etc/wsl.conf"
check "nftables 已安装" test -x "$ROOT/usr/sbin/nft"
check "chrony 已安装" test -x "$ROOT/usr/sbin/chronyd"
check "开机兜底服务已启用" test -L "$ROOT/etc/systemd/system/sysinit.target.wants/wslb-boot.service"
check "网络发行版连接服务已启用" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/wslb-link.service"
check "时区 America/Los_Angeles" bash -c "[[ \$(readlink '$ROOT/etc/localtime') == */America/Los_Angeles ]]"
check "locale ja_JP 已生成" bash -c "chroot '$ROOT' locale -a | grep -qi '^ja_JP.utf8'"
check "NTS 对时源" test -f "$ROOT/etc/chrony/sources.d/wslb-agent.sources"
check "Firefox 来自 Mozilla" bash -c "[[ \$(readlink -f '$ROOT/usr/bin/firefox') == */usr/lib/firefox/* ]]"
check "Firefox 日语包" bash -c "chroot '$ROOT' dpkg -l | grep -q 'firefox-l10n-ja'"
check "Firefox 语言偏好 ja-JP" grep -q '"intl.locale.requested", "ja-JP"' "$ROOT/usr/lib/firefox/defaults/pref/wslb-identity.js"
check "GPU 选 NVIDIA" grep -q 'MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA' "$ROOT/etc/profile.d/wslg-gpu.sh"
check "firefox 命令走启动器" grep -q 'wsl-firefox' "$ROOT/home/alice/.bash_aliases"
check "隐藏 Claude 服务已启用" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/hide-windows-claude.service"

echo "重复运行"
if printf '\n' | in_root /usr/local/bin/wslb-agent provision --user alice --timezone America/Los_Angeles --locale ja_JP.UTF-8 --no-upgrade >"$WORK/log2.txt" 2>&1; then
  ok "第二次 provision 成功 沿用已有用户"
else
  bad "第二次 provision 失败"
  tail -20 "$WORK/log2.txt" | sed 's/^/    /'
fi
check "bash_aliases 里只有一段 firefox 块" test "$(grep -c '>>> wslb firefox >>>' "$ROOT/home/alice/.bash_aliases")" == 1

echo
echo "通过 $PASS  失败 $FAIL"
(( FAIL == 0 ))
