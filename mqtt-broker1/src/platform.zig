const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum {
    LinuxHighPerf, // Linux x86_64/aarch64 with io_uring
    WindowsHighPerf, // Windows x86_64 with IOCP
    EmbeddedARM, // ARM 嵌入式设备（OpenWrt 等）
    Fallback, // 其他平台或不支持异步 IO
};

pub const PlatformCapabilities = struct {
    platform: Platform,
    supports_io_uring: bool,
    supports_iocp: bool,
    max_recommended_connections: u32,
    use_async: bool,
};

/// 检测当前运行平台和能力
pub fn detectPlatform() PlatformCapabilities {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;

    return switch (os) {
        .linux => detectLinux(arch),
        .windows => detectWindows(arch),
        else => fallbackPlatform(arch),
    };
}

fn detectLinux(arch: std.Target.Cpu.Arch) PlatformCapabilities {
    return switch (arch) {
        .x86_64, .aarch64 => blk: {
            const has_uring = checkIoUring();
            break :blk PlatformCapabilities{
                .platform = if (has_uring) .LinuxHighPerf else .Fallback,
                .supports_io_uring = has_uring,
                .supports_iocp = false,
                .max_recommended_connections = if (has_uring) 1_000_000 else 10_000,
                .use_async = has_uring,
            };
        },
        .arm => PlatformCapabilities{
            .platform = .EmbeddedARM,
            .supports_io_uring = false,
            .supports_iocp = false,
            .max_recommended_connections = 500,
            .use_async = false,
        },
        else => fallbackPlatform(arch),
    };
}

fn detectWindows(arch: std.Target.Cpu.Arch) PlatformCapabilities {
    return switch (arch) {
        .x86_64 => PlatformCapabilities{
            .platform = .WindowsHighPerf,
            .supports_io_uring = false,
            .supports_iocp = true, // Windows 总是支持 IOCP
            .max_recommended_connections = 1_000_000,
            .use_async = true,
        },
        else => fallbackPlatform(arch),
    };
}

fn fallbackPlatform(arch: std.Target.Cpu.Arch) PlatformCapabilities {
    _ = arch;
    return PlatformCapabilities{
        .platform = .Fallback,
        .supports_io_uring = false,
        .supports_iocp = false,
        .max_recommended_connections = 1_000,
        .use_async = false,
    };
}

/// 检测 io_uring 是否可用（尝试创建实例）
fn checkIoUring() bool {
    // 编译时检查：如果不是 Linux 直接返回 false
    if (builtin.os.tag != .linux) return false;

    // 运行时检查：尝试初始化 io_uring
    const IO = @import("iobeetle/io.zig").IO;
    var io = IO.init(32, 0) catch |err| {
        // 如果是 SystemOutdated 错误，说明内核不支持
        if (err == error.SystemOutdated) {
            return false;
        }
        // 其他错误（如权限问题）也认为不可用
        return false;
    };
    io.deinit();
    return true;
}

/// 获取系统建议的配置
pub fn getRecommendedConfig(caps: PlatformCapabilities) Config {
    return switch (caps.platform) {
        .LinuxHighPerf => Config{
            .max_connections = 1_000_000,
            .io_entries = 4096,
            .worker_threads = 4,
            .use_thread_pool = false, // 异步不需要线程池
            .read_buffer_size = 4096,
            .write_buffer_size = 4096,
        },
        .WindowsHighPerf => Config{
            .max_connections = 1_000_000,
            .io_entries = 4096,
            .worker_threads = 4,
            .use_thread_pool = false,
            .read_buffer_size = 4096,
            .write_buffer_size = 4096,
        },
        .EmbeddedARM => Config{
            .max_connections = 500,
            .io_entries = 64,
            .worker_threads = 2,
            .use_thread_pool = true, // 同步版本需要线程池
            .read_buffer_size = 1024, // 减小缓冲区节省内存
            .write_buffer_size = 1024,
        },
        .Fallback => Config{
            .max_connections = 1_000,
            .io_entries = 128,
            .worker_threads = 4,
            .use_thread_pool = true,
            .read_buffer_size = 2048,
            .write_buffer_size = 2048,
        },
    };
}

pub const Config = struct {
    max_connections: u32,
    io_entries: u32,
    worker_threads: u32,
    use_thread_pool: bool,
    read_buffer_size: u32,
    write_buffer_size: u32,
};
