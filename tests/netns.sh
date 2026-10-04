#!/usr/bin/env bash
# kill-switch 集成测试 在 unshare -rn 隔离的网络命名空间里运行 不碰宿主网络
#   tests/netns.sh [path/to/wslb-agent]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/wslb-agent-test

nft_sysroot() {
  if [[ -e /usr/lib/x86_64-linux-gnu/libnftables.so.1 ]] && command -v nft >/dev/null; then
    echo ""
    return
  fi
  local root=$CACHE/sysroot
  if [[ ! -e $root/usr/sbin/nft ]]; then
    mkdir -p "$CACHE/debs" "$root"
    (cd "$CACHE/debs" && apt-get download libnftables1 libnftnl11 libmnl0 libjansson4 nftables >/dev/null)
    for d in "$CACHE"/debs/*.deb; do
      dpkg -x "$d" "$root"
    done
  fi
  echo "$root"
}

if [[ ${1:-} != --inner ]]; then
  BIN=$(realpath "${1:-$HERE/../zig-out/bin/wslb-agent}")
  [[ -x $BIN ]] || { echo "找不到 $BIN 先 zig build" >&2; exit 1; }
  root=$(nft_sysroot)
  export WSLB_TEST_BIN=$BIN
  export WSLB_TEST_HOST_NS
  WSLB_TEST_HOST_NS=$(readlink /proc/self/ns/net)
  if [[ -n $root ]]; then
    export LD_LIBRARY_PATH=$root/usr/lib/x86_64-linux-gnu
    export WSLB_LIBNFT=$root/usr/lib/x86_64-linux-gnu/libnftables.so.1
    export WSLB_TEST_NFT=$root/usr/sbin/nft
  else
    export WSLB_TEST_NFT=nft
  fi
  exec unshare -rn bash "$0" --inner
fi

# 进到这里必须已在新的网络命名空间
if [[ $(readlink /proc/self/ns/net) == "$WSLB_TEST_HOST_NS" ]]; then
  echo "仍在宿主网络命名空间 中止" >&2
  exit 99
fi
for legacy in seattle0 seattle-null wslb0 wslb-null; do
  if ip link show "$legacy" >/dev/null 2>&1; then
    echo "命名空间里出现 $legacy 中止" >&2
    exit 99
  fi
done

BIN=$WSLB_TEST_BIN
NFT=$WSLB_TEST_NFT
WORK=$(mktemp -d)
export WSLB_ETC=$WORK/etc WSLB_RUN=$WORK/run WSLB_NO_SYSTEMD=1
mkdir -p "$WSLB_ETC" "$WSLB_RUN"
NODE=203.0.113.7
PASS=0
FAIL=0
DAEMON=0

cleanup() {
  [[ $DAEMON != 0 ]] && kill "$DAEMON" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); printf '  \e[32m✔\e[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \e[31m✘\e[0m %s\n' "$*"; }
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# 毫秒级轮询 结果写入 ELAPSED
# uutils date 的 %3N 输出纳秒 改用 bash 内置时钟
now_ms() { local t=${EPOCHREALTIME/./}; echo $(( t / 1000 )); }
wait_for() {
  local limit_ms=$1 t0
  shift
  t0=$(now_ms)
  while ! "$@"; do
    if (( $(now_ms) - t0 > limit_ms )); then
      return 1
    fi
    sleep 0.01
  done
  ELAPSED=$(( $(now_ms) - t0 ))
}

only_blackhole_default() { [[ $(ip -4 route show default) == "default dev wslb-null "* && $(ip -4 route show default | wc -l) == 1 ]]; }
node_via() { ip -4 route show "$NODE/32" | grep -q "via $1 dev $2"; }
table_present() { "$NFT" list table inet wslb >/dev/null 2>&1; }
singbox_pid() { sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$WSLB_RUN/state.json" 2>/dev/null; }
singbox_running() { local p; p=$(singbox_pid); [[ -n $p && $p != 0 ]] && kill -0 "$p" 2>/dev/null; }
pid_changed() { local p; p=$(singbox_pid); [[ -n $p && $p != 0 && $p != "$1" ]]; }

ip link set lo up
ip link add lan0 type dummy
ip link set lan0 up
ip addr add 192.168.50.10/24 dev lan0
ip route add default via 192.168.50.1 dev lan0 metric 100

cat >"$WORK/fake-singbox" <<'EOF'
#!/usr/bin/env bash
exec sleep 3600
EOF
chmod +x "$WORK/fake-singbox"
cat >"$WSLB_ETC/config.json" <<EOF
{ "lan_cidr": "192.168.50.0/24", "lan_gateway": "192.168.50.1", "singbox": "$WORK/fake-singbox",
  "identity": { "timezone_mode": "windows", "locale": "" } }
EOF
cat >"$WSLB_ETC/node.json" <<EOF
{ "name": "test", "host": "$NODE", "ip": "$NODE", "port": 443, "uuid": "u-1", "security": "tls", "fingerprint": "chrome" }
EOF

echo "firewall-up 缺 libnftables 首次安装时的状态"
if WSLB_LIBNFT=/nonexistent "$BIN" firewall-up 2>/dev/null; then ok "缺库时 firewall-up 仍成功退出"; else bad "缺库时 firewall-up 失败"; fi
check "缺库时黑洞已建立 外来默认路由已清除" only_blackhole_default
check "缺库时节点路由已固定" node_via 192.168.50.1 lan0
check "缺库时防火墙表不存在" bash -c "! $NFT list table inet wslb >/dev/null 2>&1"
ip route add default via 192.168.50.1 dev lan0 metric 100

echo "firewall-up 开机早期"
"$BIN" firewall-up
check "黑洞默认路由 外来默认路由已清除" only_blackhole_default
check "节点路由经 lan0" node_via 192.168.50.1 lan0
check "防火墙表已加载" table_present

echo "daemon"
"$BIN" daemon 2>"$WORK/daemon.log" &
DAEMON=$!
check "sing-box 被拉起" wait_for 3000 singbox_running

echo "注入外来默认路由"
ip route add default via 192.168.50.1 dev lan0 metric 50
if wait_for 500 only_blackhole_default; then ok "注入的默认路由 ${ELAPSED}ms 内被清除"; else bad "注入的默认路由未被清除"; fi

echo "直连探测"
if "$BIN" leaktest >"$WORK/leak.txt"; then ok "leaktest 无泄露"; else bad "leaktest 报告泄露"; fi
check "TCP 被防火墙拒绝" grep -q "TCP 1.1.1.1:443 被防火墙拒绝" "$WORK/leak.txt"
check "UDP 被防火墙拒绝" grep -q "UDP 8.8.8.8:53 被防火墙拒绝" "$WORK/leak.txt"
sed 's/^/      /' "$WORK/leak.txt"

echo "换网"
old=$(singbox_pid)
ip link add lan1 type dummy
ip link set lan1 up
ip addr add 10.77.0.5/24 dev lan1
ip route add default via 10.77.0.1 dev lan1 metric 10
if wait_for 1000 node_via 10.77.0.1 lan1; then ok "节点路由 ${ELAPSED}ms 内切到 lan1"; else bad "节点路由未切到 lan1"; fi
check "sing-box 随上行重启" wait_for 3000 pid_changed "$old"
check "lan1 默认路由被清除" wait_for 500 only_blackhole_default
sleep 3
check "3 秒后仍经 lan1 不回跳" node_via 10.77.0.1 lan1

echo "防火墙被删"
"$NFT" delete table inet wslb
if wait_for 3000 table_present; then ok "防火墙表 ${ELAPSED}ms 内恢复"; else bad "防火墙表未恢复"; fi

echo "sing-box 崩溃"
old=$(singbox_pid)
kill -9 "$old"
check "sing-box 自动重启" wait_for 4000 pid_changed "$old"

echo "黑洞网卡被删"
ip link del wslb-null
if wait_for 1000 only_blackhole_default; then ok "黑洞 ${ELAPSED}ms 内重建"; else bad "黑洞未重建"; fi

echo "守护进程退出"
kill -TERM "$DAEMON"
wait "$DAEMON" || true
DAEMON=0
check "退出后防火墙保留" table_present
check "退出后黑洞保留" only_blackhole_default
if "$BIN" leaktest >"$WORK/leak2.txt"; then ok "退出后仍无泄露"; else bad "退出后出现泄露"; fi

echo
if (( FAIL > 0 )); then
  echo "守护进程日志:"
  sed 's/^/    /' "$WORK/daemon.log"
fi
echo "通过 $PASS  失败 $FAIL"
(( FAIL == 0 ))
