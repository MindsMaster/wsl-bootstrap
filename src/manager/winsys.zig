const std = @import("std");
const builtin = @import("builtin");
const Runner = @import("Runner.zig");

const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

const win = if (is_windows) struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;

    const SEE_MASK_NOCLOSEPROCESS: u32 = 0x40;
    const SW_SHOWNORMAL: i32 = 1;
    const INFINITE: u32 = 0xffffffff;

    const ShellExecuteInfo = extern struct {
        size: u32 = @sizeOf(ShellExecuteInfo),
        mask: u32 = 0,
        hwnd: ?*anyopaque = null,
        verb: ?[*:0]const u16 = null,
        file: ?[*:0]const u16 = null,
        params: ?[*:0]const u16 = null,
        dir: ?[*:0]const u16 = null,
        show: i32 = SW_SHOWNORMAL,
        inst: ?*anyopaque = null,
        id_list: ?*anyopaque = null,
        class: ?[*:0]const u16 = null,
        key_class: ?*anyopaque = null,
        hotkey: u32 = 0,
        icon: ?*anyopaque = null,
        process: ?HANDLE = null,
    };

    const MemoryStatus = extern struct {
        length: u32 = @sizeOf(MemoryStatus),
        load: u32 = 0,
        total_phys: u64 = 0,
        avail_phys: u64 = 0,
        total_page: u64 = 0,
        avail_page: u64 = 0,
        total_virtual: u64 = 0,
        avail_virtual: u64 = 0,
        avail_ext: u64 = 0,
    };

    extern "shell32" fn ShellExecuteExW(info: *ShellExecuteInfo) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GlobalMemoryStatusEx(s: *MemoryStatus) callconv(.winapi) BOOL;
    extern "user32" fn OpenClipboard(owner: ?*anyopaque) callconv(.winapi) BOOL;
    extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
    extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GlobalLock(h: HANDLE) callconv(.winapi) ?[*:0]const u16;
    extern "kernel32" fn GlobalUnlock(h: HANDLE) callconv(.winapi) BOOL;
    const CF_UNICODETEXT: u32 = 13;
} else struct {};

fn wide(a: Allocator, s: []const u8) ![:0]const u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s);
}

/// 弹 UAC 以管理员身份运行并等它结束 用户拒绝时返回 error.Cancelled
pub fn runElevated(a: Allocator, file: []const u8, params: []const u8) !u32 {
    if (!is_windows) {
        return error.Unsupported;
    }
    var info: win.ShellExecuteInfo = .{
        .mask = win.SEE_MASK_NOCLOSEPROCESS,
        .verb = try wide(a, "runas"),
        .file = try wide(a, file),
        .params = try wide(a, params),
    };
    if (win.ShellExecuteExW(&info) == .FALSE) {
        return error.Cancelled;
    }
    const h = info.process orelse return 0;
    defer _ = win.CloseHandle(h);
    _ = win.WaitForSingleObject(h, win.INFINITE);
    var code: u32 = 0;
    _ = win.GetExitCodeProcess(h, &code);
    return code;
}

/// 新开一个控制台窗口进入发行版 不占用管理器的终端
pub fn openShell(a: Allocator, distro: []const u8) !void {
    if (!is_windows) {
        return error.Unsupported;
    }
    var info: win.ShellExecuteInfo = .{
        .verb = try wide(a, "open"),
        .file = try wide(a, "wsl.exe"),
        .params = try wide(a, try std.fmt.allocPrint(a, "-d {s} --cd ~", .{distro})),
    };
    if (win.ShellExecuteExW(&info) == .FALSE) {
        return error.LaunchFailed;
    }
}

/// 网址和 mailto 交给系统默认程序
pub fn openUrl(a: Allocator, url: []const u8) !void {
    if (!is_windows) {
        return error.Unsupported;
    }
    var info: win.ShellExecuteInfo = .{
        .verb = try wide(a, "open"),
        .file = try wide(a, url),
    };
    if (win.ShellExecuteExW(&info) == .FALSE) {
        return error.LaunchFailed;
    }
}

/// 剪贴板里的文字 没有文字时返回空
pub fn clipboardText(a: Allocator) ![]const u8 {
    if (!is_windows) {
        return error.Unsupported;
    }
    if (win.OpenClipboard(null) == .FALSE) {
        return error.ClipboardBusy;
    }
    defer _ = win.CloseClipboard();
    const h = win.GetClipboardData(win.CF_UNICODETEXT) orelse return "";
    const ptr = win.GlobalLock(h) orelse return "";
    defer _ = win.GlobalUnlock(h);
    return std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(ptr));
}

pub fn memoryGb() u64 {
    if (!is_windows) {
        return 16;
    }
    var st: win.MemoryStatus = .{};
    if (win.GlobalMemoryStatusEx(&st) == .FALSE) {
        return 16;
    }
    return st.total_phys >> 30;
}

/// 显卡名用于 Mesa D3D12 选卡 查不到返回空
pub fn gpuNames(runner: Runner, a: Allocator) []const u8 {
    const r = runner.run(a, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "(Get-CimInstance Win32_VideoController).Name -join ', '" }, null) catch return "";
    return std.mem.trim(u8, r.stdout, " \r\n");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) {
        return false;
    }
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) {
            return true;
        }
    }
    return false;
}

/// 从显卡名猜 Mesa 适配器子串
pub fn gpuVendor(names: []const u8) []const u8 {
    for ([_][]const u8{ "NVIDIA", "AMD", "Intel" }) |v| {
        if (containsIgnoreCase(names, v)) {
            return v;
        }
    }
    if (containsIgnoreCase(names, "Radeon")) {
        return "AMD";
    }
    return "";
}

/// Windows 盘符路径换成 /mnt 下的路径 C:\Windows → /mnt/c/Windows
pub fn mntPath(a: Allocator, path: []const u8) ![]const u8 {
    if (path.len < 2 or path[1] != ':') {
        return error.NotDrivePath;
    }
    const rest = try std.mem.replaceOwned(u8, a, path[2..], "\\", "/");
    return std.fmt.allocPrint(a, "/mnt/{c}{s}", .{ std.ascii.toLower(path[0]), rest });
}

const run_key = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const run_value = "wslb-net";

/// 登录时在后台连住网络发行版 conhost --headless 不弹窗口
pub fn setAutostart(runner: Runner, a: Allocator, system_root: []const u8, on: bool) !void {
    if (!on) {
        _ = try runner.run(a, &.{ "reg.exe", "delete", run_key, "/v", run_value, "/f" }, null);
        return;
    }
    const cmd = try std.fmt.allocPrint(a, "\"{s}\\System32\\conhost.exe\" --headless \"{s}\\System32\\wsl.exe\" -d wslb-net -u root --exec /usr/local/bin/wslb-agent hold", .{ system_root, system_root });
    const r = try runner.run(a, &.{ "reg.exe", "add", run_key, "/v", run_value, "/t", "REG_SZ", "/d", cmd, "/f" }, null);
    if (!r.ok()) {
        return error.RegistryFailed;
    }
}

pub fn autostartEnabled(runner: Runner, a: Allocator) bool {
    const r = runner.run(a, &.{ "reg.exe", "query", run_key, "/v", run_value }, null) catch return false;
    return r.ok();
}

const tcpip6_key = "HKLM\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters";

/// 没有这个值时返回 null
pub fn ipv6DisabledComponents(runner: Runner, a: Allocator) ?u32 {
    const r = runner.run(a, &.{ "reg.exe", "query", tcpip6_key, "/v", "DisabledComponents" }, null) catch return null;
    if (!r.ok()) {
        return null;
    }
    return parseRegDword(r.stdout);
}

/// reg query 输出的最后一列 如 0xff
fn parseRegDword(text: []const u8) ?u32 {
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var last: []const u8 = "";
    while (tokens.next()) |t| {
        last = t;
    }
    return std.fmt.parseInt(u32, last, 0) catch null;
}

test "reg dword" {
    try std.testing.expectEqual(@as(?u32, 0xff), parseRegDword("\r\nHKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters\r\n    DisabledComponents    REG_DWORD    0xff\r\n\r\n"));
    try std.testing.expectEqual(@as(?u32, null), parseRegDword(""));
}

test "mnt path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/mnt/c/Windows/System32/wsl.exe", try mntPath(arena.allocator(), "C:\\Windows\\System32\\wsl.exe"));
    try std.testing.expectEqualStrings("NVIDIA", gpuVendor("Intel(R) UHD, NVIDIA GeForce RTX 4070"));
}
