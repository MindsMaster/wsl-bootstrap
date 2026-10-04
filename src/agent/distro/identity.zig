const std = @import("std");
const Config = @import("Config.zig");
const fsx = @import("../fsx.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.identity);

/// 与 firefox 安装模块写入的 pref 目录一致
const firefox_pref_dir = "/usr/lib/firefox/defaults/pref";
const ntp_server = "time.cloudflare.com";

pub const Plan = struct {
    timezone: ?[]const u8,
    locale: ?[]const u8,
    ntp: bool,

    pub fn of(id: Config.Identity) Plan {
        const tz: ?[]const u8 = switch (id.timezone_mode) {
            .windows => null,
            // 出口时区查到之前用 UTC 不回落到 Windows 时区
            .auto => if (id.timezone.len != 0) id.timezone else "Etc/UTC",
            .fixed => if (id.timezone.len != 0) id.timezone else null,
        };
        return .{
            .timezone = tz,
            .locale = if (id.locale.len != 0) id.locale else null,
            .ntp = id.ntp,
        };
    }
};

pub fn validTimezone(io: Io, root: []const u8, tz: []const u8) bool {
    if (tz.len == 0 or std.mem.indexOf(u8, tz, "..") != null or tz[0] == '/') {
        return false;
    }
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/usr/share/zoneinfo/{s}", .{ root, tz }) catch return false;
    return fsx.exists(io, p);
}

/// en_US.UTF-8 转 en-US
pub fn langTag(buf: []u8, locale: []const u8) []const u8 {
    const base = locale[0 .. std.mem.indexOfAny(u8, locale, ".@") orelse locale.len];
    const n = @min(base.len, buf.len);
    @memcpy(buf[0..n], base[0..n]);
    for (buf[0..n]) |*c| {
        if (c.* == '_') {
            c.* = '-';
        }
    }
    return buf[0..n];
}

fn primaryLang(tag: []const u8) []const u8 {
    return tag[0 .. std.mem.indexOfScalar(u8, tag, '-') orelse tag.len];
}

const Writer = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,

    fn path(w: Writer, buf: []u8, p: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ w.root, p }) catch unreachable;
    }

    fn write(w: Writer, p: []const u8, data: []const u8) !void {
        var buf: [512]u8 = undefined;
        const full = w.path(&buf, p);
        if (std.fs.path.dirname(full)) |dir| {
            try fsx.ensureDir(w.io, dir);
        }
        try fsx.writeAtomic(w.io, w.gpa, full, data, 0o644);
    }

    fn remove(w: Writer, p: []const u8) void {
        var buf: [512]u8 = undefined;
        Io.Dir.cwd().deleteFile(w.io, w.path(&buf, p)) catch {};
    }

    fn editKeys(w: Writer, p: []const u8, keys: []const [2][]const u8) !void {
        var buf: [512]u8 = undefined;
        const old = (try fsx.readOptional(w.io, w.gpa, w.path(&buf, p), 1 << 20)) orelse try w.gpa.dupe(u8, "");
        defer w.gpa.free(old);
        const new = try fsx.setKeys(w.gpa, old, keys);
        defer w.gpa.free(new);
        if (!std.mem.eql(u8, old, new)) {
            try w.write(p, new);
        }
    }
};

/// 把时区 语言 对时同步到每一处会暴露它们的地方
pub fn apply(gpa: Allocator, io: Io, root: []const u8, id: Config.Identity) !void {
    const plan = Plan.of(id);
    const w: Writer = .{ .gpa = gpa, .io = io, .root = root };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    if (plan.timezone) |tz| {
        if (!validTimezone(io, root, tz)) {
            return error.UnknownTimezone;
        }
        try setLocaltime(w, a, tz);
        try w.write("/etc/timezone", try a.print("{s}\n", .{tz}));
    }
    try setWslTime(w, a, plan.timezone != null);

    var tag_buf: [32]u8 = undefined;
    const tag: ?[]const u8 = if (plan.locale) |l| langTag(&tag_buf, l) else null;
    const language: []const u8 = if (tag) |t| try a.print("{s}:{s}", .{ std.mem.replaceOwned(u8, a, t, "-", "_") catch t, primaryLang(t) }) else "";
    const tz_value: []const u8 = if (plan.timezone) |tz| tz else "";
    const locale_value: []const u8 = plan.locale orelse "";

    try w.editKeys("/etc/environment", &.{
        .{ "TZ", tz_value },
        .{ "LANG", locale_value },
        .{ "LANGUAGE", language },
        .{ "LC_ALL", locale_value },
    });
    if (plan.locale != null) {
        try w.editKeys("/etc/default/locale", &.{
            .{ "LANG", locale_value },
            .{ "LANGUAGE", language },
        });
    }

    var profile: std.Io.Writer.Allocating = .init(a);
    try profile.writer.writeAll("# wslb-agent identity 由 wslb-agent identity apply 生成\n");
    if (plan.timezone) |tz| {
        try profile.writer.print("export TZ={s}\n", .{tz});
    }
    if (plan.locale) |l| {
        try profile.writer.print("export LANG={s}\nexport LANGUAGE={s}\nexport LC_ALL={s}\n", .{ l, language, l });
    }
    // 流量已走 TUN 代理变量会让 Node 报 UnsupportedProxyProtocol
    try profile.writer.writeAll("unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY\n");
    try w.write("/etc/profile.d/wslb-identity.sh", profile.written());

    var manager: std.Io.Writer.Allocating = .init(a);
    try manager.writer.writeAll("[Manager]\nDefaultEnvironment=");
    if (plan.timezone) |tz| {
        try manager.writer.print("\"TZ={s}\" ", .{tz});
    }
    if (plan.locale) |l| {
        try manager.writer.print("\"LANG={s}\" \"LANGUAGE={s}\"", .{ l, language });
    }
    try manager.writer.writeAll("\n");
    if (plan.timezone != null or plan.locale != null) {
        try w.write("/etc/systemd/system.conf.d/wslb-identity.conf", manager.written());
        try w.write("/etc/systemd/user.conf.d/wslb-identity.conf", manager.written());
    } else {
        w.remove("/etc/systemd/system.conf.d/wslb-identity.conf");
        w.remove("/etc/systemd/user.conf.d/wslb-identity.conf");
    }

    var ff_buf: [512]u8 = undefined;
    if (tag == null) {
        w.remove(firefox_pref_dir ++ "/wslb-identity.js");
    } else if (fsx.exists(io, w.path(&ff_buf, firefox_pref_dir))) {
        const t = tag.?;
        try w.write(firefox_pref_dir ++ "/wslb-identity.js", try a.print(
            \\// wslb-agent identity 由 wslb-agent identity apply 生成
            \\pref("intl.accept_languages", "{s}, {s}");
            \\pref("intl.locale.requested", "{s}");
            \\pref("intl.regional_prefs.use_os_locales", false);
            \\
        , .{ t, primaryLang(t), t }));
    }

    var chrony_buf: [512]u8 = undefined;
    if (fsx.exists(io, w.path(&chrony_buf, "/etc/chrony"))) {
        if (plan.ntp) {
            try w.write("/etc/chrony/sources.d/wslb-agent.sources", "server " ++ ntp_server ++ " iburst nts\n");
        } else {
            w.remove("/etc/chrony/sources.d/wslb-agent.sources");
        }
    }

    if (root.len == 0) {
        if (plan.locale) |l| {
            ensureLocale(gpa, io, l);
        }
        if (plan.ntp) {
            runQuiet(gpa, io, &.{ "chronyc", "reload", "sources" });
        }
    }
}

fn setLocaltime(w: Writer, a: Allocator, tz: []const u8) !void {
    var buf: [512]u8 = undefined;
    const link = w.path(&buf, "/etc/localtime");
    const tmp = try a.print("{s}.wslb-agent", .{link});
    Io.Dir.cwd().deleteFile(w.io, tmp) catch {};
    try Io.Dir.cwd().symLink(w.io, try a.print("/usr/share/zoneinfo/{s}", .{tz}), tmp, .{});
    try Io.Dir.renameAbsolute(tmp, link, w.io);
}

/// wsl.conf 的 time.useWindowsTimezone 关掉后 WSL 开机不再拷入 Windows 时区
fn setWslTime(w: Writer, a: Allocator, managed: bool) !void {
    var buf: [512]u8 = undefined;
    const old = (try fsx.readOptional(w.io, a, w.path(&buf, "/etc/wsl.conf"), 1 << 16)) orelse "";
    const new = try setIni(a, old, "time", "useWindowsTimezone", if (managed) "false" else "true");
    if (!std.mem.eql(u8, old, new)) {
        try w.write("/etc/wsl.conf", new);
    }
}

pub fn setIni(a: Allocator, text: []const u8, section: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var in_section = false;
    var done = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) {
            break;
        }
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 1 and t[0] == '[' and t[t.len - 1] == ']') {
            if (in_section and !done) {
                try out.writer.print("{s}={s}\n", .{ key, value });
                done = true;
            }
            in_section = std.ascii.eqlIgnoreCase(t[1 .. t.len - 1], section);
        } else if (in_section and !done) {
            const eq = std.mem.indexOfScalar(u8, t, '=');
            if (eq) |i| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t[0..i], " \t"), key)) {
                    try out.writer.print("{s}={s}\n", .{ key, value });
                    done = true;
                    continue;
                }
            }
        }
        try out.writer.print("{s}\n", .{line});
    }
    if (!done) {
        if (in_section) {
            try out.writer.print("{s}={s}\n", .{ key, value });
        } else {
            if (out.written().len != 0) {
                try out.writer.writeAll("\n");
            }
            try out.writer.print("[{s}]\n{s}={s}\n", .{ section, key, value });
        }
    }
    return out.written();
}

fn runQuiet(gpa: Allocator, io: Io, argv: []const []const u8) void {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch return;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
}

fn ensureLocale(gpa: Allocator, io: Io, locale: []const u8) void {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "locale", "-a" } }) catch return;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    var want_buf: [64]u8 = undefined;
    const want = std.ascii.lowerString(&want_buf, locale[0..@min(locale.len, 64)]);
    // locale -a 输出 en_US.utf8 而配置写 en_US.UTF-8
    const norm = std.mem.replaceOwned(u8, gpa, want, "utf-8", "utf8") catch return;
    defer gpa.free(norm);
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        var have_buf: [64]u8 = undefined;
        const have = std.ascii.lowerString(&have_buf, line[0..@min(line.len, 64)]);
        if (std.mem.eql(u8, have, norm)) {
            return;
        }
    }
    log.info("生成 locale {s}", .{locale});
    runQuiet(gpa, io, &.{ "locale-gen", locale });
}

test "auto without resolved timezone pins UTC" {
    try std.testing.expectEqualStrings("Etc/UTC", Plan.of(.{ .timezone_mode = .auto }).timezone.?);
    try std.testing.expect(Plan.of(.{ .timezone_mode = .windows, .timezone = "Asia/Tokyo" }).timezone == null);
}

test "langTag" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("en-US", langTag(&buf, "en_US.UTF-8"));
    try std.testing.expectEqualStrings("de-DE", langTag(&buf, "de_DE@euro"));
}

test "setIni" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "[boot]\nsystemd=true\n\n[time]\nuseWindowsTimezone=false\n",
        try setIni(a, "[boot]\nsystemd=true\n", "time", "useWindowsTimezone", "false"),
    );
    try std.testing.expectEqualStrings(
        "[time]\nuseWindowsTimezone=true\n[user]\ndefault=a\n",
        try setIni(a, "[time]\nuseWindowsTimezone = false\n[user]\ndefault=a\n", "time", "useWindowsTimezone", "true"),
    );
}
