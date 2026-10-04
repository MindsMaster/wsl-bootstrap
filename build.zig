const std = @import("std");

pub fn build(b: *std.Build) void {
    // glibc 2.36 对应 Debian 12 运行时 dlopen 系统的 libnftables
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 36, .patch = 0 } },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "版本号") orelse "0.1.0-dev");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "wsl-egress", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "运行 wsl-egress").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "单元测试").dependOn(&b.addRunArtifact(tests).step);
}
