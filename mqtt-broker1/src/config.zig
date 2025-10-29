const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");

// ========================================================================
// 运行时配置结构（从 data/config.json 加载）
// ========================================================================

/// 运行时可配置项（优先级高于编译期默认值）
pub const RuntimeConfig = struct {
    port: u16 = PORT,
    log_enabled: bool = true,
    log_level: logger.Level = DEFAULT_LOG_LEVEL,
    stats_interval_sec: u32 = STATS_PUBLISH_INTERVAL_SEC, // 统计信息输出间隔（秒）
};

/// 从 JSON 字符串解析日志级别
fn parseLevelFromString(s: []const u8) ?logger.Level {
    // 简单的字符串比较，不区分大小写
    if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(s, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
    return null;
}

/// 日志级别转字符串
fn levelToString(l: logger.Level) []const u8 {
    return switch (l) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

/// 加载运行时配置（从 data/config.json）
/// 文件不存在时自动创建默认配置；解析失败时使用编译期默认值
pub fn loadRuntimeConfig(allocator: std.mem.Allocator, path: []const u8) RuntimeConfig {
    // 1. 确保目录存在
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            logger.warn("Failed to ensure config directory '{s}': {any}, using compile-time defaults", .{ dir, err });
            return RuntimeConfig{};
        };
    }

    // 2. 尝试打开配置文件
    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            // 文件不存在，创建默认配置
            const default_config = RuntimeConfig{};
            saveRuntimeConfig(allocator, path, default_config) catch |save_err| {
                logger.warn("Failed to write default config to '{s}': {any}", .{ path, save_err });
            };
            logger.always("Created default configuration at '{s}'", .{path});
            return default_config;
        } else {
            logger.warn("Failed to open config file '{s}': {any}, using defaults", .{ path, err });
            return RuntimeConfig{};
        }
    };
    defer file.close();

    // 3. 读取文件内容
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        logger.warn("Failed to read config file '{s}': {any}, using defaults", .{ path, err });
        return RuntimeConfig{};
    };
    defer allocator.free(content);

    // 4. 解析 JSON
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{},
    ) catch |err| {
        logger.warn("Invalid JSON in config file '{s}': {any}, using defaults", .{ path, err });
        return RuntimeConfig{};
    };
    defer parsed.deinit();

    // 5. 提取配置项
    var rc = RuntimeConfig{};
    const root = parsed.value;

    if (root == .object) {
        const obj = root.object;

        // 解析 port
        if (obj.get("port")) |port_value| {
            if (port_value == .integer) {
                const p = @as(u16, @intCast(port_value.integer));
                if (p != 0) rc.port = p;
            }
        }

        // 解析 log 配置
        if (obj.get("log")) |log_value| {
            if (log_value == .object) {
                const log_obj = log_value.object;

                if (log_obj.get("enabled")) |enabled_value| {
                    if (enabled_value == .bool) {
                        rc.log_enabled = enabled_value.bool;
                    }
                }

                if (log_obj.get("level")) |level_value| {
                    if (level_value == .string) {
                        if (parseLevelFromString(level_value.string)) |lvl| {
                            rc.log_level = lvl;
                        }
                    }
                }
            }
        }

        // 解析统计间隔
        if (obj.get("stats_interval_sec")) |stats_value| {
            if (stats_value == .integer) {
                const interval = @as(u32, @intCast(stats_value.integer));
                if (interval > 0) rc.stats_interval_sec = interval;
            }
        }
    }

    logger.info("Loaded configuration from '{s}' (port={d}, log_level={s}, stats_interval={d}s)", .{ path, rc.port, @tagName(rc.log_level), rc.stats_interval_sec });
    return rc;
}

/// 保存运行时配置到 JSON 文件
fn saveRuntimeConfig(allocator: std.mem.Allocator, path: []const u8, rc: RuntimeConfig) !void {
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);

    // 手动构建 JSON（与 persistence.zig 风格一致）
    try json_buf.appendSlice(allocator, "{\n");
    try std.fmt.format(json_buf.writer(allocator), "  \"port\": {d},\n", .{rc.port});
    try std.fmt.format(json_buf.writer(allocator), "  \"stats_interval_sec\": {d},\n", .{rc.stats_interval_sec});
    try json_buf.appendSlice(allocator, "  \"log\": {\n");
    try std.fmt.format(json_buf.writer(allocator), "    \"enabled\": {s},\n", .{if (rc.log_enabled) "true" else "false"});
    try std.fmt.format(json_buf.writer(allocator), "    \"level\": \"{s}\"\n", .{levelToString(rc.log_level)});
    try json_buf.appendSlice(allocator, "  }\n");
    try json_buf.appendSlice(allocator, "}\n");

    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll(json_buf.items);
}

// ========================================================================
// 平台检测与性能分级
// ========================================================================

/// 部署场景类型
pub const DeploymentProfile = enum {
    /// 高性能服务器（Linux io_uring / Windows IOCP）
    /// 目标：100万+ 并发连接
    high_performance,

    /// 标准服务器（阻塞 I/O + 线程池）
    /// 目标：10K-50K 并发连接
    standard,

    /// 嵌入式设备（资源受限）
    /// 目标：100-5K 并发连接
    embedded,

    /// 开发环境（快速调试）
    development,
};

/// 获取当前部署场景（编译期决策）
pub fn getDeploymentProfile() DeploymentProfile {
    // 编译模式判断
    if (builtin.mode == .Debug) {
        return .development;
    }

    // 目标架构判断
    if (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb) {
        return .embedded;
    }

    // 根据优化等级判断
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        // 假设 ReleaseFast 用于高性能服务器
        return .high_performance;
    }

    return .standard;
}

/// 根据部署场景获取推荐的最大连接数
pub fn getMaxConnections() u32 {
    return switch (getDeploymentProfile()) {
        .high_performance => 1_000_000, // 100万
        .standard => 50_000, // 5万
        .embedded => 5_000, // 5千
        .development => 1_000, // 1千
    };
}

/// 根据部署场景获取初始池大小
pub fn getInitialPoolSize() u32 {
    return switch (getDeploymentProfile()) {
        .high_performance => 10_000, // 预热 1万连接
        .standard => 2_000, // 预热 2千连接
        .embedded => 500, // 预热 500连接
        .development => 100, // 预热 100连接
    };
}

/// 根据部署场景获取转发批次大小
pub fn getForwardBatchSize() u32 {
    return switch (getDeploymentProfile()) {
        .high_performance => 10_000, // 大批次，减少系统调用
        .standard => 1_000, // 中等批次
        .embedded => 100, // 小批次，节省内存
        .development => 50, // 小批次，易调试
    };
}

/// 根据部署场景获取日志级别
pub fn getDefaultLogLevel() logger.Level {
    return switch (getDeploymentProfile()) {
        .high_performance => .warn, // 最小日志，最高性能
        .standard => .info, // 平衡
        .embedded => .warn, // 减少 I/O
        .development => .debug, // 详细日志
    };
}

// ========================================================================
// 服务器配置
// ========================================================================
pub const PORT = 1883;
pub const KERNEL_BACKLOG = 128;

// ========================================================================
// 连接限制（动态配置）
// ========================================================================

/// 最大并发连接数（根据部署场景自动调整）
pub const MAX_CONNECTIONS = getMaxConnections();

/// IO操作队列深度 - Linux io_uring 内核会自动向上取整到最近的2的幂次方
/// 直接设置为 4096 (2^12), 内核原样使用无需调整
/// 注意: Windows IOCP 完全忽略此参数
pub const IO_ENTRIES = 4096; // 2^12 = 4096 (io_uring 最佳实践值)
pub const QUEUE_DEPTH = 4096; // 传统队列深度(向后兼容)

// ========================================================================
// 内存池配置（动态配置）
// ========================================================================

/// 初始预热大小：启动时立即分配的连接对象数
/// 根据部署场景自动调整（高性能 10K / 标准 2K / 嵌入式 500 / 开发 100）
pub const INITIAL_POOL_SIZE = getInitialPoolSize();

/// 最大连接池大小（与 MAX_CONNECTIONS 同步）
pub const MAX_POOL_SIZE = MAX_CONNECTIONS;

pub const MAX_MESSAGES_POOL = 10_000; // 消息池大小

// ========================================================================
// 缓冲区大小（针对高吞吐优化）
// ========================================================================

/// 每连接读缓冲区大小
/// 权衡：大缓冲 = 减少系统调用 vs 增加内存占用
/// - 4KB: 适合小消息场景（传感器数据）
/// - 8KB: 适合混合场景
/// - 16KB: 适合大消息场景（图片上传）
pub const READ_BUFFER_SIZE = if (getDeploymentProfile() == .embedded) 2048 else 4096;

/// 每连接写缓冲区大小
pub const WRITE_BUFFER_SIZE = if (getDeploymentProfile() == .embedded) 2048 else 4096;
pub const MAXIMUM_MESSAGE_SIZE = 256 * 1024; // 最大消息256KB

// ========================================================================
// 客户端标识
// ========================================================================
pub const MAX_CLIENT_ID_LEN = 64;
pub const MAX_MESSAGE_LEN = 2048; // 向后兼容

// ========================================================================
// 超时配置
// ========================================================================
pub const KEEP_ALIVE_DEFAULT = 60; // 默认保活时间(秒)
pub const CONNECTION_TIMEOUT = 30; // 连接超时(秒)

// ========================================================================
// 会话过期配置（MQTT 5.0 特性，MQTT 3.1.1 使用默认值）
// ========================================================================
// MQTT 3.1.1 Clean Session = 0 时的默认会话过期时间（秒）
// 注意：MQTT 3.1.1 协议本身不支持 session_expiry_interval
// 这是服务器端的默认配置，防止会话无限期保留
pub const DEFAULT_SESSION_EXPIRY_SEC = 3600; // 1小时
pub const MAX_SESSION_EXPIRY_SEC = 86400; // 24小时（最大值）
pub const SESSION_EXPIRY_NEVER = 0xFFFFFFFF; // 永不过期（MQTT 5.0）

// ========================================================================
// 主题限制
// ========================================================================
pub const MAX_TOPIC_LENGTH = 256;
pub const MAX_TOPIC_LEVELS = 16;

// ========================================================================
// 监控配置
// ========================================================================
pub const STATS_PUBLISH_INTERVAL_SEC = 60; // 统计信息发布间隔(秒) - 1分钟输出一次
pub const STATS_INTERVAL_NS = STATS_PUBLISH_INTERVAL_SEC * std.time.ns_per_s; // 纳秒单位

// ========================================================================
// 转发优化配置（动态配置）
// ========================================================================

/// 批量转发触发阈值（订阅者数量 >= 此值时使用批量转发）
pub const BATCH_FORWARD_THRESHOLD = 10;

/// 批量转发每批大小（根据部署场景自动调整）
/// - 高性能：10K（减少系统调用，最大化吞吐）
/// - 标准：1K（平衡性能和内存）
/// - 嵌入式：100（节省内存）
pub const FORWARD_BATCH_SIZE = getForwardBatchSize();

// ========================================================================
// 线程池配置（仅同步版本使用）
// ========================================================================

/// 获取客户端处理线程池大小
pub fn getClientPoolSize() u32 {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    return switch (getDeploymentProfile()) {
        .high_performance => @min(cpu_count * 2, 32), // CPU × 2，最多 32
        .standard => @min(cpu_count * 2, 16), // CPU × 2，最多 16
        .embedded => @min(cpu_count, 4), // CPU 数量，最多 4
        .development => 4, // 固定 4 线程
    };
}

/// 获取消息转发线程池大小
pub fn getForwardPoolSize() u32 {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    return switch (getDeploymentProfile()) {
        .high_performance => @min(cpu_count * 4, 64), // CPU × 4，最多 64
        .standard => @min(cpu_count * 2, 32), // CPU × 2，最多 32
        .embedded => @min(cpu_count, 8), // CPU 数量，最多 8
        .development => 4, // 固定 4 线程
    };
}

// ========================================================================
// 日志配置（动态配置）
// ========================================================================

/// 默认日志级别（根据部署场景自动调整）
/// - 开发：debug（详细日志，性能影响 30-50%）
/// - 标准：info（关键操作，性能影响 < 5%）
/// - 高性能/嵌入式：warn（仅警告，性能影响 < 1%）
pub const DEFAULT_LOG_LEVEL = getDefaultLogLevel();

// ========================================================================
// 性能监控配置
// ========================================================================

/// 是否启用性能监控
pub const ENABLE_METRICS = (getDeploymentProfile() != .embedded);

/// 是否启用内存追踪
pub const ENABLE_MEMORY_TRACKING = (getDeploymentProfile() == .development);

// ========================================================================
// 配置摘要打印（启动时显示）
// ========================================================================

pub fn printConfig() void {
    const profile = getDeploymentProfile();
    std.debug.print("\n=== MQTT Broker Configuration ===\n", .{});
    std.debug.print("Deployment Profile: {s}\n", .{@tagName(profile)});
    std.debug.print("Max Connections: {d}\n", .{MAX_CONNECTIONS});
    std.debug.print("Initial Pool Size: {d}\n", .{INITIAL_POOL_SIZE});
    std.debug.print("Forward Batch Size: {d}\n", .{FORWARD_BATCH_SIZE});
    std.debug.print("Log Level: {s}\n", .{@tagName(DEFAULT_LOG_LEVEL)});
    std.debug.print("Read Buffer: {d} KB\n", .{READ_BUFFER_SIZE / 1024});
    std.debug.print("Write Buffer: {d} KB\n", .{WRITE_BUFFER_SIZE / 1024});

    if (profile == .standard or profile == .embedded) {
        std.debug.print("Client Thread Pool: {d}\n", .{getClientPoolSize()});
        std.debug.print("Forward Thread Pool: {d}\n", .{getForwardPoolSize()});
    }

    std.debug.print("=================================\n\n", .{});
}
