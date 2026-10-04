const std = @import("std");
const Ctx = @import("Ctx.zig");

const unit = "hide-windows-claude.service";
const script = "/usr/local/sbin/hide-windows-claude";

/// 用只读空占位挂到 /mnt/*/Users/*/.claude 等处 Windows 侧原文件不动
pub fn install(ctx: *Ctx) !void {
    ctx.step("隐藏 Windows 侧 Claude Code 数据", .{});
    try ctx.write(script, @embedFile("assets/hide-windows-claude"), 0o755);
    try ctx.enableUnit(unit, @embedFile("assets/hide-windows-claude.service"), "multi-user.target");
    ctx.ok("下次启动发行版后生效", .{});
}

pub fn remove(ctx: *Ctx) void {
    ctx.disableUnit(unit, "multi-user.target");
    ctx.remove(script);
    ctx.ok("已移除 下次启动发行版后不再遮蔽", .{});
}
