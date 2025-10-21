const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.log.info("=== MQTT 性能测试 ===", .{});
    std.log.info("连接到 localhost:1883", .{});

    const addr = try net.Address.parseIp("127.0.0.1", 1883);
    const stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    std.log.info("✅ 已连接", .{});

    // 发送 CONNECT 包
    const connect_packet = [_]u8{
        0x10, // CONNECT
        0x1C, // Remaining Length
        0x00, 0x04, 'M', 'Q', 'T', 'T', // Protocol Name
        0x04, // Protocol Level (MQTT 3.1.1)
        0x02, // Connect Flags (Clean Session)
        0x00, 0x3C, // Keep Alive (60s)
        0x00, 0x0E, 't', 'e', 's', 't', '_', 'c', 'l', 'i', 'e', 'n', 't', '_', '1', // Client ID
    };

    try stream.writeAll(&connect_packet);
    std.log.info("📤 已发送 CONNECT", .{});

    // 读取 CONNACK
    var buffer: [256]u8 = undefined;
    const len = try stream.read(&buffer);
    if (len >= 4 and buffer[0] == 0x20) {
        std.log.info("📥 收到 CONNACK (连接成功)", .{});
    }

    // 订阅主题
    const subscribe_packet = [_]u8{
        0x82, // SUBSCRIBE
        0x0A, // Remaining Length
        0x00, 0x01, // Packet ID
        0x00, 0x05, '/', 't', 'e', 's', 't', // Topic Filter
        0x00, // QoS 0
    };

    try stream.writeAll(&subscribe_packet);
    std.log.info("📤 已订阅 /test", .{});

    // 读取 SUBACK
    _ = try stream.read(&buffer);
    std.log.info("📥 收到 SUBACK", .{});

    // 性能测试: 发送 N 条消息并测量时间
    const message_count = 1000;
    const payload = "Hello MQTT Performance Test!";

    std.log.info("\n开始性能测试: 发送 {} 条消息", .{message_count});

    var total_time_ns: u64 = 0;
    var i: usize = 0;

    while (i < message_count) : (i += 1) {
        const start = std.time.nanoTimestamp();

        // 构建 PUBLISH 包
        var publish_buffer: [1024]u8 = undefined;
        var pos: usize = 0;

        publish_buffer[pos] = 0x30; // PUBLISH
        pos += 1;

        const topic = "/test";
        const remaining_length = 2 + topic.len + payload.len;
        publish_buffer[pos] = @intCast(remaining_length);
        pos += 1;

        // Topic Length
        publish_buffer[pos] = 0;
        pos += 1;
        publish_buffer[pos] = @intCast(topic.len);
        pos += 1;

        // Topic
        @memcpy(publish_buffer[pos .. pos + topic.len], topic);
        pos += topic.len;

        // Payload
        @memcpy(publish_buffer[pos .. pos + payload.len], payload);
        pos += payload.len;

        // 发送
        try stream.writeAll(publish_buffer[0..pos]);

        // 读取回显(如果是自己订阅的)
        const recv_len = try stream.read(&buffer);
        if (recv_len == 0) {
            std.log.warn("连接断开", .{});
            break;
        }

        const end = std.time.nanoTimestamp();
        total_time_ns += @intCast(end - start);

        // 每 100 条打印一次进度
        if ((i + 1) % 100 == 0) {
            const avg_latency_us = @divFloor(total_time_ns, (i + 1) * 1000);
            std.log.info("已发送 {}/{}  平均延迟: {} μs", .{ i + 1, message_count, avg_latency_us });
        }
    }

    const avg_latency_ms = @divFloor(total_time_ns, message_count * 1_000_000);
    const avg_latency_us = @divFloor(total_time_ns, message_count * 1000);
    const qps = if (total_time_ns > 0) @divFloor(message_count * 1_000_000_000, total_time_ns) else 0;

    std.log.info("\n=== 性能测试结果 ===", .{});
    std.log.info("总消息数: {}", .{message_count});
    std.log.info("总耗时: {} ms", .{@divFloor(total_time_ns, 1_000_000)});
    std.log.info("平均延迟: {} ms ({} μs)", .{ avg_latency_ms, avg_latency_us });
    std.log.info("吞吐量: {} 消息/秒", .{qps});
    std.log.info("====================", .{});

    // 断开连接
    const disconnect_packet = [_]u8{ 0xE0, 0x00 };
    try stream.writeAll(&disconnect_packet);
    std.log.info("\n📤 已发送 DISCONNECT", .{});
}
