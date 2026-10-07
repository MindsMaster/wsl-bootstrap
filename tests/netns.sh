#!/usr/bin/env bash
# 网络防护集成测试 在 unshare -rn 隔离的网络命名空间里运行 不碰宿主网络
#   tests/netns.sh [path/to/wslb-agent]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/wslb-test
# shellcheck source=../tools/alpine.sh
. "$HERE/../tools/alpine.sh"

if [[ ${1:-} != --inner ]]; then
  BIN=$(realpath "${1:-$HERE/../zig-out/bin/wslb-agent}")
  [[ -x $BIN ]] || { echo "找不到 $BIN 先 zig build" >&2; exit 1; }
  alpine_root "$CACHE/alpine-$ALPINE_VERSION" "$CACHE"
  alpine_nft_wrapper "$CACHE/alpine-$ALPINE_VERSION" "$CACHE/nft"
  export WSLB_TEST_BIN=$BIN WSLB_NFT=$CACHE/nft
  export WSLB_TEST_HOST_NS
  WSLB_TEST_HOST_NS=$(readlink /proc/self/ns/net)
  exec unshare -rn bash "$0" --inner
fi

# 进到这里必须已在新的网络命名空间
if [[ $(readlink /proc/self/ns/net) == "$WSLB_TEST_HOST_NS" ]]; then
  echo "仍在宿主网络命名空间 中止" >&2
  exit 99
fi
for name in seattle0 seattle-null wslb0 wslb-null; do
  if ip link show "$name" >/dev/null 2>&1; then
    echo "命名空间里出现 $name 中止" >&2
    exit 99
  fi
done

BIN=$WSLB_TEST_BIN
NFT=$WSLB_NFT
WORK=$(mktemp -d)
export WSLB_ETC=$WORK/etc WSLB_RUN=$WORK/run WSLB_LOG=$WORK/log
mkdir -p "$WSLB_ETC" "$WSLB_RUN"
NODE=203.0.113.7
PASS=0
FAIL=0
DAEMON=0

cleanup() {
  "$BIN" disable --yes >/dev/null 2>&1 || true
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
# 先取完整输出 grep -q 提前退出会让 nft 收到 SIGPIPE 被 pipefail 判失败
table_owner() { local t; t=$("$NFT" list table inet wslb 2>/dev/null) && [[ $t == *"comment \"wslb $1\""* ]]; }
no_table() { ! "$NFT" list table inet wslb >/dev/null 2>&1; }
singbox_pid() { sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$WSLB_RUN/state.json" 2>/dev/null; }
singbox_running() { local p; p=$(singbox_pid); [[ -n $p && $p != 0 ]] && kill -0 "$p" 2>/dev/null; }
pid_changed() { local p; p=$(singbox_pid); [[ -n $p && $p != 0 && $p != "$1" ]]; }
guard_alive() { local s; s=$("$BIN" status --json 2>/dev/null) || true; [[ $s == *'"guard": true'* ]]; }
guard_gone() { ! guard_alive; }
state_field() { "$BIN" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
routes_snapshot() { ip -4 route show table main; ip -br link | awk '{print $1}' | sort; }

ip link set lo up
ip link add lan0 type dummy
ip link set lan0 up
ip addr add 192.168.50.10/24 dev lan0
ip route add default via 192.168.50.1 dev lan0 metric 100

cat >"$WORK/fake-singbox" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" check "* ]]; then
  exit 0
fi
exec sleep 3600
EOF
chmod +x "$WORK/fake-singbox"
cat >"$WSLB_ETC/net.json" <<EOF
{ "lan_cidr": "192.168.50.0/24", "lan_gateway": "192.168.50.1", "singbox": "$WORK/fake-singbox",
  "health": { "interval_s": 0 } }
EOF
cat >"$WSLB_ETC/node.json" <<EOF
{ "name": "test", "host": "$NODE", "ip": "$NODE", "port": 443, "uuid": "u-1", "security": "tls", "fingerprint": "chrome" }
EOF

echo "另一套 kill-switch 在场"
ip link add seattle-null type dummy
ip link set seattle-null up
ip link add seattle0 type dummy
ip route replace default dev seattle-null
before=$(routes_snapshot)
if "$BIN" firewall-up 2>/dev/null; then bad "firewall-up 没有拒绝"; else ok "firewall-up 拒绝改动"; fi
if "$BIN" guard 2>/dev/null; then bad "守护进程没有拒绝启动"; else ok "守护进程拒绝启动"; fi
check "开机兜底识别出外部 kill-switch" bash -c "\"$BIN\" boot | grep -q seattle"
check "路由与网卡没有任何变化" test "$before" == "$(routes_snapshot)"
check "没有建立防火墙表" no_table
ip link del seattle0
ip link del seattle-null
ip route replace default via 192.168.50.1 dev lan0 metric 100

echo "用户发行版开机兜底 守护进程未运行"
"$BIN" boot >/dev/null
check "黑洞默认路由 外来默认路由已清除" only_blackhole_default
check "兜底防火墙表已建立" table_owner boot
check "兜底层不设节点路由" bash -c "! ip -4 route show $NODE/32 | grep -q via"
check "关闭 IPv6 与 TCP 时间戳" bash -c "[[ \$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 1 && \$(cat /proc/sys/net/ipv4/tcp_timestamps) == 0 ]]"
"$BIN" boot >/dev/null
check "重复执行不改动已有的表" table_owner boot

echo "守护进程接管"
"$BIN" guard 2>"$WORK/daemon.log" &
DAEMON=$!
check "sing-box 被拉起" wait_for 3000 singbox_running
if wait_for 2000 table_owner guard; then ok "兜底表 ${ELAPSED}ms 内换成完整规则"; else bad "兜底表没有被接管"; fi
check "节点路由经 lan0" node_via 192.168.50.1 lan0
check "其他发行版经控制套接字看到守护进程" guard_alive

echo "单实例"
if timeout 2 "$BIN" guard 2>/dev/null; then ok "第二个守护进程立即退出"; else bad "第二个守护进程没有退出"; fi
check "第一个守护进程仍在运行" kill -0 "$DAEMON"
"$BIN" boot >/dev/null
check "守护进程在时开机兜底不改动规则" table_owner guard
check "守护进程在时节点路由保留" node_via 192.168.50.1 lan0

echo "注入外来默认路由"
ip route add default via 192.168.50.1 dev lan0 metric 50
if wait_for 500 only_blackhole_default; then ok "注入的默认路由 ${ELAPSED}ms 内被清除"; else bad "注入的默认路由未被清除"; fi

echo "直连探测"
if "$BIN" leaktest >"$WORK/leak.txt"; then ok "leaktest 无泄露"; else bad "leaktest 报告泄露"; fi
check "leaktest 经控制套接字暂停了 sing-box" grep -q "已暂停 sing-box" "$WORK/leak.txt"
check "TCP 被防火墙拒绝" grep -q "TCP 1.1.1.1:443 被防火墙拒绝" "$WORK/leak.txt"
check "UDP 被防火墙拒绝" grep -q "UDP 8.8.8.8:53 被防火墙拒绝" "$WORK/leak.txt"
check "leaktest 后 sing-box 恢复" wait_for 3000 singbox_running
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

echo "换节点 默认路由已删光 不配 LAN 网段"
python3 - "$WSLB_ETC/net.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["lan_cidr"] = ""
c["lan_gateway"] = ""
json.dump(c, open(sys.argv[1], "w"))
PY
NODE2=198.51.100.7
"$BIN" node add 'vless://22222222-0000-4000-8000-000000000000@node2.example.com:443?security=tls#n2' --ip "$NODE2" --use >/dev/null
check "新节点路由沿用 lan1" wait_for 2000 bash -c "ip -4 route show $NODE2/32 | grep -q 'via 10.77.0.1 dev lan1'"
check "换节点后 sing-box 在运行" wait_for 3000 singbox_running
check "状态里的上行网卡是 lan1" test "$(state_field uplink)" == lan1
"$BIN" set-node "vless://u-1@$NODE:443?security=tls&fp=chrome#test" --ip "$NODE" >/dev/null
check "换回原节点后 sing-box 在运行" wait_for 3000 singbox_running

echo "上行网卡断开再恢复 WSL 不一定补回默认路由"
ip link set lan1 down
check "断开后只剩黑洞默认路由" wait_for 1000 only_blackhole_default
check "断开时防火墙完整规则仍在" table_owner guard
ip link set lan1 up
if wait_for 3000 node_via 10.77.0.1 lan1; then ok "恢复后 ${ELAPSED}ms 内节点路由回到 lan1"; else bad "恢复后节点路由没有回来"; fi
check "恢复后 sing-box 在运行" wait_for 3000 singbox_running

echo "上行网卡被删除后重建"
ip link del lan1
check "删除后只剩黑洞默认路由" wait_for 1000 only_blackhole_default
check "删除时防火墙完整规则仍在" table_owner guard
ip link add lan1 type dummy
ip link set lan1 up
ip addr add 10.77.0.5/24 dev lan1
ip route add default via 10.77.0.1 dev lan1 metric 10
if wait_for 3000 node_via 10.77.0.1 lan1; then ok "重建后 ${ELAPSED}ms 内节点路由回到 lan1"; else bad "重建后节点路由没有回来"; fi
check "重建时带来的默认路由被清除" wait_for 1000 only_blackhole_default
check "重建后 sing-box 在运行" wait_for 3000 singbox_running
"$BIN" config set lan-cidr 192.168.50.0/24 >/dev/null
"$BIN" config set lan-gateway 192.168.50.1 >/dev/null

echo "防火墙被删或被换"
"$NFT" delete table inet wslb
if wait_for 2000 table_owner guard; then ok "被删的防火墙表 ${ELAPSED}ms 内恢复"; else bad "防火墙表未恢复"; fi
printf 'delete table inet wslb\ncreate table inet wslb { comment "wslb boot"\n}\n' | "$NFT" -f -
if wait_for 2000 table_owner guard; then ok "被换成兜底规则后 ${ELAPSED}ms 内恢复"; else bad "兜底规则没有被换回"; fi

echo "sing-box 崩溃"
old=$(singbox_pid)
kill -9 "$old"
check "sing-box 自动重启" wait_for 4000 pid_changed "$old"

echo "黑洞网卡被删"
ip link del wslb-null
if wait_for 1000 only_blackhole_default; then ok "黑洞 ${ELAPSED}ms 内重建"; else bad "黑洞未重建"; fi

echo "隧道健康探测"
old=$(singbox_pid)
"$BIN" config set health-interval 1 >/dev/null
"$BIN" config set health-timeout 1 >/dev/null
"$BIN" config set health-failures 2 >/dev/null
sleep 1
old=$(singbox_pid)
if wait_for 12000 pid_changed "$old"; then ok "探测连续失败 ${ELAPSED}ms 后重启 sing-box"; else bad "探测失败没有触发重启"; fi
check "状态里记录了健康重启" bash -c "\"$BIN\" status --json | grep -q '\"health_restarts\": [1-9]'"

echo "隧道健康探测 经本地 DNS 应答"
cat >"$WORK/dns.py" <<'EOF'
import socket, sys
mode_file = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 53))
while True:
    data, addr = s.recvfrom(512)
    mode = open(mode_file).read().strip()
    if mode == "silent":
        continue
    rcode = 3 if mode == "nxdomain" else 2
    s.sendto(data[:2] + bytes([0x81, 0x80 | rcode]) + data[4:6] + bytes(6) + data[12:], addr)
EOF
echo nxdomain >"$WORK/dns-mode"
python3 "$WORK/dns.py" "$WORK/dns-mode" &
DNS_PID=$!
"$BIN" config set remote-dns 192.168.50.10 >/dev/null
sleep 5
restarts=$(state_field health_restarts)
check "NXDOMAIN 应答算作隧道正常" test "$(state_field health_failures)" == 0
check "记录了最近一次探测通过" test "$(state_field health_ok_age_s)" -ge 0
sleep 4
check "应答正常时不重启 sing-box" test "$(state_field health_restarts)" == "$restarts"
old=$(singbox_pid)
echo servfail >"$WORK/dns-mode"
if wait_for 12000 pid_changed "$old"; then ok "SERVFAIL ${ELAPSED}ms 后重启 sing-box"; else bad "SERVFAIL 没有触发重启"; fi
echo nxdomain >"$WORK/dns-mode"
sleep 4
old=$(singbox_pid)
echo silent >"$WORK/dns-mode"
if wait_for 15000 pid_changed "$old"; then ok "无应答 ${ELAPSED}ms 后重启 sing-box"; else bad "超时没有触发重启"; fi
kill "$DNS_PID"
"$BIN" config set health-interval 0 >/dev/null
"$BIN" config set remote-dns 8.8.8.8 >/dev/null

echo "守护进程退出"
kill -TERM "$DAEMON"
wait "$DAEMON" || true
DAEMON=0
check "退出后防火墙保留" table_owner guard
check "退出后黑洞保留" only_blackhole_default
if "$BIN" leaktest >"$WORK/leak2.txt"; then ok "退出后仍无泄露"; else bad "退出后出现泄露"; fi

echo "脱离会话拉起 停用 启用"
"$BIN" start
check "start 拉起的守护进程可达" wait_for 3000 guard_alive
"$BIN" disable --yes >/dev/null 2>&1
check "disable 后守护进程退出" wait_for 3000 guard_gone
check "disable 后防火墙表移除" no_table
check "disable 后黑洞默认路由移除" bash -c "! ip -4 route show default | grep -q wslb-null"
"$BIN" start >/dev/null
sleep 1
check "停用状态下 start 不拉起" guard_gone
"$BIN" enable >/dev/null
check "enable 后守护进程恢复" wait_for 3000 guard_alive
check "enable 后防火墙恢复" wait_for 3000 table_owner guard

echo "另一套 kill-switch 后启动 守护进程让出"
seattle_up() {
  ip link add seattle-null type dummy
  ip link set seattle-null up
  ip link add seattle0 type dummy
  ip route replace default dev seattle-null metric 5
}
seattle_down() {
  ip link del seattle0
  ip link del seattle-null
}
retreated() { no_table && ! ip -4 route show default | grep -q wslb-null; }
seattle_route_kept() { ip -4 route show default | grep -q 'dev seattle-null'; }
check "守护进程在运行" guard_alive
seattle_up
if wait_for 1500 retreated; then ok "${ELAPSED}ms 内删掉 wslb 表和黑洞默认路由"; else bad "守护进程没有让出"; fi
check "守护进程退出" wait_for 2000 guard_gone
check "seattle 的默认路由保留" seattle_route_kept
"$BIN" start >/dev/null
sleep 1
check "seattle 在时 start 不拉起守护进程" guard_gone

echo "另一套 kill-switch 后启动 开机兜底让出"
seattle_down
"$BIN" boot >/dev/null
check "兜底层已建立" table_owner boot
printf '{ "wsl_exe": "/bin/false", "net_distro": "wslb-net" }\n' >"$WSLB_ETC/distro.json"
"$BIN" link 2>"$WORK/link.log" &
LINK=$!
sleep 1
seattle_up
if wait_for 8000 retreated; then ok "link ${ELAPSED}ms 内拆掉兜底表和黑洞默认路由"; else bad "link 没有拆掉兜底"; fi
check "seattle 的默认路由保留" seattle_route_kept
kill "$LINK"
wait "$LINK" 2>/dev/null || true

echo
if (( FAIL > 0 )); then
  echo "守护进程日志:"
  sed 's/^/    /' "$WORK/daemon.log"
  [[ -f $WORK/log/guard.log ]] && sed 's/^/    /' "$WORK/log/guard.log"
fi
echo "通过 $PASS  失败 $FAIL"
(( FAIL == 0 ))
