const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");

// 根据目标架构选择合适的原子计数器类型
// 32位架构(如ARMv7)不支持64位原子操作,使用u32
// 64位架构使用u64以支持更大的计数范围
const CounterType = if (@sizeOf(usize) >= 8) u64 else u32;

/// 原子指标结构体 - 支持多线程安全更新
/// 在32位平台上使用u32计数器,64位平台使用u64计数器
pub const Metrics = struct {
    // 连接统计
    connections_current: std.atomic.Value(CounterType), // 当前连接数
    connections_total: std.atomic.Value(CounterType), // 累计连接数
    connections_refused: std.atomic.Value(CounterType), // 拒绝连接数

    // 消息统计
    messages_received: std.atomic.Value(CounterType), // 接收消息数
    messages_sent: std.atomic.Value(CounterType), // 发送消息数
    messages_dropped: std.atomic.Value(CounterType), // 丢弃消息数

    // 字节统计
    bytes_received: std.atomic.Value(CounterType), // 接收字节数
    bytes_sent: std.atomic.Value(CounterType), // 发送字节数

    // PUBLISH 统计
    publish_received: std.atomic.Value(CounterType), // 接收 PUBLISH 数
    publish_sent: std.atomic.Value(CounterType), // 发送 PUBLISH 数

    // 订阅统计
    subscriptions_current: std.atomic.Value(CounterType), // 当前订阅数
    subscriptions_total: std.atomic.Value(CounterType), // 累计订阅数

    // 错误统计
    errors_total: std.atomic.Value(CounterType), // 总错误数
    errors_protocol: std.atomic.Value(CounterType), // 协议错误数
    errors_network: std.atomic.Value(CounterType), // 网络错误数

    // 服务器信息
    start_time: i64, // 启动时间戳(毫秒)

    pub fn init() Metrics {
        return Metrics{
            .connections_current = std.atomic.Value(CounterType).init(0),
            .connections_total = std.atomic.Value(CounterType).init(0),
            .connections_refused = std.atomic.Value(CounterType).init(0),
            .messages_received = std.atomic.Value(CounterType).init(0),
            .messages_sent = std.atomic.Value(CounterType).init(0),
            .messages_dropped = std.atomic.Value(CounterType).init(0),
            .bytes_received = std.atomic.Value(CounterType).init(0),
            .bytes_sent = std.atomic.Value(CounterType).init(0),
            .publish_received = std.atomic.Value(CounterType).init(0),
            .publish_sent = std.atomic.Value(CounterType).init(0),
            .subscriptions_current = std.atomic.Value(CounterType).init(0),
            .subscriptions_total = std.atomic.Value(CounterType).init(0),
            .errors_total = std.atomic.Value(CounterType).init(0),
            .errors_protocol = std.atomic.Value(CounterType).init(0),
            .errors_network = std.atomic.Value(CounterType).init(0),
            .start_time = std.time.milliTimestamp(),
        };
    }

    // ========================================================================
    // 连接相关
    // ========================================================================

    pub fn incConnectionAccepted(self: *Metrics) void {
        _ = self.connections_current.fetchAdd(1, .monotonic);
        _ = self.connections_total.fetchAdd(1, .monotonic);
    }

    pub fn incConnectionClosed(self: *Metrics) void {
        _ = self.connections_current.fetchSub(1, .monotonic);
    }

    pub fn incConnectionRefused(self: *Metrics) void {
        _ = self.connections_refused.fetchAdd(1, .monotonic);
    }

    // ========================================================================
    // 消息相关
    // ========================================================================

    pub fn incMessageReceived(self: *Metrics, bytes: usize) void {
        _ = self.messages_received.fetchAdd(1, .monotonic);
        _ = self.bytes_received.fetchAdd(bytes, .monotonic);
    }

    pub fn incMessageSent(self: *Metrics, bytes: usize) void {
        _ = self.messages_sent.fetchAdd(1, .monotonic);
        _ = self.bytes_sent.fetchAdd(bytes, .monotonic);
    }

    pub fn incMessageDropped(self: *Metrics) void {
        _ = self.messages_dropped.fetchAdd(1, .monotonic);
    }

    pub fn incPublishReceived(self: *Metrics) void {
        _ = self.publish_received.fetchAdd(1, .monotonic);
    }

    pub fn incPublishSent(self: *Metrics) void {
        _ = self.publish_sent.fetchAdd(1, .monotonic);
    }

    // ========================================================================
    // 订阅相关
    // ========================================================================

    pub fn incSubscription(self: *Metrics) void {
        _ = self.subscriptions_current.fetchAdd(1, .monotonic);
        _ = self.subscriptions_total.fetchAdd(1, .monotonic);
    }

    pub fn decSubscription(self: *Metrics) void {
        _ = self.subscriptions_current.fetchSub(1, .monotonic);
    }

    // ========================================================================
    // 错误相关
    // ========================================================================

    pub fn incError(self: *Metrics) void {
        _ = self.errors_total.fetchAdd(1, .monotonic);
    }

    pub fn incProtocolError(self: *Metrics) void {
        _ = self.errors_protocol.fetchAdd(1, .monotonic);
        _ = self.errors_total.fetchAdd(1, .monotonic);
    }

    pub fn incNetworkError(self: *Metrics) void {
        _ = self.errors_network.fetchAdd(1, .monotonic);
        _ = self.errors_total.fetchAdd(1, .monotonic);
    }

    // ========================================================================
    // 查询接口
    // ========================================================================

    pub fn getConnectionsCurrent(self: *const Metrics) u64 {
        return self.connections_current.load(.monotonic);
    }

    pub fn getConnectionsTotal(self: *const Metrics) u64 {
        return self.connections_total.load(.monotonic);
    }

    pub fn getMessagesReceived(self: *const Metrics) u64 {
        return self.messages_received.load(.monotonic);
    }

    pub fn getMessagesSent(self: *const Metrics) u64 {
        return self.messages_sent.load(.monotonic);
    }

    pub fn getBytesReceived(self: *const Metrics) u64 {
        return self.bytes_received.load(.monotonic);
    }

    pub fn getBytesSent(self: *const Metrics) u64 {
        return self.bytes_sent.load(.monotonic);
    }

    pub fn getUptimeSeconds(self: *const Metrics) i64 {
        const now = std.time.milliTimestamp();
        return @divTrunc((now - self.start_time), 1000);
    }

    // ========================================================================
    // 日志输出
    // ========================================================================

    pub fn logStats(self: *const Metrics) void {
        const uptime = self.getUptimeSeconds();
        logger.info("=== MQTT Broker Statistics ===", .{});
        logger.info("Uptime: {d}s", .{uptime});
        logger.info("Connections: {d} current, {d} total, {d} refused", .{
            self.getConnectionsCurrent(),
            self.getConnectionsTotal(),
            self.connections_refused.load(.monotonic),
        });
        logger.info("Messages: {d} recv, {d} sent, {d} dropped", .{
            self.getMessagesReceived(),
            self.getMessagesSent(),
            self.messages_dropped.load(.monotonic),
        });
        logger.info("Bytes: {d} recv, {d} sent", .{
            self.getBytesReceived(),
            self.getBytesSent(),
        });
        logger.info("PUBLISH: {d} recv, {d} sent", .{
            self.publish_received.load(.monotonic),
            self.publish_sent.load(.monotonic),
        });
        logger.info("Subscriptions: {d} current, {d} total", .{
            self.subscriptions_current.load(.monotonic),
            self.subscriptions_total.load(.monotonic),
        });
        logger.info("Errors: {d} total ({d} protocol, {d} network)", .{
            self.errors_total.load(.monotonic),
            self.errors_protocol.load(.monotonic),
            self.errors_network.load(.monotonic),
        });
        logger.info("============================", .{});
    }
};
