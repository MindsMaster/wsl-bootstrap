const std = @import("std");
const Log = @import("Log.zig");
const Runner = @import("Runner.zig");

const Wsl = @This();
const Allocator = std.mem.Allocator;

pub const net_distro = "wslb-net";
pub const agent_path = "/usr/local/bin/wslb-agent";

/// 可安装的用户发行版 名字与 wsl --list --online 一致
pub const catalog = [_]struct { id: []const u8, label: []const u8 }{
    .{ .id = "Ubuntu-26.04", .label = "Ubuntu 26.04 LTS" },
    .{ .id = "Ubuntu-24.04", .label = "Ubuntu 24.04 LTS" },
    .{ .id = "Debian", .label = "Debian 13" },
};

pub const State = enum { running, stopped, installing, other };

pub const Distro = struct {
    name: []const u8,
    state: State,
    version: u8,
    default: bool,

    /// 网络发行版和 Docker 的发行版不当成用户系统
    pub fn isUser(d: Distro) bool {
        return !std.mem.eql(u8, d.name, net_distro) and !std.mem.startsWith(u8, d.name, "docker-desktop");
    }
};

pub const Version = struct {
    wsl: []const u8 = "",
    kernel: []const u8 = "",
};

runner: Runner,
exe: []const u8 = "wsl.exe",

pub fn version(w: Wsl, arena: Allocator) !?Version {
    const r = try w.runner.run(arena, &.{ w.exe, "--version" }, null);
    if (!r.ok()) {
        return null;
    }
    return parseVersion(r.stdout);
}

/// 标签随系统语言变化 只按行序取版本号 第一行 WSL 第二行内核
fn parseVersion(text: []const u8) Version {
    var v: Version = .{};
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        const value = std.mem.trim(u8, afterColon(line) orelse continue, " \t");
        switch (i) {
            0 => v.wsl = value,
            1 => v.kernel = value,
            else => break,
        }
    }
    return v;
}

/// 中文系统里可能是全角冒号
fn afterColon(line: []const u8) ?[]const u8 {
    if (std.mem.lastIndexOf(u8, line, "：")) |i| {
        return line[i + "：".len ..];
    }
    const i = std.mem.lastIndexOfScalar(u8, line, ':') orelse return null;
    return line[i + 1 ..];
}

pub fn list(w: Wsl, arena: Allocator) ![]Distro {
    const r = try w.runner.run(arena, &.{ w.exe, "--list", "--verbose" }, null);
    if (!r.ok()) {
        return &.{};
    }
    return parseList(arena, r.stdout);
}

fn parseList(arena: Allocator, text: []const u8) ![]Distro {
    var out: std.ArrayList(Distro) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        var first = tok.next() orelse continue;
        const default = std.mem.eql(u8, first, "*");
        if (default) {
            first = tok.next() orelse continue;
        }
        const state_text = tok.next() orelse continue;
        const ver = tok.next() orelse "2";
        try out.append(arena, .{
            .name = first,
            .state = if (std.ascii.eqlIgnoreCase(state_text, "Running"))
                .running
            else if (std.ascii.eqlIgnoreCase(state_text, "Stopped"))
                .stopped
            else if (std.ascii.eqlIgnoreCase(state_text, "Installing"))
                .installing
            else
                .other,
            .version = std.fmt.parseInt(u8, ver, 10) catch 2,
            .default = default,
        });
    }
    return out.items;
}

pub fn find(distros: []const Distro, name: []const u8) ?Distro {
    for (distros) |d| {
        if (std.mem.eql(u8, d.name, name)) {
            return d;
        }
    }
    return null;
}

/// 在发行版里以 root 运行 输出写进日志
pub fn exec(w: Wsl, log: *Log, distro: []const u8, argv: []const []const u8, input: ?[]const u8) !u32 {
    var buf: [32][]const u8 = undefined;
    const full = execArgv(&buf, w.exe, distro, argv);
    return w.runner.stream(full, input, log);
}

pub fn capture(w: Wsl, arena: Allocator, distro: []const u8, argv: []const []const u8, input: ?[]const u8) !Runner.Result {
    var buf: [32][]const u8 = undefined;
    return w.runner.run(arena, execArgv(&buf, w.exe, distro, argv), input);
}

fn execArgv(buf: *[32][]const u8, exe: []const u8, distro: []const u8, argv: []const []const u8) []const []const u8 {
    const head = [_][]const u8{ exe, "-d", distro, "-u", "root", "--exec" };
    @memcpy(buf[0..head.len], &head);
    const n = @min(argv.len, buf.len - head.len);
    @memcpy(buf[head.len..][0..n], argv[0..n]);
    return buf[0 .. head.len + n];
}

/// 二进制经标准输入写进发行版 不依赖 /mnt 自动挂载
pub fn push(w: Wsl, log: *Log, distro: []const u8, path: []const u8, data: []const u8, mode: []const u8) !void {
    var buf: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "mkdir -p \"$(dirname '{s}')\" && cat > '{s}.part' && chmod {s} '{s}.part' && mv -f '{s}.part' '{s}'", .{ path, path, mode, path, path, path });
    const code = try w.exec(log, distro, &.{ "/bin/sh", "-c", script }, data);
    if (code != 0) {
        return error.PushFailed;
    }
}

pub fn simple(w: Wsl, log: *Log, args: []const []const u8) !u32 {
    var buf: [16][]const u8 = undefined;
    buf[0] = w.exe;
    @memcpy(buf[1..][0..args.len], args);
    return w.runner.stream(buf[0 .. args.len + 1], null, log);
}

pub fn terminate(w: Wsl, log: *Log, name: []const u8) !u32 {
    return w.simple(log, &.{ "--terminate", name });
}

pub fn shutdown(w: Wsl, log: *Log) !u32 {
    return w.simple(log, &.{"--shutdown"});
}

pub fn setDefault(w: Wsl, log: *Log, name: []const u8) !u32 {
    return w.simple(log, &.{ "--set-default", name });
}

pub fn unregister(w: Wsl, log: *Log, name: []const u8) !u32 {
    return w.simple(log, &.{ "--unregister", name });
}

pub fn exportTo(w: Wsl, log: *Log, name: []const u8, file: []const u8) !u32 {
    return w.simple(log, &.{ "--export", name, file });
}

pub fn importFrom(w: Wsl, log: *Log, name: []const u8, dir: []const u8, file: []const u8) !u32 {
    return w.simple(log, &.{ "--import", name, dir, file, "--version", "2" });
}

/// 商店下载失败时改走 GitHub 直链
pub fn install(w: Wsl, log: *Log, distro: []const u8, name: []const u8, location: []const u8) !void {
    const base = [_][]const u8{ "--install", distro, "--name", name, "--location", location, "--no-launch" };
    if (try w.simple(log, &base) == 0) {
        return;
    }
    log.add("安装失败 改用 --web-download 重试");
    if (try w.simple(log, &(base ++ .{"--web-download"})) != 0) {
        return error.InstallFailed;
    }
}

test "parse version and list" {
    const v = parseVersion("WSL 版本: 2.9.13.0\r\n内核版本: 6.18.40.1-1\r\nWSLg 版本: 1.0.79\r\n");
    try std.testing.expectEqualStrings("2.9.13.0", v.wsl);
    try std.testing.expectEqualStrings("6.18.40.1-1", v.kernel);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ds = try parseList(arena.allocator(), "  NAME              STATE           VERSION\r\n* Ubuntu-26.04      Running         2\r\n  docker-desktop    Stopped         2\r\n");
    try std.testing.expectEqual(@as(usize, 2), ds.len);
    try std.testing.expect(ds[0].default and ds[0].state == .running);
    try std.testing.expect(!ds[1].isUser());
}

test "exec argv runs as root" {
    var buf: [32][]const u8 = undefined;
    const argv = execArgv(&buf, "wsl.exe", "Debian", &.{ "wslb-agent", "status" });
    const line = try std.mem.join(std.testing.allocator, " ", argv);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("wsl.exe -d Debian -u root --exec wslb-agent status", line);
}
