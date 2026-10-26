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

- WSL 必须是 mirrored 网络。退回 nat 时到节点的连接要经 Windows 路由表，会被 Windows 上的代理和 VPN 改道，所以守护进程不连节点，网络保持阻断。网络页会显示退回的原因和恢复命令。
- 守护进程退出或崩溃都不撤销两层规则，只有 `wslb-agent disable --yes` 会。
- 防火墙表被删，或被换成兜底规则，守护进程收到 nftables 事件后几十毫秒内换回。
- 每 30 秒经隧道查询一个随机子域名，必须收到上游回包才算通。连续 3 次失败就自动重启 sing-box。
- 同一个 VM 里只允许一个守护进程。检测到另一套 kill-switch 的网卡（默认 `seattle0` `seattle-null`）时，守护进程和开机兜底都拒绝改动网络。
- 另一套 kill-switch 后启动时，wslb 会让出网络：删掉自己的防火墙表和黑洞默认路由，守护进程退出。交接期间由对方的规则接管。

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
2. 每页上面是状态，下面是操作列表。↑↓ 选择，回车执行，Tab 或 1 2 3 4 切页，Esc 返回，q 退出。会停掉发行版或删除数据的操作标成红色，确认框默认停在取消。
3. WSL 页：启用 WSL、更新到预发行版、写入推荐的 `.wslconfig`。
4. 网络页：安装网络发行版，安装时自动打开开机自动连接。在 `节点` 里从剪贴板导入、添加订阅或手动粘贴，支持 `vless://` `hysteria2://` `hy2://` `tuic://`，剪贴板可以是多行链接或 base64。订阅只经隧道下载，需要先有一个能用的节点，Clash 格式不支持。节点域名在 Windows 侧解析后固定为 IP，切换时重新解析。切换前先用随包 sing-box 校验配置，不通过就保持原节点。
5. 发行版页：新建 Ubuntu 或 Debian。表单只列必填项，时区、语言、显卡等收在高级选项里。新建前会先确认网络已受保护。
6. 进入发行版详情页，可以改时区语言、装卸 Firefox、系统更新、装卸软件包、导出、停止、删除。给已有发行版安装 wslb 后不会自动重启它，需要自己选停止发行版再打开。
7. 关于页：GitHub 地址、QQ 群、作者联系方式。启动时用 Windows 的 `curl.exe` 查一次 GitHub 最新发布版本，有新版本时顶栏会提示。

`wslb status` 不进界面，直接打印状态。

**节点只保存在网络发行版里，正在用的是 `/etc/wslb/node.json`，保存的节点在 `/etc/wslb/nodes/`，都是 root 600。程序里不含任何节点或 UUID。**

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

推送 `v` 开头的标签，比如 `v0.2.1`，GitHub Actions 会跑同一个 `tools/release.sh`，把 exe 和校验文件发到 Release。在 Actions 页手动运行时只编译，产物在运行记录的 Artifacts 里。

`tools/build-netdistro.sh` 的取材：
- minirootfs 与 nftables 从 Alpine 官方源下载；
- sing-box 用官方的 `-musl` 静态包，并校验 SHA-256；
- 包版本记在 `dist/wslb-net.lock`。

## 测试

全部在隔离环境里运行，不改动本机的 WSL 和网络：

| 脚本 | 内容 |
|---|---|
| `tests/netns.sh` | 在 `unshare -rn` 里跑 57 项，见下 |
| `tests/netdistro.sh` | 解包 `wslb-net` 产物，在隔离命名空间里 chroot 运行。真实 sing-box 建立 `wslb0` 与策略路由；节点不通时，探测经真实 sing-box 判定失败并重启 |
| `tests/provision.sh ubuntu\|debian` | 把官方 WSL 镜像解包后 chroot 跑完整安装流程，需要宿主装 uidmap |

`tests/netns.sh` 覆盖的场景：
- 外部 kill-switch 存在时拒绝改动；开机兜底层被守护进程接管；单实例；
- 注入默认路由、泄露探测、换网；
- 防火墙被删或被换、sing-box 崩溃、黑洞网卡被删；
- 健康探测的正常应答、SERVFAIL 与超时；
- 停用与启用；
- seattle 这类外部 kill-switch 后启动时，守护进程和开机兜底让出网络。

还没在真机上验证的：
- Windows 控制台后端：`wslb.exe` 的界面只在 Linux 的 pty 里走过，真实控制台的按键、中文输入和窗口缩放没跑过；
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
  page/                       WSL 网络 发行版列表 发行版详情 关于
  job/                        新建发行版 安装网络发行版 节点
  term/  ui/                  终端后端 屏幕缓冲 表单
tools/                        打包脚本
tests/                        集成测试
```

## 许可证

[AGPL-3.0](LICENSE)。作者 an5w1r@163.com，QQ 群 1046048297。

`wslb.exe` 里打包的网络发行版带有 sing-box（GPL-3.0）和 Alpine 的软件包，它们各自沿用原来的许可证，版本记在 `wslb-net.lock`。
