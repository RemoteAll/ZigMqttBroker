const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const posix = std.posix;
const packet = @import("packet.zig");
const mqtt = @import("mqtt.zig");
const Client = @import("client.zig").Client;
const assert = std.debug.assert;

pub const UnsubscribeError = error{
    InvalidPacket,
    TopicMustBePresent,
};

/// UNSUBSCRIBE 数据包结构
pub const UnsubscribePacket = struct {
    packet_id: u16,
    topics: std.ArrayList([]const u8),

    pub fn init(packet_id: u16) UnsubscribePacket {
        return UnsubscribePacket{
            .packet_id = packet_id,
            .topics = .{},
        };
    }

    pub fn deinit(self: *UnsubscribePacket, allocator: Allocator) void {
        self.topics.deinit(allocator);
    }
};

/// 读取 UNSUBSCRIBE 数据包
pub fn read(reader: *packet.Reader, allocator: Allocator) !*UnsubscribePacket {
    // 读取 Packet Identifier
    const packet_id = try reader.readTwoBytes();

    // 在堆上分配 UnsubscribePacket
    const up = try allocator.create(UnsubscribePacket);
    errdefer allocator.destroy(up);

    up.* = UnsubscribePacket.init(packet_id);
    errdefer up.deinit(allocator);

    // 读取主题过滤器(可能有多个)
    // UNSUBSCRIBE 数据包的有效载荷包含一个或多个主题过滤器
    while (reader.pos < reader.length) {
        const topic_filter = try reader.readUTF8String(false) orelse {
            std.debug.print("ERROR: Topic filter is null or empty in UNSUBSCRIBE\n", .{});
            return UnsubscribeError.TopicMustBePresent;
        };

        if (topic_filter.len == 0) {
            std.debug.print("ERROR: Topic filter length is 0 in UNSUBSCRIBE\n", .{});
            return UnsubscribeError.TopicMustBePresent;
        }

        std.debug.print("DEBUG: Unsubscribing from topic: '{s}' (length: {d})\n", .{ topic_filter, topic_filter.len });

        try up.topics.append(allocator, topic_filter);
    }

    if (up.topics.items.len == 0) {
        std.debug.print("ERROR: UNSUBSCRIBE packet has no topics\n", .{});
        return UnsubscribeError.TopicMustBePresent;
    }

    return up;
}

/// 发送 UNSUBACK 响应
pub fn unsuback(writer: *packet.Writer, stream: *net.Stream, packet_id: u16) (packet.PacketWriterError || posix.WriteError)!void {
    std.debug.print("Sending UNSUBACK with packet_id {d}\n", .{packet_id});

    try writer.startPacket(mqtt.Command.UNSUBACK);

    // Variable Header: Packet Identifier
    try writer.writeTwoBytes(packet_id);

    try writer.finishPacket();

    writer.writeToStream(stream) catch |err| {
        std.log.err("Failed to write UNSUBACK to stream: {any}", .{err});
        return error.StreamWriteError;
    };
}

/// 异步版本: 发送 UNSUBACK 响应 - 只准备数据不发送
pub fn unsubackAsync(writer: *packet.Writer, packet_id: u16) !void {
    std.debug.print("Preparing UNSUBACK with packet_id {d}\n", .{packet_id});

    try writer.startPacket(mqtt.Command.UNSUBACK);

    // Variable Header: Packet Identifier
    try writer.writeTwoBytes(packet_id);

    try writer.finishPacket();
}
