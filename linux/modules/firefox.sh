# shellcheck shell=bash
# Module: Firefox from Mozilla's APT repo (not the Ubuntu snap), tuned for WSLg.

PAYLOAD_FIREFOX=$ROOT/payload/firefox
MOZILLA_KEY_FPR=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3

firefox_ask() {
  FF_GPU=$(ui_menu "WebGL 用哪块显卡（Mesa D3D12 适配器名，按子串匹配）
检测到的 Windows 显卡: ${GPU_HINT:-未知}" "${GPU_HINT_VENDOR:-auto}" \
    NVIDIA "NVIDIA" \
    AMD    "AMD" \
    Intel  "Intel" \
    auto   "不指定，交给 Mesa 选择") || return 1
  [[ $FF_GPU == auto ]] && FF_GPU=""
  FF_WEBRTC=0
  ui_yesno "WebRTC 防泄露：只暴露出口地址，不暴露局域网 IP？
（会影响部分 P2P 视频通话的连通性）" y && FF_WEBRTC=1
  return 0
}

# 语言包跟随身份设置的 locale  zh_CN.UTF-8 对应 firefox-l10n-zh-cn
firefox_l10n_package() {
  local locale=$1 tag full short
  [[ $locale == none || $locale == en_US* ]] && return 0
  tag=$(tr '[:upper:]_' '[:lower:]-' <<<"${locale%%.*}")
  full=firefox-l10n-$tag
  short=firefox-l10n-${tag%%-*}
  if apt-cache show "$full" >/dev/null 2>&1; then
    echo "$full"
  elif apt-cache show "$short" >/dev/null 2>&1; then
    echo "$short"
  fi
}

firefox_finalize() {
  local user=$1 home
  home=$(getent passwd "$user" | cut -d: -f6)

  step "Firefox: 移除 snap 版，接入 Mozilla 官方 APT 源"
  if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
    snap remove --purge firefox && ok "已移除 snap firefox"
  fi
  command -v gpg >/dev/null 2>&1 || apt_quiet install gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
  local fpr
  fpr=$(gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null |
    awk '/^pub/ { getline; gsub(/^ +| +$/, ""); print; exit }')
  [[ $fpr == "$MOZILLA_KEY_FPR" ]] || die "Mozilla 签名密钥指纹不匹配: $fpr"
  ok "签名密钥指纹校验通过"
  cat >/etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
  printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' >/etc/apt/preferences.d/mozilla
  if [[ $OS_ID == ubuntu ]]; then
    # Ubuntu's firefox is a transitional deb that installs the snap; snap Firefox
    # cannot reach /usr/lib/wsl/lib (no GPU) and breaks DISPLAY under WSLg.
    printf 'Package: firefox*\nPin: release o=Ubuntu\nPin-Priority: -1\n' >/etc/apt/preferences.d/firefox-no-ubuntu
    printf 'Unattended-Upgrade::Package-Blacklist { "firefox"; };\n' >/etc/apt/apt.conf.d/51unattended-upgrades-firefox
    ok "已屏蔽 Ubuntu 的 snap 过渡包，unattended-upgrades 不再动 firefox"
  fi

  step "Firefox: 安装"
  apt_quiet update
  local -a pkgs=(firefox)
  local l10n
  l10n=$(firefox_l10n_package "${LOCALE:-none}")
  [[ -n $l10n ]] && pkgs+=("$l10n")
  apt_quiet install --allow-downgrades "${pkgs[@]}"
  [[ $(readlink -f /usr/bin/firefox) == /usr/lib/firefox/* ]] || die "/usr/bin/firefox 不是 Mozilla deb 版本"
  ok "$(/usr/lib/firefox/firefox --version 2>/dev/null || echo firefox)（Mozilla deb）"

  step "Firefox: WSLg 显示 / GPU 配置"
  install_payload "$PAYLOAD_FIREFOX/wslg-prefs.js" /usr/lib/firefox/defaults/pref/wslg-prefs.js 0644
  if (( FF_WEBRTC )); then
    install_payload "$PAYLOAD_FIREFOX/webrtc-noleak.js" /usr/lib/firefox/defaults/pref/webrtc-noleak.js 0644
  fi
  local adapter='# MESA_D3D12_DEFAULT_ADAPTER_NAME not set: Mesa picks the adapter'
  [[ -n $FF_GPU ]] && adapter="export MESA_D3D12_DEFAULT_ADAPTER_NAME=$FF_GPU"
  tr -d '\r' <"$PAYLOAD_FIREFOX/wslg-gpu.sh.in" | sed "s|@ADAPTER_LINE@|$adapter|" >/etc/profile.d/wslg-gpu.sh
  chmod 644 /etc/profile.d/wslg-gpu.sh
  install_payload "$PAYLOAD_FIREFOX/wsl-firefox" /usr/local/bin/wsl-firefox 0755
  ok "软件 WebRender + D3D12 WebGL${FF_GPU:+（$FF_GPU）}"

  # `firefox` in interactive shells and the WSLg Start-menu entry both go
  # through the launcher, so the GPU env is always applied.
  local aliases=$home/.bash_aliases
  touch "$aliases"
  sed -i '/^# >>> wsl-bootstrap firefox >>>$/,/^# <<< wsl-bootstrap firefox <<<$/d' "$aliases"
  cat >>"$aliases" <<'EOF'
# >>> wsl-bootstrap firefox >>>
# firefox [url] | firefox -P <name> [url] | firefox --profiles | firefox --shortcut <name>
firefox() { /usr/local/bin/wsl-firefox "$@"; }
_firefox_complete() {
  case "${COMP_WORDS[COMP_CWORD-1]}" in
    -P|-p|--shortcut) COMPREPLY=($(compgen -W "$(wsl-firefox --profiles 2>/dev/null)" -- "${COMP_WORDS[COMP_CWORD]}")) ;;
  esac
}
complete -o default -F _firefox_complete firefox
# <<< wsl-bootstrap firefox <<<
EOF
  local apps=$home/.local/share/applications
  install -d -m 0755 "$apps"
  sed -E 's#^Exec=firefox#Exec=/usr/local/bin/wsl-firefox#' /usr/share/applications/firefox.desktop >"$apps/firefox.desktop"
  chown -R "$user:" "$aliases" "$home/.local"
  ok "命令 firefox / 开始菜单入口 → wsl-firefox"
}
