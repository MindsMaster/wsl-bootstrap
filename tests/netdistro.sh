#!/usr/bin/env bash
# 网络发行版产物冒烟测试 解包 rootfs 后在 unshare 隔离的网络命名空间里 chroot 运行
# 用产物里真实的 nft 与 sing-box 不碰宿主网络
#   tests/netdistro.sh [dist/wslb-net.tar.gz]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ ${1:-} != --inner ]]; then
  TARBALL=$(realpath "${1:-$HERE/../dist/wslb-net.tar.gz}")
  [[ -f $TARBALL ]] || { echo "找不到 $TARBALL 先运行 tools/build-netdistro.sh" >&2; exit 1; }
  export WSLB_TEST_HOST_NS WSLB_TEST_TARBALL=$TARBALL
  WSLB_TEST_HOST_NS=$(readlink /proc/self/ns/net)
  exec unshare -rmn bash "$0" --inner
fi

if [[ $(readlink /proc/self/ns/net) == "$WSLB_TEST_HOST_NS" ]]; then
  echo "仍在宿主网络命名空间 中止" >&2
  exit 99
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
in_root() { chroot "$ROOT" "$@"; }
cleanup() {
  in_root /usr/local/bin/wslb-agent disable --yes >/dev/null 2>&1 || true
  umount -l "$ROOT/proc" "$ROOT/dev" "$ROOT/sys" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$ROOT"
tar --no-same-owner -xzf "$WSLB_TEST_TARBALL" -C "$ROOT"
for d in proc dev sys; do
  mkdir -p "$ROOT/$d"
  mount --rbind "/$d" "$ROOT/$d"
done
mkdir -p "$ROOT/run"

ip link set lo up
ip link add lan0 type dummy
ip link set lan0 up
ip addr add 192.168.50.10/24 dev lan0
ip route add default via 192.168.50.1 dev lan0 metric 100

echo "产物内容"
check "wslb-agent 可运行" in_root /usr/local/bin/wslb-agent version
check "nft 可运行" in_root /usr/sbin/nft --version
check "sing-box 可运行" in_root /usr/local/lib/wslb/sing-box version
check "wsl.conf 开机命令" grep -q 'command = /usr/local/bin/wslb-agent start' "$ROOT/etc/wsl.conf"

echo "节点与配置"
link='vless://00000000-0000-4000-8000-000000000000@node.example.com:443?security=tls&sni=node.example.com&type=ws&path=%2Fws#test'
check "set-node 用 --ip 固定地址" in_root /usr/local/bin/wslb-agent set-node "$link" --ip 203.0.113.7
in_root /usr/local/bin/wslb-agent config set lan-cidr 192.168.50.0/24 >/dev/null
in_root /usr/local/bin/wslb-agent config set lan-gateway 192.168.50.1 >/dev/null
in_root /usr/local/bin/wslb-agent config set health-interval 0 >/dev/null
in_root /usr/local/bin/wslb-agent singbox-config >"$ROOT/tmp/sb.json"
check "生成的配置通过随包 sing-box 校验" in_root /usr/local/lib/wslb/sing-box check -c /tmp/sb.json

echo "开机命令拉起守护进程 真实 sing-box"
in_root /usr/local/bin/wslb-agent start
state() { in_root /usr/local/bin/wslb-agent status --json 2>/dev/null || true; }
wait_for() {
  local n=$1
  shift
  for _ in $(seq 1 "$n"); do
    "$@" && return 0
    sleep 0.2
  done
  return 1
}
guard_up() { [[ $(state) == *'"guard": true'* ]]; }
tun_up() { ip link show wslb0 >/dev/null 2>&1; }
check "守护进程可达" wait_for 25 guard_up
check "sing-box 建立了 wslb0" wait_for 50 tun_up
check "完整防火墙规则" bash -c "chroot '$ROOT' /usr/sbin/nft list table inet wslb | grep -q 'comment \"wslb guard\"'"
check "sing-box 设了策略路由" bash -c "ip rule | grep -q 'lookup'"
pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$ROOT/run/wslb/state.json")
sleep 5
check "sing-box 5 秒后仍是同一进程" test "$pid" == "$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$ROOT/run/wslb/state.json")"
check "默认路由只剩黑洞" bash -c "[[ \$(ip -4 route show default) == 'default dev wslb-null '* ]]"

echo "节点不通时经真实 sing-box 的健康探测"
in_root /usr/local/bin/wslb-agent config set health-interval 2 >/dev/null
in_root /usr/local/bin/wslb-agent config set health-timeout 2 >/dev/null
in_root /usr/local/bin/wslb-agent config set health-failures 2 >/dev/null
health_restarted() { [[ $(state) =~ \"health_restarts\":\ ([1-9]) ]]; }
check "sing-box 没有替节点作答 探测失败后重启" wait_for 100 health_restarted
in_root /usr/local/bin/wslb-agent config set health-interval 0 >/dev/null

echo "暂停 sing-box 时直连被拒"
if in_root /usr/local/bin/wslb-agent leaktest >"$WORK/leak.txt"; then ok "leaktest 无泄露"; else bad "leaktest 报告泄露"; fi
sed 's/^/      /' "$WORK/leak.txt"

echo
if (( FAIL > 0 )); then
  sed 's/^/    /' "$ROOT/var/log/wslb/guard.log" 2>/dev/null || true
fi
echo "通过 $PASS  失败 $FAIL"
(( FAIL == 0 ))
