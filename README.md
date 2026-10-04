# WSL Bootstrap

一键搭建一个"只走指定节点、断线即断网"的 WSL 环境：

- **WSL 预发行版**（`wsl --update --pre-release`）+ `.wslconfig`：virtiofs 访问 Windows 磁盘、mirrored 网络、资源上限
- **Ubuntu 26.04 / 24.04**（Debian 开发中）
- **出口代理**：sing-box TUN（`wslb0`，strict_route）把全部流量送到你的 VLESS 节点
- **黑洞 kill-switch**：主路由表默认路由指向 dummy 网卡 `wslb-null`，只有节点 IP 走真实网关；IPv6 禁用；DNS 在隧道内劫持。代理挂了 = 断网，不会回落到真实 IP
- **时区跟随出口 IP**（可选固定或交还 Windows）
- **Firefox（可选）**：Mozilla 官方 APT 源的 deb，屏蔽 Ubuntu snap 过渡包；WSLg 下软件 WebRender + D3D12 WebGL；可选 WebRTC 防泄露

## 构成

| 部分 | 语言 | 作用 |
|---|---|---|
| `install.cmd` / `install.ps1` | PowerShell | Windows 端：WSL 预发行版、`.wslconfig`、安装发行版、调用 Linux 端 |
| `linux/setup.sh` + `linux/modules/` | bash | Linux 端问答与安装（whiptail） |
| **`wslb-agent`**（`src/`） | **Zig 0.17** | 守护进程 + CLI：事件驱动 kill-switch、nftables 出站白名单、监督 sing-box、时区/语言/对时统一 |
| sing-box | 官方二进制 | 数据面：TUN、VLESS、TLS/uTLS/Reality |

## 构建（在 WSL 里）

```bash
# Zig 0.17.0，仓库在 /mnt/* 上时缓存要放到 Linux 文件系统
export ZIG_LOCAL_CACHE_DIR=$HOME/.cache/zig-local/wslb
zig build test                       # 单元测试
zig build -Drelease=true -p linux    # 生成 linux/bin/wslb-agent，安装器会带上它
bash tests/netns.sh linux/bin/wslb-agent   # kill-switch 集成测试，在隔离网络命名空间里跑
```

`wslb-agent` 只动态依赖 glibc（≥2.36），libnftables 在运行时 `dlopen`：缺库时守护进程仍维持路由黑洞，不会因此起不来。

## 使用

1. 在已构建的机器上运行 `zig build -Drelease=true -p linux`，生成 `linux/bin/wslb-agent`（见上节）。
2. 把整个目录（含 `linux/bin/`）复制到目标电脑。单纯 `git clone` 不含二进制，安装器会提示先构建。
3. 双击 **`install.cmd`**（不需要以管理员运行，需要的步骤会自己弹 UAC）。
4. 跟着提示走：Windows 端用 ↑/↓ 菜单，Linux 端是 whiptail 对话框。准备好节点的 `vless://` 分享链接。

参数（可选）：

```powershell
.\install.ps1 -Distro Ubuntu-26.04 -Name Ubuntu-Egress -Location D:\WSL\Ubuntu-Egress
.\install.ps1 -SkipUpdate -SkipWslConfig   # 不动 WSL 版本和 .wslconfig
.\install.ps1 -Plain                       # 纯文本问答（无方向键菜单 / whiptail）
```

**脚本里不包含任何节点或 UUID。** 节点只在安装时由用户粘贴，保存在发行版内 `/etc/wslb/node.json`（root 600）。

## 安装流程

| 阶段 | 位置 | 内容 | 网络 |
|---|---|---|---|
| 1 | Windows | 启用/更新 WSL 预发行版，合并 `.wslconfig`（自动备份） | 直连（Windows 本身） |
| 2 | Windows | `wsl --install <发行版> --name --location --no-launch` | 直连 |
| 3 | Linux `setup.sh configure` | 全部问答 → 创建用户、下载 sing-box（校验 SHA-256）、安装 `wslb-agent` 并写配置、`/etc/wsl.conf`、时区语言 | **只有** sing-box 下载是直连 |
| 4 | Windows | `wsl --terminate` 让 systemd / wsl.conf 生效 | — |
| 5 | Linux `setup.sh finalize` | 启动 kill-switch + 隧道 → apt 升级 → 安装 libnftables 加上防火墙层 → 按出口取时区 → Firefox → 泄露测试 | **全部经隧道** |

想让阶段 3 也零直连：把 `sing-box-<ver>-linux-amd64.tar.gz`（可附 `.sha256`）放进 `linux/vendor/`。

## 防泄露设计

两层，任一层都能单独挡住直连：

1. **路由层**：主表默认路由指向 dummy 网卡 `wslb-null`，只有节点 IP 经真实网关。守护进程订阅 netlink 路由事件，WSL 注入的默认路由在 **约 10ms** 内被删除（旧 bash 版是 2 秒轮询）。
2. **防火墙层**：nftables `inet wslb` 表，出站默认丢弃，只放行 lo、`wslb0`（隧道）、节点 IP、局域网和私有网段、`loopback0` 上的 127.0.0.0/8（mirrored 模式下 Windows 的 localhost）。其余 TCP 回 RST、其他回 ICMP 拒绝，隧道断开时应用立即失败而不是挂起。WSL dnsTunneling 的 `10.255.255.254:53` 单独拦截。

开机早期 `wslb-firewall.service` 在任何网络使用前加载两层；守护进程退出或崩溃 **不会** 撤销它们，只有 `wslb-agent disable --yes` 会。

`tests/netns.sh` 在 `unshare -rn` 的隔离命名空间里验证：注入默认路由被清除、直连 TCP/UDP 被防火墙拒绝、换网切上行且不回跳、防火墙表/黑洞网卡被删后自动恢复、sing-box 崩溃自动重启、守护进程退出后两层仍在（共 18 项）。

## 时区 语言 对时

`wslb-agent identity` 统一管理，写入每一个会暴露它们的地方：

`/etc/localtime` `/etc/timezone` `/etc/environment` `/etc/default/locale` `profile.d` systemd `DefaultEnvironment` `wsl.conf [time] useWindowsTimezone` Firefox `intl.accept_languages` / `intl.locale.requested` chrony（NTS，`time.cloudflare.com` 经隧道）

- 时区：`auto` 跟随出口 IP（隧道建立后自动查询，查到之前固定 UTC，不回落 Windows 时区）/ `fixed` 指定 / `windows` 不管理
- 语言：任意 locale 或 `none`；Firefox 语言包跟随它安装，避免出口在海外却带 zh-CN
- 开机时 `wslb-identity` 在其他服务之前写入；隧道就绪后 `wslb-identity-refresh` 按出口重新查询（最多等 60 秒）；`set-node` 换节点后也会触发它

## 日常管理（发行版内）

```bash
wslb-agent status [--json]   # 守护进程 防火墙 黑洞 节点路由
wslb-agent check [--json]    # 出口 IP 地区 时区
wslb-agent lan               # 可作上行的真实网卡
sudo wslb-agent set-node     # 更换节点 粘贴新 vless:// 链接
sudo wslb-agent identity set --timezone Asia/Tokyo --locale ja_JP.UTF-8
sudo wslb-agent identity set --timezone-mode auto   # 跟随出口
sudo wslb-agent leaktest     # 停掉代理 验证直连被拒绝 再恢复
sudo wslb-agent disable --yes   # 移除两层防护 流量直连 慎用
journalctl -u wslb-agent     # 日志
```

退出码：0 成功，1 失败，2 用法错误，3 检测到泄露。`wslb-agent <命令> --help` 查看说明。

本地还有一个 SOCKS5/HTTP 代理 `127.0.0.1:41080`（mirrored 模式下 Windows 也能用）。

Firefox：`firefox [url]`、`firefox -P <名字>`（独立持久 profile）、`firefox --shortcut <名字>`（Windows 开始菜单入口）。

## 支持的节点链接

`vless://uuid@host:port?...#名称`

- `security`: `tls` / `reality`（需 `pbk`，可选 `sid`）/ `none`
- `type`: `tcp` / `ws` / `grpc` / `httpupgrade`（sing-box 不支持 `xhttp`）
- `sni` `fp`（默认 chrome uTLS）`alpn` `flow` `path` `host` `serviceName` `allowInsecure`

生成的配置已在 sing-box 1.13.18 与 1.14.2 上通过 `sing-box check`。

## 已知局限

- **作用范围是整个 WSL VM。** 所有 WSL 发行版（包括 docker-desktop）共享同一个网络栈。不要在已有另一套 kill-switch 的 VM 里再装一套（安装时会检测并提示）。
- **不保护 Windows 本身**，只保护 WSL 内的流量。从 Windows 侧工具提交的 git 记录仍带 Windows 时区。
- 节点若是域名，安装时用本机 DNS 解析一次，之后固定 IP。节点换 IP 时用 `wslb-agent set-node`。
- 还没在真实的第二台机器上端到端跑过完整安装；sing-box 实际出网只能在真机验证。

## 目录结构

```
install.cmd / install.ps1   Windows 入口
build.zig / src/            wslb-agent（Zig）
  main.zig                  CLI
  Guard.zig                 守护进程 事件循环
  netlink.zig               rtnetlink 客户端
  firewall.zig              nftables 规则与 libnftables
  lan.zig                   上行探测
  singbox.zig               sing-box 配置生成
  identity.zig              时区 语言 对时同步
  Node.zig / Config.zig     节点与配置
tests/netns.sh              kill-switch 集成测试
linux/setup.sh              Linux 端安装入口
linux/modules/              egress / firefox / hide-claude
linux/payload/              systemd 单元、Firefox prefs 等
linux/bin/                  构建产物（不入库）
```

## 卸载

```powershell
wsl --unregister <实例名>
# .wslconfig 恢复：%USERPROFILE%\.wslconfig.bak-<时间戳>
```

## 路线图

- [ ] Debian 支持（firefox 模块基本通用，主要是基础包与 sudo 差异）
- [x] nftables 出站白名单（kill-switch 第二层）
- [x] Zig 重写 kill-switch / 出口管理 / 时区语言统一
- [ ] hide-windows-claude 用 Zig 重写
- [ ] Zig 版 TUI 安装器 + 应答文件（非交互安装）
- [ ] 一行命令远程安装（`irm …/install.ps1 | iex`）
