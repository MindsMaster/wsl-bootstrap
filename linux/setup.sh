#!/usr/bin/env bash
# wsl-bootstrap Linux side. Run as root inside the new distro (install.ps1 does this).
#
#   setup.sh configure [--win-user NAME] [--gpu-hint TEXT] [--gpu-vendor NVIDIA|AMD|Intel] [--plain]
#       ask everything, create the user, install sing-box + kill-switch files,
#       write /etc/wsl.conf. No apt traffic: nothing leaves before the tunnel
#       exists except the sing-box download from GitHub.
#   setup.sh finalize [--plain]
#       after `wsl --terminate` (systemd + wsl.conf active): start the tunnel,
#       then apt upgrade / Firefox / extras, all through the tunnel.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=modules/egress.sh
. "$ROOT/modules/egress.sh"
# shellcheck source=modules/firefox.sh
. "$ROOT/modules/firefox.sh"
# shellcheck source=modules/hide-claude.sh
. "$ROOT/modules/hide-claude.sh"

PHASE=${1:-configure}
shift || true
WIN_USER="" GPU_HINT="" GPU_HINT_VENDOR=""
while (( $# )); do
  case $1 in
    --win-user)   WIN_USER=$2; shift 2 ;;
    --gpu-hint)   GPU_HINT=$2; shift 2 ;;
    --gpu-vendor) GPU_HINT_VENDOR=$2; shift 2 ;;
    --plain)      UI_PLAIN=1; shift ;;
    *) die "未知参数: $1" ;;
  esac
done

abort() { die "已取消。可重新运行安装程序从头开始。"; }

check_os() {
  detect_os
  case $OS_ID in
    ubuntu) ;;
    debian)
      ui_msg "Debian 支持正在开发中，本版本暂只支持 Ubuntu。"
      exit 3 ;;
    *) die "不支持的发行版: $OS_PRETTY" ;;
  esac
}

# ------------------------------------------------------------------- user
user_ask() {
  LINUX_USER=$(getent passwd 1000 | cut -d: -f1 || true)
  if [[ -n $LINUX_USER ]]; then
    ui_msg "已存在用户 $LINUX_USER (uid 1000)，将作为默认登录用户。"
    LINUX_PASS=""
    return 0
  fi
  local def
  def=$(tr '[:upper:]' '[:lower:]' <<<"${WIN_USER:-user}" | tr -cd 'a-z0-9_-')
  [[ $def =~ ^[a-z_] ]] || def="u$def"
  while :; do
    LINUX_USER=$(ui_input "创建 Linux 用户名（小写字母开头，可含数字 _ -）:" "$def") || return 1
    [[ $LINUX_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    ui_msg "用户名无效: $LINUX_USER"
  done
  local p2
  while :; do
    LINUX_PASS=$(ui_password "为 $LINUX_USER 设置密码（sudo 使用）:") || return 1
    p2=$(ui_password "再输入一次:") || return 1
    [[ -n $LINUX_PASS && $LINUX_PASS == "$p2" ]] && break
    ui_msg "两次密码不一致或为空，请重试。"
  done
}

user_apply() {
  step "用户 $LINUX_USER"
  if ! id "$LINUX_USER" >/dev/null 2>&1; then
    local g groups=""
    # Same groups Ubuntu's WSL OOBE gives the first user.
    for g in adm cdrom sudo dip plugdev; do
      getent group "$g" >/dev/null && groups+="${groups:+,}$g"
    done
    useradd -m -s /bin/bash ${groups:+-G "$groups"} "$LINUX_USER"
    printf '%s:%s\n' "$LINUX_USER" "$LINUX_PASS" | chpasswd
    ok "已创建（$groups）"
  else
    ok "已存在"
  fi
  LINUX_PASS=""
}

wsl_conf_write() {
  step "/etc/wsl.conf"
  backup_once /etc/wsl.conf
  cat >/etc/wsl.conf <<EOF
# Written by wsl-bootstrap. Original (if any): /etc/wsl.conf.wsl-bootstrap.bak
[boot]
systemd=true

[user]
default=$LINUX_USER

[network]
generateHosts=true
generateResolvConf=$( (( MOD_EGRESS )) && echo false || echo true)

[interop]
enabled=true
appendWindowsPath=true
EOF
  ok "systemd=true, default=$LINUX_USER$( (( MOD_EGRESS )) && echo ', generateResolvConf=false')"
}

ensure_tools() {
  local -a miss=()
  local t
  for t in curl tar sha256sum ip chattr getent whiptail; do
    command -v "$t" >/dev/null 2>&1 || miss+=("$t")
  done
  (( ${#miss[@]} == 0 )) && return 0
  warn "缺少: ${miss[*]}，将在隧道建立前用 apt 安装（会直连软件源）"
  apt_quiet update
  apt_quiet install curl tar coreutils iproute2 e2fsprogs libc-bin whiptail ca-certificates
}

# ------------------------------------------------------------------ phases
phase_configure() {
  need_root
  ui_init
  check_os
  ensure_tools
  ui_init

  ui_msg "欢迎使用 WSL Bootstrap（$OS_PRETTY）

接下来会询问几项设置，确认后才开始修改系统：
  • 默认用户与 /etc/wsl.conf（systemd）
  • 出口代理：sing-box TUN 走指定 VLESS 节点
    + 黑洞 kill-switch（代理断开时整个 WSL 断网，不回落真实 IP）
  • Firefox：Mozilla 官方 deb，替换 Ubuntu snap 版（可选）

任何对话框按 Esc / 取消 即可中止。"

  local sel
  sel=$(ui_checklist "选择要安装的组件（空格勾选，回车确认）" \
    egress  "出口代理 + 黑洞 kill-switch（防 IP 泄露）" on \
    firefox "Firefox（Mozilla 官方 deb，WSLg 调优）" on \
    hide    "在 WSL 中隐藏 Windows 侧 Claude Code 数据" off) || abort
  MOD_EGRESS=0 MOD_FIREFOX=0 MOD_HIDE=0
  [[ $sel == *egress* ]] && MOD_EGRESS=1
  [[ $sel == *firefox* ]] && MOD_FIREFOX=1
  [[ $sel == *hide* ]] && MOD_HIDE=1

  user_ask || abort
  TZ_MODE=windows TZ_NAME="" LOCALE=none NTP=off
  if (( MOD_EGRESS )); then
    egress_ask || abort
    identity_ask || abort
  fi
  FF_GPU="" FF_WEBRTC=0
  if (( MOD_FIREFOX )); then firefox_ask || abort; fi

  local summary="用户:        $LINUX_USER"
  if (( MOD_EGRESS )); then
    summary+="
出口节点:    $NODE_LABEL
真实上行:    $LAN_CIDR via $LAN_GW
时区:        $TZ_MODE ${TZ_NAME}
语言:        $LOCALE   NTS 对时: $NTP
sing-box:    $SINGBOX_VERSION"
  else
    summary+="
出口代理:    不安装（真实 IP 直连！）"
  fi
  (( MOD_FIREFOX )) && summary+="
Firefox:     Mozilla deb, GPU=${FF_GPU:-auto}, WebRTC防泄露=$FF_WEBRTC"
  (( MOD_HIDE )) && summary+="
隐藏 Windows Claude 数据: 是"
  ui_yesno "确认以下设置并开始安装？

$summary" y || abort

  [[ $UI == whiptail ]] && clear
  user_apply
  if (( MOD_EGRESS )); then egress_apply; fi
  wsl_conf_write
  if (( MOD_EGRESS )); then identity_apply; fi
  state_save LINUX_USER MOD_EGRESS MOD_FIREFOX MOD_HIDE FF_GPU FF_WEBRTC LOCALE
  printf '\n%s配置阶段完成。%s 需重启发行版以启用 systemd / wsl.conf，然后运行 finalize。\n' "$C_G$C_B" "$C_N"
}

phase_finalize() {
  need_root
  ui_init
  detect_os
  state_load
  [[ -n ${LINUX_USER:-} ]] || die "找不到 $STATE_FILE，请先运行 configure"
  [[ -d /run/systemd/system ]] || die "systemd 未运行。请执行 wsl --terminate <发行版> 后重试"

  if (( MOD_EGRESS )); then
    egress_finalize
  fi

  step "系统更新$( (( MOD_EGRESS )) && echo '（经由隧道）')"
  apt_quiet update
  apt_quiet full-upgrade
  apt_quiet install curl ca-certificates gnupg iproute2 iputils-ping whiptail
  ok "完成"
  if (( MOD_EGRESS )); then
    egress_firewall_layer
  fi

  if (( MOD_FIREFOX )); then firefox_finalize "$LINUX_USER"; fi
  if (( MOD_HIDE )); then hide_claude_finalize; fi

  if (( MOD_EGRESS )); then
    step "泄露测试"
    wsl-egress leaktest || warn "泄露测试未全部通过，请查看上方输出"
  fi

  printf '\n%s安装完成%s\n' "$C_G$C_B" "$C_N"
  if (( MOD_EGRESS )); then
    printf '%s\n' \
      "  wsl-egress status            出口 防火墙 黑洞状态" \
      "  wsl-egress check             出口 IP 与时区" \
      "  sudo wsl-egress set-node     更换节点" \
      "  sudo wsl-egress identity set 改时区 语言" \
      "  本地代理 127.0.0.1:41080 (SOCKS5/HTTP)"
  fi
  (( MOD_FIREFOX )) && echo "  firefox [url] / firefox -P <名字>   启动 Firefox（新开终端后生效）"
  return 0
}

case $PHASE in
  configure) phase_configure ;;
  finalize)  phase_finalize ;;
  *) die "用法: setup.sh configure|finalize" ;;
esac
