# shellcheck shell=bash
# Module (optional): hide Windows-side Claude Code data from Linux tools in WSL
# by bind-mounting unreadable placeholders over it. Windows copies untouched.

hide_claude_finalize() {
  step "隐藏 Windows 侧 Claude Code 数据"
  install_payload "$ROOT/payload/hide-claude/hide-windows-claude" /usr/local/sbin/hide-windows-claude 0755
  install_payload "$ROOT/payload/hide-claude/hide-windows-claude.service" /etc/systemd/system/hide-windows-claude.service 0644
  systemctl daemon-reload
  systemctl enable --now hide-windows-claude.service >/dev/null 2>&1 || die "启动 hide-windows-claude 失败"
  ok "hide-windows-claude 已启用（/mnt/*/Users/*/.claude 等被遮蔽）"
}
