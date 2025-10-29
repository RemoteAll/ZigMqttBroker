const std = @import("std");
const builtin = @import("builtin");

/// 系统信息结构体
pub const SystemInfo = struct {
    /// 操作系统
    os_name: []const u8,
    /// CPU 架构
    cpu_arch: []const u8,
    /// CPU 核心数
    cpu_count: u32,
    /// 总内存（字节）
    total_memory: u64,
    /// 可用内存（字节）
    available_memory: u64,
    /// 主机名
    hostname: []const u8,
    /// Zig 版本
    zig_version: []const u8,
    /// 是否支持 io_uring
    supports_io_uring: bool,
};

/// 获取系统信息
pub fn getSystemInfo(allocator: std.mem.Allocator) !SystemInfo {
    const cpu_count = std.Thread.getCpuCount() catch 1;

    // 获取主机名
    var hostname_buffer: [256]u8 = undefined;
    const hostname = getHostname(&hostname_buffer) catch "unknown";
    const hostname_copy = try allocator.dupe(u8, hostname);

    // 获取内存信息
    const mem_info = getMemoryInfo();

    // 检测 io_uring 支持
    const supports_io_uring = detectIoUringSupport();

    return SystemInfo{
        .os_name = @tagName(builtin.os.tag),
        .cpu_arch = @tagName(builtin.cpu.arch),
        .cpu_count = @intCast(cpu_count),
        .total_memory = mem_info.total,
        .available_memory = mem_info.available,
        .hostname = hostname_copy,
        .zig_version = builtin.zig_version_string,
        .supports_io_uring = supports_io_uring,
    };
}

/// 内存信息
const MemoryInfo = struct {
    total: u64,
    available: u64,
};

/// 获取内存信息（跨平台）
fn getMemoryInfo() MemoryInfo {
    if (builtin.os.tag == .linux) {
        return getLinuxMemoryInfo() catch MemoryInfo{ .total = 0, .available = 0 };
    } else if (builtin.os.tag == .windows) {
        return getWindowsMemoryInfo() catch MemoryInfo{ .total = 0, .available = 0 };
    } else {
        // macOS 和其他平台
        return MemoryInfo{ .total = 0, .available = 0 };
    }
}

/// Linux 内存信息（从 /proc/meminfo）
fn getLinuxMemoryInfo() !MemoryInfo {
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
        return MemoryInfo{ .total = 0, .available = 0 };
    };
    defer file.close();

    var buffer: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const content = buffer[0..bytes_read];

    var total: u64 = 0;
    var available: u64 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total = parseMemLine(line) * 1024; // KB -> Bytes
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available = parseMemLine(line) * 1024; // KB -> Bytes
        }
    }

    return MemoryInfo{ .total = total, .available = available };
}

/// 解析内存行（例如：MemTotal:       16384000 kB）
fn parseMemLine(line: []const u8) u64 {
    var parts = std.mem.splitScalar(u8, line, ':');
    _ = parts.next(); // 跳过标签

    if (parts.next()) |value_part| {
        var tokens = std.mem.tokenizeAny(u8, value_part, " \t");
        if (tokens.next()) |num_str| {
            return std.fmt.parseInt(u64, num_str, 10) catch 0;
        }
    }

    return 0;
}

/// Windows 内存信息
fn getWindowsMemoryInfo() !MemoryInfo {
    if (builtin.os.tag != .windows) {
        return MemoryInfo{ .total = 0, .available = 0 };
    }

    const windows = std.os.windows;
    const MEMORYSTATUSEX = extern struct {
        dwLength: windows.DWORD,
        dwMemoryLoad: windows.DWORD,
        ullTotalPhys: windows.ULONGLONG,
        ullAvailPhys: windows.ULONGLONG,
        ullTotalPageFile: windows.ULONGLONG,
        ullAvailPageFile: windows.ULONGLONG,
        ullTotalVirtual: windows.ULONGLONG,
        ullAvailVirtual: windows.ULONGLONG,
        ullAvailExtendedVirtual: windows.ULONGLONG,
    };

    const GlobalMemoryStatusEx = struct {
        extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) windows.BOOL;
    }.GlobalMemoryStatusEx;

    var mem_status = std.mem.zeroes(MEMORYSTATUSEX);
    mem_status.dwLength = @sizeOf(MEMORYSTATUSEX);

    if (GlobalMemoryStatusEx(&mem_status) != 0) {
        return MemoryInfo{
            .total = mem_status.ullTotalPhys,
            .available = mem_status.ullAvailPhys,
        };
    }

    return MemoryInfo{ .total = 0, .available = 0 };
}

/// 获取主机名（跨平台）
fn getHostname(buffer: []u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return getWindowsHostname(buffer);
    } else {
        // POSIX (Linux, macOS, etc.)
        return getPosixHostname(buffer);
    }
}

/// POSIX 主机名
fn getPosixHostname(buffer: []u8) ![]const u8 {
    // std.posix.gethostname 需要固定大小的数组
    var fixed_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const result = std.posix.gethostname(&fixed_buffer) catch {
        return "unknown";
    };

    // 复制到用户提供的缓冲区
    const copy_len = @min(result.len, buffer.len);
    @memcpy(buffer[0..copy_len], result[0..copy_len]);
    return buffer[0..copy_len];
}

/// Windows 主机名
fn getWindowsHostname(buffer: []u8) ![]const u8 {
    const windows = std.os.windows;

    // Windows GetComputerNameA API
    const GetComputerNameA = struct {
        extern "kernel32" fn GetComputerNameA(lpBuffer: [*]u8, nSize: *windows.DWORD) callconv(.winapi) windows.BOOL;
    }.GetComputerNameA;

    var size: windows.DWORD = @intCast(buffer.len);
    const result = GetComputerNameA(buffer.ptr, &size);

    if (result == 0) {
        return error.HostnameUnavailable;
    }

    const len = @as(usize, @intCast(size));
    return buffer[0..len];
}

/// 检测 io_uring 支持(Linux 5.1+)
fn detectIoUringSupport() bool {
    if (builtin.os.tag != .linux) {
        return false;
    }

    // 尝试读取内核版本
    const file = std.fs.openFileAbsolute("/proc/sys/kernel/osrelease", .{}) catch {
        return false;
    };
    defer file.close();

    var buffer: [64]u8 = undefined;
    const bytes_read = file.readAll(&buffer) catch return false;
    const version_str = std.mem.trim(u8, buffer[0..bytes_read], &std.ascii.whitespace);

    // 解析版本号（例如：5.15.0-91-generic）
    var parts = std.mem.splitScalar(u8, version_str, '.');
    const major_str = parts.next() orelse return false;
    const minor_str = parts.next() orelse return false;

    const major = std.fmt.parseInt(u32, major_str, 10) catch return false;
    const minor = std.fmt.parseInt(u32, minor_str, 10) catch return false;

    // io_uring 在 Linux 5.1+ 可用
    if (major > 5) return true;
    if (major == 5 and minor >= 1) return true;

    return false;
}

/// 格式化内存大小（人类可读）
pub fn formatMemorySize(bytes: u64, buffer: []u8) ![]const u8 {
    if (bytes == 0) {
        return "N/A";
    }

    const kb = bytes / 1024;
    const mb = kb / 1024;
    const gb = mb / 1024;

    if (gb > 0) {
        return try std.fmt.bufPrint(buffer, "{d}.{d} GB", .{ gb, (mb % 1024) / 100 });
    } else if (mb > 0) {
        return try std.fmt.bufPrint(buffer, "{d} MB", .{mb});
    } else if (kb > 0) {
        return try std.fmt.bufPrint(buffer, "{d} KB", .{kb});
    } else {
        return try std.fmt.bufPrint(buffer, "{d} B", .{bytes});
    }
}

/// 打印系统信息摘要
pub fn printSystemInfo(info: SystemInfo, allocator: std.mem.Allocator) void {
    _ = allocator;

    std.debug.print("\n========================================================\n", .{});
    std.debug.print("             System Information                    \n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print(" Hostname:          {s: <32}\n", .{info.hostname});
    std.debug.print(" OS:                {s: <32}\n", .{info.os_name});
    std.debug.print(" CPU Arch:          {s: <32}\n", .{info.cpu_arch});
    std.debug.print(" CPU Cores:         {d: <32}\n", .{info.cpu_count});

    // 格式化内存大小
    var total_buf: [64]u8 = undefined;
    var avail_buf: [64]u8 = undefined;
    const total_str = formatMemorySize(info.total_memory, &total_buf) catch "N/A";
    const avail_str = formatMemorySize(info.available_memory, &avail_buf) catch "N/A";

    std.debug.print(" Total Memory:      {s: <32}\n", .{total_str});
    std.debug.print(" Available Memory:  {s: <32}\n", .{avail_str});
    std.debug.print(" io_uring Support:  {s: <32}\n", .{if (info.supports_io_uring) "Yes" else "No"});
    std.debug.print(" Zig Version:       {s: <32}\n", .{info.zig_version});
    std.debug.print("========================================================\n\n", .{});
}

/// 释放系统信息资源
pub fn freeSystemInfo(info: SystemInfo, allocator: std.mem.Allocator) void {
    allocator.free(info.hostname);
}

// ========================================================================
// 运行时资源监控（用于统计日志）
// ========================================================================

/// 进程资源使用情况
pub const ProcessResourceUsage = struct {
    /// 进程内存占用（RSS - Resident Set Size，字节）
    memory_rss: u64,
    /// 进程虚拟内存占用（VSZ，字节）
    memory_vsz: u64,
    /// CPU 占用率（百分比，0-100 * CPU核心数）
    cpu_usage_percent: f64,
};

/// 系统资源使用情况
pub const SystemResourceUsage = struct {
    /// 系统总内存（字节）
    total_memory: u64,
    /// 系统可用内存（字节）
    available_memory: u64,
    /// 系统已使用内存（字节）
    used_memory: u64,
    /// CPU 核心数
    cpu_count: u32,
};

/// 获取当前进程资源使用情况（跨平台）
pub fn getProcessResourceUsage() ProcessResourceUsage {
    if (builtin.os.tag == .linux) {
        return getLinuxProcessUsage() catch ProcessResourceUsage{
            .memory_rss = 0,
            .memory_vsz = 0,
            .cpu_usage_percent = 0.0,
        };
    } else if (builtin.os.tag == .windows) {
        return getWindowsProcessUsage() catch ProcessResourceUsage{
            .memory_rss = 0,
            .memory_vsz = 0,
            .cpu_usage_percent = 0.0,
        };
    } else {
        return ProcessResourceUsage{
            .memory_rss = 0,
            .memory_vsz = 0,
            .cpu_usage_percent = 0.0,
        };
    }
}

/// 获取系统资源使用情况（跨平台）
pub fn getSystemResourceUsage() SystemResourceUsage {
    const mem_info = getMemoryInfo();
    const cpu_count = std.Thread.getCpuCount() catch 1;

    return SystemResourceUsage{
        .total_memory = mem_info.total,
        .available_memory = mem_info.available,
        .used_memory = if (mem_info.total > mem_info.available)
            mem_info.total - mem_info.available
        else
            0,
        .cpu_count = @intCast(cpu_count),
    };
}

// ========================================================================
// Linux 进程资源监控
// ========================================================================

/// Linux 进程资源使用（从 /proc/self/stat 和 /proc/self/status）
fn getLinuxProcessUsage() !ProcessResourceUsage {
    // 读取 /proc/self/status 获取内存信息
    const status_file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch {
        return ProcessResourceUsage{ .memory_rss = 0, .memory_vsz = 0, .cpu_usage_percent = 0.0 };
    };
    defer status_file.close();

    var buffer: [8192]u8 = undefined;
    const bytes_read = try status_file.readAll(&buffer);
    const content = buffer[0..bytes_read];

    var rss_kb: u64 = 0;
    var vsz_kb: u64 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            rss_kb = parseMemLine(line);
        } else if (std.mem.startsWith(u8, line, "VmSize:")) {
            vsz_kb = parseMemLine(line);
        }
    }

    // CPU 使用率计算需要两次采样，这里简化为 0（避免阻塞）
    // 实际生产环境可以在后台线程定期采样
    const cpu_percent: f64 = 0.0;

    return ProcessResourceUsage{
        .memory_rss = rss_kb * 1024, // KB -> Bytes
        .memory_vsz = vsz_kb * 1024, // KB -> Bytes
        .cpu_usage_percent = cpu_percent,
    };
}

// ========================================================================
// Windows 进程资源监控
// ========================================================================

/// Windows 进程资源使用
fn getWindowsProcessUsage() !ProcessResourceUsage {
    const windows = std.os.windows;

    // PROCESS_MEMORY_COUNTERS_EX 结构体
    const PROCESS_MEMORY_COUNTERS_EX = extern struct {
        cb: windows.DWORD,
        PageFaultCount: windows.DWORD,
        PeakWorkingSetSize: windows.SIZE_T,
        WorkingSetSize: windows.SIZE_T,
        QuotaPeakPagedPoolUsage: windows.SIZE_T,
        QuotaPagedPoolUsage: windows.SIZE_T,
        QuotaPeakNonPagedPoolUsage: windows.SIZE_T,
        QuotaNonPagedPoolUsage: windows.SIZE_T,
        PagefileUsage: windows.SIZE_T,
        PeakPagefileUsage: windows.SIZE_T,
        PrivateUsage: windows.SIZE_T,
    };

    const GetProcessMemoryInfo = struct {
        extern "psapi" fn GetProcessMemoryInfo(
            hProcess: windows.HANDLE,
            ppsmemCounters: *PROCESS_MEMORY_COUNTERS_EX,
            cb: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
    }.GetProcessMemoryInfo;

    const GetCurrentProcess = struct {
        extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
    }.GetCurrentProcess;

    var mem_counters = std.mem.zeroes(PROCESS_MEMORY_COUNTERS_EX);
    mem_counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS_EX);

    const process_handle = GetCurrentProcess();
    const result = GetProcessMemoryInfo(
        process_handle,
        &mem_counters,
        @sizeOf(PROCESS_MEMORY_COUNTERS_EX),
    );

    if (result == 0) {
        return ProcessResourceUsage{
            .memory_rss = 0,
            .memory_vsz = 0,
            .cpu_usage_percent = 0.0,
        };
    }

    return ProcessResourceUsage{
        .memory_rss = mem_counters.WorkingSetSize, // 工作集大小（类似 RSS）
        .memory_vsz = mem_counters.PrivateUsage, // 私有字节数（类似 VSZ）
        .cpu_usage_percent = 0.0, // CPU 使用率需要定期采样，这里简化
    };
}
