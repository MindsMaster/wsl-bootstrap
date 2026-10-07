const std = @import("std");
const Config = @import("Config.zig");
const Control = @import("../net/Control.zig");
const Ctx = @import("Ctx.zig");
const Guard = @import("../net/Guard.zig");
const firefox = @import("firefox.zig");
const fsx = @import("../fsx.zig");
const ini = @import("ini");
const hide_claude = @import("hide_claude.zig");
const identity = @import("identity.zig");
const netlink = @import("../net/netlink.zig");

/// 两个发行版的镜像各缺一部分 Ubuntu 缺 nftables Debian 缺 curl chrony
const base_packages = [_][]const u8{ "nftables", "chrony", "locales", "ca-certificates", "curl", "iproute2", "sudo" };
const agent_path = "/usr/local/bin/wslb-agent";
pub const first_uid = "1000";

pub const Options = struct {
    user: []const u8,
    /// 已有 uid 1000 用户时忽略
    password: []const u8 = "",
    net_distro: []const u8 = "wslb-net",
    wsl_exe: []const u8 = "/mnt/c/Windows/System32/wsl.exe",
    identity: Config.Identity = .{},
    upgrade: bool = true,
    firefox: ?firefox.Options = null,
    hide_claude: bool = false,
};

pub const Protection = union(enum) {
    guard,
    foreign: []const u8,
};

/// 联网前确认流量不会直连 守护进程在或者另一套 kill-switch 在
pub fn protection(gpa: std.mem.Allocator) !Protection {
    if (Control.alive()) {
        return .guard;
    }
    var sock = try netlink.Socket.open(0);
    defer sock.close();
    if (try Guard.foreignPresent(gpa, &sock, .{})) |name| {
        return .{ .foreign = name };
    }
    return error.Unprotected;
}

pub fn run(ctx: *Ctx, opts: Options) !void {
    ctx.step("检查网络防护", .{});
    switch (try protection(ctx.gpa)) {
        .guard => ctx.ok("网络发行版的守护进程在运行", .{}),
        .foreign => |name| ctx.ok("由另一套 kill-switch {s} 保护", .{name}),
    }
    ctx.ok("发行版 {s}", .{ctx.os.id});

    const user = try ensureUser(ctx, opts);
    try writeWslConf(ctx, user);
    try writeDns(ctx);

    ctx.step("系统更新与基础包", .{});
    try ctx.apt(&.{"update"});
    if (opts.upgrade) {
        try ctx.apt(&.{"full-upgrade"});
    }
    try ctx.apt(try std.mem.concat(ctx.arena, []const u8, &.{ &.{"install"}, &base_packages }));
    ctx.ok("{s}", .{try std.mem.join(ctx.arena, " ", &base_packages)});

    ctx.step("开机防护与身份服务", .{});
    try installAgent(ctx);
    var cfg = (try Config.load(ctx.io, ctx.arena, "/etc/wslb/" ++ Config.file_name)).value;
    cfg.net_distro = opts.net_distro;
    cfg.wsl_exe = opts.wsl_exe;
    cfg.identity = opts.identity;
    try fsx.ensureDir(ctx.io, "/etc/wslb");
    try cfg.save(ctx.io, ctx.gpa, "/etc/wslb/" ++ Config.file_name);
    try ctx.enableUnit("wslb-boot.service", @embedFile("assets/wslb-boot.service"), "sysinit.target");
    try ctx.enableUnit("wslb-link.service", @embedFile("assets/wslb-link.service"), "multi-user.target");
    try ctx.enableUnit("wslb-identity.service", @embedFile("assets/wslb-identity.service"), "sysinit.target");
    try ctx.enableUnit("wslb-identity-refresh.service", @embedFile("assets/wslb-identity-refresh.service"), "multi-user.target");
    ctx.ok("wslb-boot wslb-link wslb-identity 已设为开机启动", .{});

    if (opts.firefox) |ff| {
        var o = ff;
        o.locale = opts.identity.locale;
        try firefox.install(ctx, user, o);
    }
    if (opts.hide_claude) {
        try hide_claude.install(ctx);
    }

    ctx.step("时区 语言 对时", .{});
    try identity.apply(ctx.gpa, ctx.io, "", opts.identity);
    identity.activate(ctx, opts.identity);
    const plan = identity.Plan.of(opts.identity);
    ctx.ok("时区 {s}  语言 {s}  对时 {s}", .{ plan.timezone orelse "交还 Windows", plan.locale orelse "不管理", if (plan.ntp) "NTS" else "不管理" });
}

/// 已有 uid 1000 就沿用 发行版自己的首次启动向导看到它就会跳过
fn ensureUser(ctx: *Ctx, opts: Options) ![]const u8 {
    ctx.step("默认用户", .{});
    if (try userByUid(ctx, first_uid)) |existing| {
        ctx.ok("沿用已有用户 {s}", .{existing});
        return existing;
    }
    if (!validUserName(opts.user)) {
        return error.InvalidUserName;
    }
    if (opts.password.len == 0) {
        return error.PasswordRequired;
    }
    try ctx.run(&.{ "useradd", "-m", "-u", first_uid, "-s", "/bin/bash", "-G", ctx.os.user_groups, opts.user });
    try ctx.runStdin(&.{"chpasswd"}, try ctx.arena.print("{s}:{s}\n", .{ opts.user, opts.password }));
    ctx.ok("已创建 {s} 加入 {s}", .{ opts.user, ctx.os.user_groups });
    return opts.user;
}

pub fn userByUid(ctx: *Ctx, uid: []const u8) !?[]const u8 {
    const passwd = (try fsx.readOptional(ctx.io, ctx.arena, "/etc/passwd", 1 << 20)) orelse return null;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.first();
        _ = f.next();
        if (std.mem.eql(u8, f.next() orelse "", uid)) {
            return name;
        }
    }
    return null;
}

pub fn validUserName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) {
        return false;
    }
    if (!std.ascii.isLower(name[0]) and name[0] != '_') {
        return false;
    }
    for (name[1..]) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') {
            return false;
        }
    }
    return true;
}

fn writeWslConf(ctx: *Ctx, user: []const u8) !void {
    ctx.step("/etc/wsl.conf", .{});
    var text: []const u8 = (try fsx.readOptional(ctx.io, ctx.arena, "/etc/wsl.conf", 1 << 16)) orelse "";
    const keys = [_][3][]const u8{
        .{ "boot", "systemd", "true" },
        .{ "user", "default", user },
        .{ "network", "generateHosts", "true" },
        .{ "network", "generateResolvConf", "false" },
        .{ "interop", "enabled", "true" },
        .{ "interop", "appendWindowsPath", "true" },
    };
    for (keys) |k| {
        text = try ini.set(ctx.arena, text, k[0], k[1], k[2]);
    }
    try ctx.write("/etc/wsl.conf", text, 0o644);
    ctx.ok("systemd 默认用户 {s} resolv.conf 不再由 WSL 生成", .{user});
}

/// 解析都被网络发行版的 sing-box 劫持 这里的地址只是让查询进隧道
fn writeDns(ctx: *Ctx) !void {
    ctx.step("DNS", .{});
    const locked = try fsx.setImmutable("/etc/resolv.conf", false);
    std.Io.Dir.cwd().deleteFile(ctx.io, "/etc/resolv.conf") catch {};
    try ctx.write("/etc/resolv.conf", "nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0 timeout:2 attempts:2\n", 0o644);
    if (locked) {
        _ = try fsx.setImmutable("/etc/resolv.conf", true);
        ctx.ok("原文件带 chattr +i 写入后照原样锁定", .{});
    }
    if (fsx.exists(ctx.io, "/etc/systemd")) {
        try ctx.write("/etc/systemd/resolved.conf.d/wslb.conf", @embedFile("assets/resolved.conf"), 0o644);
    }
    ctx.ok("resolv.conf 固定", .{});
}

/// 管理器先把二进制推到 agent_path 再调用 provision 已在原位就不复制
fn installAgent(ctx: *Ctx) !void {
    var buf: [512]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(ctx.io, "/proc/self/exe", &buf) catch return error.NoSelfExe;
    const self = buf[0..n];
    if (std.mem.eql(u8, self, agent_path)) {
        return;
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(ctx.io, self, ctx.arena, .limited(64 << 20));
    try ctx.write(agent_path, data, 0o755);
}

test "user names" {
    try std.testing.expect(validUserName("alice"));
    try std.testing.expect(validUserName("a_1-b"));
    try std.testing.expect(!validUserName("Alice"));
    try std.testing.expect(!validUserName("1abc"));
    try std.testing.expect(!validUserName(""));
}
