const std = @import("std");
const Cli = @import("../Cli.zig");
const Config = @import("Config.zig");
const boot = @import("boot.zig");
const exit_info = @import("../net/exit_info.zig");
const fsx = @import("../fsx.zig");
const identity = @import("identity.zig");

const Exit = Cli.Exit;

pub const commands = [_]Cli.Command{
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

fn loadConfig(c: *Cli) !Config {
    return (try Config.load(c.io, c.arena, c.etc(Config.file_name))).value;
}

fn saveConfig(c: *Cli, cfg: Config) !void {
    try fsx.ensureDir(c.io, c.paths.etc);
    try cfg.save(c.io, c.gpa, c.etc(Config.file_name));
}

fn bootCmd(c: *Cli, _: []const [:0]const u8) !Exit {
    const outcome = try boot.apply(c.gpa, c.io, c.env);
    switch (outcome) {
        .foreign => |name| try c.warn("另一套 kill-switch {s} 在管理网络 不做改动", .{name}),
        .applied => |a| if (a.guard) {
            try c.ok("黑洞路由已确认 守护进程的完整规则已在", .{});
        } else if (a.firewall) {
            try c.ok("已加载开机兜底 黑洞路由与防火墙", .{});
        } else {
            try c.warn("已加载黑洞路由 找不到 nft 没有防火墙层", .{});
        },
    }
    return .ok;
}

fn linkCmd(c: *Cli, _: []const [:0]const u8) !Exit {
    const cfg = try loadConfig(c);
    try boot.link(c.gpa, c.io, cfg.wsl_exe, cfg.net_distro);
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
        if (Cli.flagValue(args, "--timezone-mode")) |m| {
            cfg.identity.timezone_mode = std.meta.stringToEnum(Config.TimezoneMode, m) orelse return c.fail("timezone-mode 只能是 auto fixed windows", .{});
        }
        if (Cli.flagValue(args, "--timezone")) |tz| {
            if (!identity.validTimezone(c.io, c.paths.root, tz)) {
                return c.fail("未知时区 {s}", .{tz});
            }
            cfg.identity.timezone = tz;
            if (Cli.flagValue(args, "--timezone-mode") == null) {
                cfg.identity.timezone_mode = .fixed;
            }
        }
        if (Cli.flagValue(args, "--locale")) |l| {
            cfg.identity.locale = if (std.mem.eql(u8, l, "none")) "" else l;
        }
        if (Cli.flagValue(args, "--ntp")) |v| {
            cfg.identity.ntp = std.mem.eql(u8, v, "on");
        }
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
    const plan = identity.Plan.of(cfg.identity);
    try c.ok("时区 {s}  语言 {s}  对时 {s}", .{
        plan.timezone orelse "交还 Windows",
        plan.locale orelse "不管理",
        if (plan.ntp) "NTS" else "不管理",
    });
    try c.out.writeAll("    已打开的终端需重新登录生效 systemd 服务在下次启动 WSL 后生效\n");
    return .ok;
}
