const std = @import("std");
const Ctx = @import("../Ctx.zig");
const Os = @import("../Os.zig");

pub const os: Os = .{
    .id = "ubuntu",
    .user_groups = "adm,cdrom,sudo,dip,plugdev",
    .generateLocale = generateLocale,
    .blockDistroFirefox = blockDistroFirefox,
};

/// Ubuntu 的 locale-gen 接受参数 并记到 /var/lib/locales/supported.d
fn generateLocale(ctx: *Ctx, locale: []const u8) !void {
    try ctx.run(&.{ "locale-gen", locale });
}

/// Ubuntu 的 firefox 包只是装 snap 的过渡包 snap 版在 WSLg 下拿不到 GPU
fn blockDistroFirefox(ctx: *Ctx) !void {
    if (ctx.succeeds(&.{ "snap", "list", "firefox" })) {
        try ctx.run(&.{ "snap", "remove", "--purge", "firefox" });
        ctx.ok("已移除 snap 版 firefox", .{});
    }
    try ctx.write("/etc/apt/preferences.d/firefox-no-ubuntu", "Package: firefox*\nPin: release o=Ubuntu\nPin-Priority: -1\n", 0o644);
    try ctx.write("/etc/apt/apt.conf.d/51unattended-upgrades-firefox", "Unattended-Upgrade::Package-Blacklist { \"firefox\"; };\n", 0o644);
    ctx.ok("已屏蔽 Ubuntu 的 snap 过渡包", .{});
}
