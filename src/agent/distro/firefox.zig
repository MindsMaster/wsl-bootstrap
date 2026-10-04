const std = @import("std");
const Ctx = @import("Ctx.zig");
const fsx = @import("../fsx.zig");

const Allocator = std.mem.Allocator;

/// 与 identity.zig 写入 intl 偏好的目录一致
pub const pref_dir = "/usr/lib/firefox/defaults/pref";
const keyring = "/etc/apt/keyrings/packages.mozilla.org.asc";
/// Mozilla 公布的 APT 签名密钥指纹 换密钥时同步更新 mozilla-repo-signing-key.asc
const key_fingerprint = "35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3";
const repo_key = @embedFile("assets/mozilla-repo-signing-key.asc");

const aliases_begin = "# >>> wslb firefox >>>";
const aliases_end = "# <<< wslb firefox <<<";

pub const Options = struct {
    /// Mesa D3D12 适配器名 按子串匹配 空串交给 Mesa 选
    gpu: []const u8 = "",
    webrtc_noleak: bool = true,
    /// 语言包跟随 identity 的 locale
    locale: []const u8 = "",
};

pub fn install(ctx: *Ctx, user: []const u8, opts: Options) !void {
    ctx.step("Firefox 接入 Mozilla 官方 APT 源", .{});
    try ctx.os.blockDistroFirefox(ctx);
    try ctx.write(keyring, repo_key, 0o644);
    try ctx.write("/etc/apt/sources.list.d/mozilla.sources",
        \\Types: deb
        \\URIs: https://packages.mozilla.org/apt
        \\Suites: mozilla
        \\Components: main
        \\Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
        \\
    , 0o644);
    try ctx.write("/etc/apt/preferences.d/mozilla", "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n", 0o644);
    ctx.ok("签名密钥 {s}", .{key_fingerprint});

    ctx.step("Firefox 安装", .{});
    try ctx.apt(&.{"update"});
    var pkgs: std.ArrayList([]const u8) = .empty;
    try pkgs.append(ctx.arena, "firefox");
    if (try l10nPackage(ctx, opts.locale)) |p| {
        try pkgs.append(ctx.arena, p);
    }
    const args = try std.mem.concat(ctx.arena, []const u8, &.{ &.{ "install", "--allow-downgrades" }, pkgs.items });
    try ctx.apt(args);
    var link_buf: [256]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(ctx.io, "/usr/bin/firefox", &link_buf) catch 0;
    const target = link_buf[0..n];
    if (!std.mem.startsWith(u8, target, "/usr/lib/firefox/") and !std.mem.startsWith(u8, target, "../lib/firefox/")) {
        return error.NotMozillaFirefox;
    }
    ctx.ok("Mozilla deb 版已安装 {s}", .{pkgs.items[pkgs.items.len - 1]});

    ctx.step("Firefox WSLg 显示与 GPU", .{});
    try ctx.write(pref_dir ++ "/wslg-prefs.js", @embedFile("assets/wslg-prefs.js"), 0o644);
    if (opts.webrtc_noleak) {
        try ctx.write(pref_dir ++ "/webrtc-noleak.js", @embedFile("assets/webrtc-noleak.js"), 0o644);
    } else {
        ctx.remove(pref_dir ++ "/webrtc-noleak.js");
    }
    const adapter = if (opts.gpu.len != 0)
        try ctx.arena.print("export MESA_D3D12_DEFAULT_ADAPTER_NAME={s}", .{opts.gpu})
    else
        "# MESA_D3D12_DEFAULT_ADAPTER_NAME 未设置 由 Mesa 选择";
    const gpu_env = try std.mem.replaceOwned(u8, ctx.arena, @embedFile("assets/wslg-gpu.sh.in"), "@ADAPTER_LINE@", adapter);
    try ctx.write("/etc/profile.d/wslg-gpu.sh", gpu_env, 0o644);
    try ctx.write("/usr/local/bin/wsl-firefox", @embedFile("assets/wsl-firefox"), 0o755);
    try linkUser(ctx, user);
    ctx.ok("软件 WebRender 加 D3D12 WebGL {s}", .{if (opts.gpu.len != 0) opts.gpu else "自动选卡"});
}

/// 交互终端里的 firefox 和开始菜单入口都走启动器 GPU 环境总会生效
fn linkUser(ctx: *Ctx, user: []const u8) !void {
    const home = try homeOf(ctx, user);
    const aliases_path = try ctx.arena.print("{s}/.bash_aliases", .{home});
    const old = (try fsx.readOptional(ctx.io, ctx.arena, aliases_path, 1 << 20)) orelse "";
    const block =
        aliases_begin ++ "\n" ++
        \\firefox() { /usr/local/bin/wsl-firefox "$@"; }
        \\_firefox_complete() {
        \\  case "${COMP_WORDS[COMP_CWORD-1]}" in
        \\    -P|-p|--shortcut) COMPREPLY=($(compgen -W "$(wsl-firefox --profiles 2>/dev/null)" -- "${COMP_WORDS[COMP_CWORD]}")) ;;
        \\  esac
        \\}
        \\complete -o default -F _firefox_complete firefox
        \\
        ++ aliases_end ++ "\n";
    try ctx.write(aliases_path, try replaceBlock(ctx.arena, old, block), 0o644);

    const desktop_src = (try fsx.readOptional(ctx.io, ctx.arena, "/usr/share/applications/firefox.desktop", 1 << 20)) orelse "";
    if (desktop_src.len != 0) {
        const desktop = try std.mem.replaceOwned(u8, ctx.arena, desktop_src, "Exec=firefox", "Exec=/usr/local/bin/wsl-firefox");
        try ctx.write(try ctx.arena.print("{s}/.local/share/applications/firefox.desktop", .{home}), desktop, 0o644);
    }
    try ctx.run(&.{ "chown", "-R", try ctx.arena.print("{s}:", .{user}), aliases_path, try ctx.arena.print("{s}/.local", .{home}) });
}

pub fn remove(ctx: *Ctx, user: []const u8) !void {
    ctx.step("移除 Firefox", .{});
    try ctx.apt(&.{ "remove", "firefox" });
    for ([_][]const u8{ "/etc/apt/sources.list.d/mozilla.sources", "/etc/apt/preferences.d/mozilla", keyring, "/etc/profile.d/wslg-gpu.sh", "/usr/local/bin/wsl-firefox" }) |p| {
        ctx.remove(p);
    }
    const home = try homeOf(ctx, user);
    const aliases_path = try ctx.arena.print("{s}/.bash_aliases", .{home});
    if (try fsx.readOptional(ctx.io, ctx.arena, aliases_path, 1 << 20)) |old| {
        try ctx.write(aliases_path, try replaceBlock(ctx.arena, old, ""), 0o644);
    }
    ctx.remove(try ctx.arena.print("{s}/.local/share/applications/firefox.desktop", .{home}));
    ctx.ok("已移除", .{});
}

pub fn homeOf(ctx: *Ctx, user: []const u8) ![]const u8 {
    const passwd = (try fsx.readOptional(ctx.io, ctx.arena, "/etc/passwd", 1 << 20)) orelse return error.NoPasswd;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        if (!std.mem.eql(u8, fields.first(), user)) {
            continue;
        }
        var i: usize = 1;
        while (fields.next()) |f| : (i += 1) {
            if (i == 5) {
                return f;
            }
        }
    }
    return error.NoSuchUser;
}

/// zh_CN.UTF-8 先找 firefox-l10n-zh-cn 再找 firefox-l10n-zh
fn l10nPackage(ctx: *Ctx, locale: []const u8) !?[]const u8 {
    if (locale.len == 0 or std.mem.startsWith(u8, locale, "en_US")) {
        return null;
    }
    const base = locale[0 .. std.mem.indexOfAny(u8, locale, ".@") orelse locale.len];
    const tag = try ctx.arena.dupe(u8, base);
    for (tag) |*c| {
        c.* = if (c.* == '_') '-' else std.ascii.toLower(c.*);
    }
    const full = try ctx.arena.print("firefox-l10n-{s}", .{tag});
    if (ctx.succeeds(&.{ "apt-cache", "show", full })) {
        return full;
    }
    const short = try ctx.arena.print("firefox-l10n-{s}", .{tag[0 .. std.mem.indexOfScalar(u8, tag, '-') orelse tag.len]});
    if (ctx.succeeds(&.{ "apt-cache", "show", short })) {
        return short;
    }
    return null;
}

/// 替换或追加由 begin end 两行包住的块 block 为空则删除
fn replaceBlock(a: Allocator, text: []const u8, block: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var inside = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) {
            break;
        }
        if (std.mem.eql(u8, line, aliases_begin)) {
            inside = true;
            continue;
        }
        if (inside) {
            if (std.mem.eql(u8, line, aliases_end)) {
                inside = false;
            }
            continue;
        }
        try out.writer.print("{s}\n", .{line});
    }
    try out.writer.writeAll(block);
    return out.written();
}

/// v4 公钥指纹 SHA1(0x99 长度 公钥包体)
fn keyFingerprint(a: Allocator, armored: []const u8) ![20]u8 {
    var b64: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, armored, '\n');
    var in_body = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (!in_body) {
            in_body = line.len == 0;
            continue;
        }
        if (line.len == 0 or line[0] == '=' or line[0] == '-') {
            break;
        }
        try b64.appendSlice(a, line);
    }
    const dec = std.base64.standard.Decoder;
    const bin = try a.alloc(u8, try dec.calcSizeForSlice(b64.items));
    try dec.decode(bin, b64.items);
    if (bin.len < 3 or bin[0] & 0xc0 != 0xc0 or bin[0] & 0x3f != 6) {
        return error.NotPublicKey;
    }
    const len: usize, const off: usize = if (bin[1] < 192)
        .{ bin[1], 2 }
    else
        .{ (@as(usize, bin[1]) - 192) * 256 + bin[2] + 192, 3 };
    const body = bin[off..][0..len];
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(&.{ 0x99, @intCast(len >> 8), @intCast(len & 0xff) });
    h.update(body);
    return h.finalResult();
}

test "embedded mozilla key matches pinned fingerprint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fp = try keyFingerprint(arena.allocator(), repo_key);
    const hex = std.fmt.bytesToHex(fp, .upper);
    try std.testing.expectEqualStrings(key_fingerprint, &hex);
}

test "aliases block replaced not duplicated" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const once = try replaceBlock(a, "alias ll='ls -l'\n", aliases_begin ++ "\nX\n" ++ aliases_end ++ "\n");
    const twice = try replaceBlock(a, once, aliases_begin ++ "\nY\n" ++ aliases_end ++ "\n");
    try std.testing.expectEqualStrings("alias ll='ls -l'\n" ++ aliases_begin ++ "\nY\n" ++ aliases_end ++ "\n", twice);
    try std.testing.expectEqualStrings("alias ll='ls -l'\n", try replaceBlock(a, twice, ""));
}
