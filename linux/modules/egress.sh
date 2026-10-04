# shellcheck shell=bash
# 出口模块 配置全部经 wsl-egress 写入 本脚本只负责问答和安装文件

PAYLOAD_EGRESS=$ROOT/payload/egress
EGRESS_BIN=$ROOT/bin/wsl-egress
SINGBOX_BIN=/usr/local/lib/wsl-egress/sing-box

egress_conflict_check() {
  local foreign=""
  if ip link show seattle-null >/dev/null 2>&1; then
    foreign="seattle-null（手工版 seattle-killswitch）"
  elif ip link show egress-null >/dev/null 2>&1 && [[ ! -e /etc/systemd/system/wsl-egress.service ]]; then
    foreign="egress-null（另一个发行版里的 wsl-egress）"
  fi
  [[ -z $foreign ]] && return 0
  ui_yesno "检测到 WSL VM 中已有 kill-switch 在运行：
  $foreign

所有 WSL 发行版共享同一个网络栈。两套 kill-switch 会互相抢默认路由，
导致断网或行为不可预期。建议先在原发行版停用它，再继续。

仍然继续？" n
}

egress_ask() {
  [[ -x $EGRESS_BIN ]] || die "缺少 $EGRESS_BIN 请先在项目根目录运行 zig build -Drelease=true -p linux"
  egress_conflict_check || return 1

  local link summary errf
  errf=$(mktemp)
  while :; do
    link=$(ui_password "粘贴节点的 vless:// 分享链接（输入不回显，下一步会显示解析结果）

支持: security=tls / reality / none
      type=tcp / ws / grpc / httpupgrade") || { rm -f "$errf"; return 1; }
    if summary=$("$EGRESS_BIN" set-node --dry-run "$link" 2>"$errf"); then
      break
    fi
    ui_msg "链接无效：$(<"$errf")"
  done
  rm -f "$errf"
  NODE_LINK=$link

  local k v
  local -A n=()
  while IFS='=' read -r k v; do
    n[$k]=$v
  done <<<"$summary"
  NODE_IP=${n[ip]}
  while :; do
    NODE_IP=$(ui_input "节点: ${n[name]:-（未命名）}
  地址 ${n[host]}:${n[port]}   uuid ${n[uuid_hint]}…
  security=${n[security]}  type=${n[transport]}  sni=${n[sni]:--}  fp=${n[fingerprint]:--}${n[flow]:+  flow=${n[flow]}}

节点 IP 会被固定（kill-switch 只放行这一个 IP，之后不再需要公网 DNS）。
确认或修改节点 IPv4:" "$NODE_IP") || return 1
    [[ $NODE_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
    ui_msg "不是有效的 IPv4 地址: $NODE_IP"
  done
  NODE_LABEL="${n[name]:-${n[host]}} → $NODE_IP:${n[port]} (${n[security]}/${n[transport]})"

  local -a menu=() rows=()
  local iface cidr addr gw metric
  while IFS=$'\t' read -r iface cidr addr gw metric; do
    [[ -z $iface ]] && continue
    rows+=("$iface|$cidr|$gw")
    menu+=("$iface" "$addr  网关 $gw  (metric $metric)")
  done < <("$EGRESS_BIN" lan --tsv)
  if (( ${#rows[@]} == 0 )); then
    ui_msg "找不到可用的默认路由（真实网卡）。
如果已有 kill-switch 在运行，请先停用；或检查 Windows 网络连接。"
    return 1
  fi
  local pick=${rows[0]%%|*} row
  if (( ${#rows[@]} > 1 )); then
    pick=$(ui_menu "选择连接节点用的真实网卡（局域网上行）。
虚拟网卡（Radmin/ZeroTier/Tailscale 等）不要选。" "$pick" "${menu[@]}") || return 1
  fi
  for row in "${rows[@]}"; do
    [[ ${row%%|*} == "$pick" ]] || continue
    IFS='|' read -r _ LAN_CIDR LAN_GW <<<"$row"
  done

  local latest
  latest=$(singbox_latest 2>/dev/null || true)
  SINGBOX_VERSION=$(ui_input "sing-box 版本（默认最新 release；已在 1.13.18 / 1.14.2 上验证配置）" "${latest:-1.14.2}") || return 1
  SINGBOX_VERSION=${SINGBOX_VERSION#v}
  return 0
}

# 时区 语言 对时 所有暴露点由 wsl-egress identity 统一写入
identity_ask() {
  TZ_MODE=$(ui_menu "时区（与出口 IP 不一致是常见的指纹泄露点）" auto \
    auto    "跟随出口 IP（隧道建立后自动查询，推荐）" \
    fixed   "手动指定，如 America/Los_Angeles" \
    windows "不管理，同步 Windows 时区") || return 1
  TZ_NAME=""
  if [[ $TZ_MODE == fixed ]]; then
    while :; do
      TZ_NAME=$(ui_input "输入时区（tz database 名称）:" "America/Los_Angeles") || return 1
      [[ -e /usr/share/zoneinfo/$TZ_NAME ]] && break
      ui_msg "未知时区: $TZ_NAME"
    done
  fi
  LOCALE=$(ui_menu "系统与浏览器语言（Accept-Language 也随之统一）" en_US.UTF-8 \
    en_US.UTF-8 "English (US)，与美国出口一致" \
    en_GB.UTF-8 "English (UK)" \
    ja_JP.UTF-8 "日本語" \
    zh_CN.UTF-8 "简体中文（出口在海外时是明显指纹）" \
    other       "手动输入" \
    none        "不管理") || return 1
  if [[ $LOCALE == other ]]; then
    LOCALE=$(ui_input "输入 locale，如 de_DE.UTF-8:" "en_US.UTF-8") || return 1
  fi
  NTP=on
  ui_yesno "用 NTS 加密对时（time.cloudflare.com，经隧道）？" y || NTP=off
  return 0
}

singbox_arch() {
  case $(uname -m) in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

singbox_latest() {
  curl -fsSL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    tr -d ' \n' | grep -o '"tag_name":"v[^"]*"' | head -n1 | sed 's/.*"v\([^"]*\)"/\1/'
}

# 校验 GitHub 公布的 SHA-256 linux/vendor/ 里有离线包时优先使用
singbox_install() {
  local ver=$1 arch asset tmp sum="" url
  arch=$(singbox_arch)
  asset="sing-box-$ver-linux-$arch.tar.gz"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  if [[ -f $ROOT/vendor/$asset ]]; then
    info "使用离线包 vendor/$asset"
    cp "$ROOT/vendor/$asset" "$tmp/$asset"
    [[ -f $ROOT/vendor/$asset.sha256 ]] && sum=$(awk '{print $1}' "$ROOT/vendor/$asset.sha256")
  else
    url="https://github.com/SagerNet/sing-box/releases/download/v$ver/$asset"
    info "下载 $url"
    curl -fL --retry 3 --progress-bar -o "$tmp/$asset" "$url" || die "下载 sing-box 失败"
    sum=$(curl -fsSL --max-time 15 "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$ver" |
      tr -d ' \n' | tr ',' '\n' |
      awk -v a="\"name\":\"$asset\"" '$0 == a { f = 1 } f && /^"digest":"sha256:/ { gsub(/.*sha256:|"/, ""); print; exit }')
  fi
  if [[ -n $sum ]]; then
    echo "$sum  $tmp/$asset" | sha256sum -c --quiet - || die "sing-box 校验和不匹配，已中止"
    ok "SHA-256 校验通过"
  else
    warn "拿不到官方 SHA-256，跳过校验"
  fi
  tar -xzf "$tmp/$asset" -C "$tmp"
  install -d -m 0755 "$(dirname "$SINGBOX_BIN")"
  install -m 0755 "$tmp/sing-box-$ver-linux-$arch/sing-box" "$SINGBOX_BIN"
  ok "$("$SINGBOX_BIN" version | head -n1)"
}

# 配置阶段 隧道建立前唯一的直连流量是 sing-box 下载
egress_apply() {
  step "安装 sing-box $SINGBOX_VERSION"
  singbox_install "$SINGBOX_VERSION"

  step "安装 wsl-egress 并写入配置"
  install -m 0755 "$EGRESS_BIN" /usr/local/bin/wsl-egress
  ok "$(wsl-egress version)"
  wsl-egress config set singbox "$SINGBOX_BIN" >/dev/null
  wsl-egress config set lan-cidr "$LAN_CIDR" >/dev/null
  wsl-egress config set lan-gateway "$LAN_GW" >/dev/null
  wsl-egress set-node "$NODE_LINK" --ip "$NODE_IP" | sed 's/^/  /'
  NODE_LINK=""
  wsl-egress singbox-config >/tmp/wsl-egress-check.json
  "$SINGBOX_BIN" check -c /tmp/wsl-egress-check.json || die "生成的 sing-box 配置未通过校验"
  rm -f /tmp/wsl-egress-check.json
  ok "上行网段 $LAN_CIDR 网关 $LAN_GW"

  step "DNS / IPv6 加固"
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0 timeout:2 attempts:2 use-vc\n' >/etc/resolv.conf
  chmod 644 /etc/resolv.conf
  chattr +i /etc/resolv.conf 2>/dev/null && ok "/etc/resolv.conf 固定且不可改写" || warn "chattr 不可用，resolv.conf 未加锁"
  if [[ -d /etc/systemd ]]; then
    install_payload "$PAYLOAD_EGRESS/resolved.conf" /etc/systemd/resolved.conf.d/wsl-egress.conf 0644
  fi
  cat >/etc/sysctl.d/90-wsl-egress.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
EOF
  ok "IPv6 禁用 关闭 TCP 时间戳 拒收 ICMP 重定向"

  step "注册 systemd 服务"
  local u
  for u in wsl-egress-firewall.service wsl-egress.service wsl-egress-identity.service wsl-egress-identity-refresh.service; do
    install_payload "$PAYLOAD_EGRESS/$u" "/etc/systemd/system/$u" 0644
  done
  systemctl enable wsl-egress-firewall.service wsl-egress.service wsl-egress-identity.service wsl-egress-identity-refresh.service >/dev/null 2>&1 ||
    die "systemctl enable 失败"
  ok "wsl-egress-firewall / wsl-egress / wsl-egress-identity 已设为开机启动"
}

identity_apply() {
  step "时区 语言 对时"
  local -a args=(--timezone-mode "$TZ_MODE" --locale "$LOCALE" --ntp "$NTP")
  [[ -n $TZ_NAME ]] && args+=(--timezone "$TZ_NAME")
  wsl-egress identity set "${args[@]}" | sed 's/^/  /'
}

# 完成阶段 systemd 已运行
egress_finalize() {
  step "启动出口隧道"
  systemctl daemon-reload
  systemctl restart wsl-egress-firewall.service || warn "防火墙层暂未加载 libnftables 稍后经隧道安装"
  systemctl restart wsl-egress.service
  local info=""
  for _ in $(seq 1 40); do
    info=$(wsl-egress check 2>/dev/null) && break
    sleep 1
  done
  if [[ -z $info ]]; then
    journalctl -u wsl-egress.service -n 30 --no-pager >&2 || true
    die "出口不通（网络保持阻断，不会泄露）。检查节点链接后运行: sudo wsl-egress set-node"
  fi
  echo "$info"
}

# libnftables 经隧道安装 之前只有路由黑洞一层
egress_firewall_layer() {
  step "nftables 出站白名单"
  apt_quiet install libnftables1
  systemctl restart wsl-egress-firewall.service
  systemctl restart wsl-egress.service
  sleep 3
  if wsl-egress status --json | grep -q '"firewall": true'; then
    ok "防火墙层已加载"
  else
    warn "防火墙层未加载，仅靠路由黑洞。查看: journalctl -u wsl-egress"
  fi
  wsl-egress identity refresh --wait 30 | sed 's/^/  /' || warn "自动时区失败，稍后运行: sudo wsl-egress identity refresh"
}
