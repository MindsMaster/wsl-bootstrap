# wslb

在 Windows 上管理 WSL 的终端程序。它做四件事：
- 装好 WSL 预发行版和推荐配置；
- 用一个专门的网络发行版，让整个 WSL 只经指定节点出网，断线即断网；
- 按需新建 Ubuntu 或 Debian；
- 统一时区、语言、对时和 Firefox。

## 组成

| 部分 | 运行位置 | 作用 |
|---|---|---|
| `wslb.exe`（`src/manager`） | Windows | TUI 管理器：WSL 版本与更新、`.wslconfig`、网络发行版、各发行版的安装与管理 |
| `wslb-agent`（`src/agent`） | 每个发行版里 | 静态链接，Ubuntu、Debian、Alpine 通用。网络侧是守护进程，用户侧负责开机防护、身份同步、软件安装 |
| `wslb-net` | 专用 Alpine 发行版 | 只运行守护进程和官方 sing-box，负责整个 WSL 的出口 |

`wslb.exe` 一个文件里带着 agent 和网络发行版的 rootfs，复制到别的电脑就能用。

## 为什么要单独的网络发行版

所有 WSL 发行版跑在同一个虚拟机里，共用一套网卡、路由表和防火墙。网络防护改的是这套共用网络，进程放在哪个发行版都一样。把它单独放进 `wslb-net` 有三个好处：

- 用户发行版随便重装、删除，网络防护不受影响；
- 节点和规则只有一份；
- 隧道不会因为某个用户发行版被关掉而断开。

每个用户发行版开机第一步仍会自己加载一层兜底：黑洞默认路由，加上只放行本地网段的防火墙。网络发行版还没起来时，这个发行版是断网的，不会直连。兜底层只在防火墙表不存在时创建，不会覆盖守护进程的规则。

## 防泄露

两层，任一层都能单独挡住直连：

1. **路由**：默认路由指向 dummy 网卡 `wslb-null`，只有节点 IP 经真实网关。守护进程订阅 netlink 事件，WSL 注入的默认路由约 10ms 内被删。
2. **防火墙**：nftables `inet wslb` 表，出站默认丢弃，只放行 lo、隧道 `wslb0`、节点 IP、本地网段，以及 mirrored 模式下 Windows 的 127.0.0.0/8。TCP 回 RST，应用立即失败，不会卡住。

另外：

- 守护进程退出或崩溃都不撤销两层规则，只有 `wslb-agent disable --yes` 会。
- 防火墙表被删，或被换成兜底规则，守护进程收到 nftables 事件后几十毫秒内换回。
- 每 30 秒经隧道查询一个随机子域名，必须收到上游回包才算通。连续 3 次失败就自动重启 sing-box。
- 同一个 VM 里只允许一个守护进程。检测到另一套 kill-switch 的网卡（默认 `seattle0` `seattle-null`）时，守护进程和开机兜底都拒绝改动网络。

## 时区 语言 对时

每个发行版各自设置，写入所有会暴露它们的位置：`/etc/localtime` `/etc/timezone` `/etc/environment` `/etc/default/locale` `profile.d` systemd `DefaultEnvironment` `wsl.conf [time]` Firefox `intl.*` chrony NTS。

- **时区**有三种模式：
  - `auto` 跟随出口 IP，查到之前固定为 UTC，不回落到 Windows 时区；
  - `fixed` 手动指定；
  - `windows` 不管理。
- **语言**：Firefox 语言包跟随它安装。
- Ubuntu 与 Debian 生成 locale 的方式不同，差异放在 `src/agent/distro/os/`。

## 使用

1. 把 `wslb.exe` 复制到目标电脑，在 Windows Terminal 或 cmd 里运行。
2. WSL 页：没有 WSL 时按 i 启用；按 u 更新到预发行版；按 c 写入推荐的 `.wslconfig`。
3. 网络页：按 i 安装网络发行版，按 n 粘贴 `vless://` 链接。节点域名在 Windows 侧解析后固定为 IP。
4. 发行版页：按 n 新建 Ubuntu 或 Debian，填写用户名、密码、时区、语言，选择是否装 Firefox。新建前会先确认网络已受保护。
5. 进入发行版详情页，可以改时区语言、装卸 Firefox、系统更新、装卸软件包、导出、删除。

`wslb status` 不进界面，直接打印状态。

**节点只保存在网络发行版的 `/etc/wslb/node.json`（root 600），程序里不含任何节点或 UUID。**

发行版内也可以直接用 agent：

```bash
wslb-agent status            # 防护状态 网络发行版里最完整
wslb-agent check             # 经隧道查出口 IP 与时区
sudo wslb-agent identity set --timezone Asia/Tokyo --locale ja_JP.UTF-8
sudo wslb-agent pkg upgrade  # 网络未受保护时拒绝联网
sudo wslb-agent firefox install --gpu NVIDIA
```

## 构建

在 WSL 里构建，需要 Zig 0.17.0。仓库在 `/mnt/*` 上时，缓存要放到 Linux 文件系统：

```bash
export ZIG_LOCAL_CACHE_DIR=$HOME/.cache/zig-local/wslb
zig build test                      # 单元测试
tools/release.sh 0.2.0              # 打网络发行版并编进 dist/wslb-0.2.0.exe
```

`tools/build-netdistro.sh` 的取材：
- minirootfs 与 nftables 从 Alpine 官方源下载；
- sing-box 用官方的 `-musl` 静态包，并校验 SHA-256；
- 包版本记在 `dist/wslb-net.lock`。

## 测试

全部在隔离环境里运行，不改动本机的 WSL 和网络：

| 脚本 | 内容 |
|---|---|
| `tests/netns.sh` | 在 `unshare -rn` 里跑 49 项，见下 |
| `tests/netdistro.sh` | 解包 `wslb-net` 产物，在隔离命名空间里 chroot 运行，真实 sing-box 建立 `wslb0` 与策略路由 |
| `tests/provision.sh ubuntu\|debian` | 把官方 WSL 镜像解包后 chroot 跑完整安装流程，需要宿主装 uidmap |

`tests/netns.sh` 覆盖的场景：
- 外部 kill-switch 存在时拒绝改动；开机兜底层被守护进程接管；单实例；
- 注入默认路由、泄露探测、换网；
- 防火墙被删或被换、sing-box 崩溃、黑洞网卡被删；
- 健康探测的正常应答、SERVFAIL 与超时；
- 停用与启用。

还没在真机上验证的：
- `wsl --import` 之后，网络发行版的开机命令能否正常运行；
- `wslb-link` 能否在 systemd 服务里调用 `wsl.exe`；
- 没有终端开着时，网络发行版会不会被 WSL 停掉；
- 用真实节点出网。

## 目录

```
build.zig
src/shared/ini.zig            两端共用的 INI 读写
src/agent/
  main.zig  Cli.zig           命令注册与分发
  net/                        网络发行版：守护进程 防火墙 netlink 健康探测 控制套接字
  distro/                     用户发行版：开机兜底 身份同步 安装流程 Firefox
    Os.zig  os/               Ubuntu 与 Debian 的差异
    assets/                   systemd 单元 Firefox 配置 Mozilla 签名公钥
src/manager/
  main.zig  App.zig           入口 状态与分发
  Wsl.zig  Runner.zig         wsl.exe 调用 真实与录制两种执行器
  page/                       WSL 网络 发行版列表 发行版详情
  job/                        新建发行版 安装网络发行版 设置节点
  term/  ui/                  终端后端 屏幕缓冲 表单
tools/                        打包脚本
tests/                        集成测试
```
