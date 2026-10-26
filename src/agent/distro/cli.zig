const std = @import("std");
const Cli = @import("../Cli.zig");
const Config = @import("Config.zig");
const Ctx = @import("Ctx.zig");
const Os = @import("Os.zig");
const boot = @import("boot.zig");
const firefox = @import("firefox.zig");
const hide_claude = @import("hide_claude.zig");
const provision = @import("provision.zig");
const exit_info = @import("../net/exit_info.zig");
const fsx = @import("../fsx.zig");
const identity = @import("identity.zig");

const Exit = Cli.Exit;

pub const commands = [_]Cli.Command{
    .{ .name = "provision", .args = "--user 名字 [--password-stdin] [选项]", .summary = "把当前发行版装成受保护的用户系统 见 provision --help", .group = .distro, .run = provisionCmd },
    .{ .name = "pkg", .args = "upgrade | install <包> | remove <包> | search <词> | list [--json]", .summary = "软件包管理 联网操作要求网络受保护", .group = .distro, .run = pkgCmd },
    .{ .name = "firefox", .args = "install [--gpu 名称] [--no-webrtc-noleak] | remove", .summary = "Mozilla 官方 Firefox 与 WSLg 调优", .group = .distro, .run = firefoxCmd },
    .{ .name = "hide-claude", .args = "on | off", .summary = "在 WSL 里遮蔽 Windows 侧 Claude Code 数据", .group = .distro, .run = hideClaudeCmd },
    .{ .name = "identity", .args = "show | set [选项] | apply | refresh [--wait 秒]", .summary = "时区 语言 对时统一 见 identity --help", .group = .distro, .run = identityCmd },
    .{ .name = "boot", .summary = "开机兜底 网络发行版没起来时先断网", .group = .internal, .run = bootCmd },
    .{ .name = "link", .summary = "连着网络发行版 保持它运行", .group = .internal, .run = linkCmd },
};

const identity_usage =
    \\wslb-agent identity 时区 语言 对时
    \\
    \\  identity show
    \\  identity set [--timezone-mode auto|fixed|windows] [--timezone Area/City]
    \\               [--locale en_US.UTF-8|none] [--ntp on|off]
    \\  identity apply      把当前设置写到所有相关位置
    \\  identity refresh    auto 模式下按出口 IP 重新取时区并应用
    \\
    \\同步位置 /etc/localtime /etc/timezone /etc/environment /etc/default/locale
    \\  profile.d systemd DefaultEnvironment wsl.conf[time] Firefox intl.* chrony
    \\
;

const provision_usage =
    \\wslb-agent provision 把当前发行版装成受保护的用户系统 需 root
    \\
    \\  --user 名字             uid 1000 的默认用户 已存在时沿用
    \\  --password-stdin        从标准输入第一行读密码
    \\  --net-distro 名字       网络发行版 默认 wslb-net
    \\  --wsl-exe 路径          发行版里 wsl.exe 的路径
    \\  --timezone-mode auto|fixed|windows  --timezone Area/City
    \\  --locale en_US.UTF-8|none  --ntp on|off
    \\  --no-upgrade            不做 full-upgrade
    \\  --firefox [--gpu 名称] [--no-webrtc-noleak]
    \\  --hide-claude
    \\
;

fn makeCtx(c: *Cli) !Ctx {
    return .{
        .gpa = c.gpa,
        .arena = c.arena,
        .io = c.io,
        .env = c.env,
        .out = c.out,
        .os = try Os.detect(c.io, c.arena, ""),
    };
}

fn defaultUser(ctx: *Ctx) ![]const u8 {
    return (try provision.userByUid(ctx, provision.first_uid)) orelse error.NoDefaultUser;
}

/// 联网前的防护检查 不通过就拒绝 不让 apt 直连
fn requireProtection(c: *Cli) bool {
    provision.protection() catch {
        c.err.writeAll("wslb-agent: 网络未受保护 网络发行版的守护进程未运行 拒绝联网\n") catch {};
        return false;
    };
    return true;
}

fn provisionCmd(c: *Cli, args: []const [:0]const u8) !Exit {
    if (Cli.hasFlag(args, "--help")) {
        try c.out.writeAll(provision_usage);
        return .ok;
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    var opts: provision.Options = .{ .user = Cli.flagValue(args, "--user") orelse "" };
    if (Cli.hasFlag(args, "--password-stdin")) {
        opts.password = try c.readStdinLine();
    }
    if (Cli.flagValue(args, "--net-distro")) |v| {
        opts.net_distro = v;
    }
    if (Cli.flagValue(args, "--wsl-exe")) |v| {
        opts.wsl_exe = v;
    }
    opts.identity = parseIdentity(c, args, .{}) catch |err| return c.fail("{s}", .{@errorName(err)});
    opts.upgrade = !Cli.hasFlag(args, "--no-upgrade");
    if (Cli.hasFlag(args, "--firefox")) {
        opts.firefox = .{
            .gpu = Cli.flagValue(args, "--gpu") orelse "",
            .webrtc_noleak = !Cli.hasFlag(args, "--no-webrtc-noleak"),
        };
    }
    opts.hide_claude = Cli.hasFlag(args, "--hide-claude");
    var ctx = makeCtx(c) catch |err| return c.fail("不支持的发行版 {s}", .{@errorName(err)});
    provision.run(&ctx, opts) catch |err| {
        c.out.flush() catch {};
        return c.fail("安装中断 {s}", .{@errorName(err)});
    };
    try c.out.writeAll("==> 完成 重启发行版后 systemd 与开机防护生效\n");
    return .ok;
}

fn pkgCmd(c: *Cli, args: []const [:0]const u8) !Exit {
    const sub = if (args.len > 0) args[0] else "";
    const names = if (args.len > 1) args[1..] else args[0..0];
    var ctx = makeCtx(c) catch |err| return c.fail("不支持的发行版 {s}", .{@errorName(err)});
    if (std.mem.eql(u8, sub, "search") and names.len > 0) {
        const r = try std.process.run(c.arena, c.io, .{ .argv = &.{ "apt-cache", "search", "--names-only", names[0] } });
        return printPackages(c, r.stdout, " - ");
    }
    if (std.mem.eql(u8, sub, "list")) {
        const manual = try std.process.run(c.arena, c.io, .{ .argv = &.{ "apt-mark", "showmanual" } });
        return printPackages(c, manual.stdout, "");
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    if (std.mem.eql(u8, sub, "remove") and names.len > 0) {
        try ctx.apt(try std.mem.concat(c.arena, []const u8, &.{ &.{"remove"}, toSlices(names) }));
        return .ok;
    }
    if (!requireProtection(c)) {
        return .failed;
    }
    if (std.mem.eql(u8, sub, "upgrade")) {
        try ctx.apt(&.{"update"});
        try ctx.apt(&.{"full-upgrade"});
        return .ok;
    }
    if (std.mem.eql(u8, sub, "install") and names.len > 0) {
        try ctx.apt(try std.mem.concat(c.arena, []const u8, &.{ &.{"install"}, toSlices(names) }));
        return .ok;
    }
    return c.usage("pkg upgrade | install <包> | remove <包> | search <词> | list [--json]");
}

fn toSlices(args: []const [:0]const u8) []const []const u8 {
    return @ptrCast(args);
}

/// 每行一个包 sep 非空时其后是说明
fn printPackages(c: *Cli, text: []const u8, sep: []const u8) !Exit {
    var s: std.json.Stringify = .{ .writer = c.out, .options = .{ .whitespace = .indent_2 } };
    if (c.json) {
        try s.beginArray();
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        const cut = if (sep.len != 0) std.mem.indexOf(u8, line, sep) else null;
        const name = if (cut) |i| line[0..i] else line;
        const summary = if (cut) |i| line[i + sep.len ..] else "";
        if (c.json) {
            try s.write(.{ .name = name, .summary = summary });
        } else {
            try c.out.print("{s:<32} {s}\n", .{ name, summary });
        }
    }
    if (c.json) {
        try s.endArray();
        try c.out.writeAll("\n");
    }
    return .ok;
}

fn firefoxCmd(c: *Cli, args: []const [:0]const u8) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    var ctx = makeCtx(c) catch |err| return c.fail("不支持的发行版 {s}", .{@errorName(err)});
    const user = defaultUser(&ctx) catch return c.fail("找不到 uid 1000 的用户", .{});
    const sub = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, sub, "remove")) {
        try firefox.remove(&ctx, user);
        return .ok;
    }
    if (!std.mem.eql(u8, sub, "install")) {
        return c.usage("firefox install [--gpu 名称] [--no-webrtc-noleak] | remove");
    }
    if (!requireProtection(c)) {
        return .failed;
    }
    const cfg = try loadConfig(c);
    try firefox.install(&ctx, user, .{
        .gpu = Cli.flagValue(args, "--gpu") orelse "",
        .webrtc_noleak = !Cli.hasFlag(args, "--no-webrtc-noleak"),
        .locale = cfg.identity.locale,
    });
    try identity.apply(c.gpa, c.io, "", cfg.identity);
    return .ok;
}

fn hideClaudeCmd(c: *Cli, args: []const [:0]const u8) !Exit {
    if (!c.requireRoot()) {
        return .failed;
    }
    var ctx = makeCtx(c) catch |err| return c.fail("不支持的发行版 {s}", .{@errorName(err)});
    const sub = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, sub, "on")) {
        try hide_claude.install(&ctx);
    } else if (std.mem.eql(u8, sub, "off")) {
        hide_claude.remove(&ctx);
    } else {
        return c.usage("hide-claude on | off");
    }
    return .ok;
}

/// identity set 与 provision 共用的选项解析
fn parseIdentity(c: *Cli, args: []const [:0]const u8, base: Config.Identity) !Config.Identity {
    var id = base;
    if (Cli.flagValue(args, "--timezone-mode")) |m| {
        id.timezone_mode = std.meta.stringToEnum(Config.TimezoneMode, m) orelse return error.BadTimezoneMode;
    }
    if (Cli.flagValue(args, "--timezone")) |tz| {
        if (!identity.validTimezone(c.io, c.paths.root, tz)) {
            return error.UnknownTimezone;
        }
        id.timezone = tz;
        if (Cli.flagValue(args, "--timezone-mode") == null) {
            id.timezone_mode = .fixed;
        }
    }
    if (Cli.flagValue(args, "--locale")) |l| {
        id.locale = if (std.mem.eql(u8, l, "none")) "" else l;
    }
    if (Cli.flagValue(args, "--ntp")) |v| {
        id.ntp = std.mem.eql(u8, v, "on");
    }
    return id;
}

fn loadConfig(c: *Cli) !Config {
    return (try Config.load(c.io, c.arena, c.etc(Config.file_name))).value;
}

fn saveConfig(c: *Cli, cfg: Config) !void {
    try fsx.ensureDir(c.io, c.paths.etc);
    try cfg.save(c.io, c.gpa, c.etc(Config.file_name));
}

fn bootCmd(c: *Cli, _: []const [:0]const u8) !Exit {
    const a = try boot.apply(c.gpa, c.io, c.env);
    if (a.guard) {
        try c.ok("黑洞路由已确认 守护进程的完整规则已在", .{});
    } else if (a.firewall) {
        try c.ok("已加载开机兜底 黑洞路由与防火墙", .{});
    } else {
        try c.warn("已加载黑洞路由 找不到 nft 没有防火墙层", .{});
    }
    return .ok;
}

fn linkCmd(c: *Cli, _: []const [:0]const u8) !Exit {
    const cfg = try loadConfig(c);
    try boot.link(c.io, cfg.wsl_exe, cfg.net_distro);
    return .ok;
}

fn identityCmd(c: *Cli, args: []const [:0]const u8) !Exit {
    if (Cli.hasFlag(args, "--help")) {
        try c.out.writeAll(identity_usage);
        return .ok;
    }
    const sub = if (args.len > 0) args[0] else "show";
    var cfg = try loadConfig(c);
    if (std.mem.eql(u8, sub, "show")) {
        try c.writeJson(cfg.identity);
        return .ok;
    }
    if (!c.requireRoot()) {
        return .failed;
    }
    if (std.mem.eql(u8, sub, "set")) {
        cfg.identity = parseIdentity(c, args, cfg.identity) catch |err| return c.fail("{s}", .{@errorName(err)});
        try saveConfig(c, cfg);
        try c.ok("身份设置已保存", .{});
        return applyIdentity(c, cfg);
    }
    if (std.mem.eql(u8, sub, "apply")) {
        return applyIdentity(c, cfg);
    }
    if (std.mem.eql(u8, sub, "refresh")) {
        if (cfg.identity.timezone_mode == .auto) {
            const wait_s = std.fmt.parseInt(u32, Cli.flagValue(args, "--wait") orelse "15", 10) catch 15;
            const info = try fetchUntil(c, wait_s * 1000) orelse return c.fail("{d} 秒内查不到出口时区 隧道未就绪", .{wait_s});
            if (!identity.validTimezone(c.io, c.paths.root, info.timezone)) {
                return c.fail("出口时区无效 {s}", .{info.timezone});
            }
            if (!std.mem.eql(u8, cfg.identity.timezone, info.timezone)) {
                cfg.identity.timezone = info.timezone;
                try saveConfig(c, cfg);
            }
            try c.ok("出口 {s} 时区 {s}", .{ info.ip, info.timezone });
        }
        return applyIdentity(c, cfg);
    }
    try c.err.writeAll(identity_usage);
    return .usage;
}

/// 开机时隧道可能还没起来 截止前反复尝试
fn fetchUntil(c: *Cli, budget_ms: u32) !?exit_info.Info {
    var spent: u32 = 0;
    while (spent < budget_ms) {
        const attempt_ms = @min(10_000, budget_ms - spent);
        if (exit_info.fetchTimeout(c.arena, c.io, attempt_ms)) |info| {
            return info;
        } else |_| {}
        spent += attempt_ms;
        if (spent < budget_ms) {
            try c.io.sleep(.fromSeconds(2), .awake);
            spent += 2000;
        }
    }
    return null;
}

fn applyIdentity(c: *Cli, cfg: Config) !Exit {
    identity.apply(c.gpa, c.io, c.paths.root, cfg.identity) catch |err| return c.fail("应用身份设置失败 {s}", .{@errorName(err)});
    if (c.paths.root.len == 0) {
        if (makeCtx(c)) |ctx_value| {
            var ctx = ctx_value;
            identity.activate(&ctx, cfg.identity);
        } else |_| {}
    }
    const plan = identity.Plan.of(cfg.identity);
    try c.ok("时区 {s}  语言 {s}  对时 {s}", .{
        plan.timezone orelse "交还 Windows",
        plan.locale orelse "不管理",
        if (plan.ntp) "NTS" else "不管理",
    });
    try c.out.writeAll("    已打开的终端需重新登录生效 systemd 服务在下次启动 WSL 后生效\n");
    return .ok;
}
