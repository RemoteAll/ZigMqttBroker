const std = @import("std");
const packet = @import("packet.zig");
const mqtt = @import("mqtt.zig");
const Client = @import("client.zig").Client;
const Allocator = std.mem.Allocator;
const logger = @import("logger.zig");

/// PUBLISH 包结构
pub const PublishPacket = struct {
    topic: []const u8,
    payload: []const u8,
    qos: mqtt.QoS,
    retain: bool,
    dup: bool,
    packet_id: ?u16, // QoS 1 和 2 需要

    pub fn deinit(self: *PublishPacket, allocator: Allocator) void {
        _ = self;
        _ = allocator;
        // topic 和 payload 是指向 reader buffer 的引用,不需要释放
    }
};

/// 读取 PUBLISH 包
/// reader.pos 应该已经越过 Command 和 Remaining Length
pub fn read(reader: *packet.Reader) !PublishPacket {
    // 读取固定头部的 flags (从 reader.buffer[0] 读取,因为包含 DUP、QoS、RETAIN)
    const fixed_header = reader.buffer[0];
    const dup = (fixed_header & 0b0000_1000) != 0;
    const qos_value = (fixed_header & 0b0000_0110) >> 1;
    const retain = (fixed_header & 0b0000_0001) != 0;

    const qos = mqtt.QoS.fromU8(qos_value) orelse {
        logger.err("Invalid QoS value in PUBLISH: {d}", .{qos_value});
        return error.InvalidQoS;
    };

    // 读取主题名称
    const topic = try reader.readUTF8String(false) orelse {
        logger.err("PUBLISH packet missing topic", .{});
        return error.MissingTopic;
    };

    // QoS 1 或 2 需要 Packet ID
    var packet_id: ?u16 = null;
    if (qos != .AtMostOnce) {
        packet_id = try reader.readTwoBytes();
    }

    // 剩余部分是 payload
    const payload_start = reader.pos;
    const payload_length = reader.length - payload_start;
    const payload = reader.buffer[payload_start..reader.length];

    logger.debug("PUBLISH parsed: topic='{s}', qos={any}, retain={any}, dup={any}, packet_id={any}, payload_len={d}", .{ topic, qos, retain, dup, packet_id, payload_length });

    return PublishPacket{
        .topic = topic,
        .payload = payload,
        .qos = qos,
        .retain = retain,
        .dup = dup,
        .packet_id = packet_id,
    };
}

/// 构建 PUBLISH 包并写入 writer
/// 用于转发消息给订阅者
pub fn writePublish(
    writer: *packet.Writer,
    topic: []const u8,
    payload: []const u8,
    qos: mqtt.QoS,
    retain: bool,
    dup: bool,
    packet_id: ?u16,
) !void {
    // 计算固定头部的 flags
    var flags: u8 = @intFromEnum(mqtt.Command.PUBLISH) << 4;
    if (dup) flags |= 0b0000_1000;
    flags |= (@intFromEnum(qos) << 1);
    if (retain) flags |= 0b0000_0001;

    // 写入固定头部
    try writer.writeByte(flags);

    // 计算 Remaining Length
    var remaining_length: usize = 0;
    remaining_length += 2 + topic.len; // Topic Name (2 字节长度 + 内容)
    if (qos != .AtMostOnce) {
        remaining_length += 2; // Packet ID
    }
    remaining_length += payload.len; // Payload

    // 写入 Remaining Length (可变长度编码)
    {
        var value = remaining_length;
        while (true) {
            var byte: u8 = @intCast(value % 128);
            value /= 128;
            if (value > 0) {
                byte |= 128;
            }
            try writer.writeByte(byte);
            if (value == 0) break;
        }
    }

    // 写入 Variable Header
    try writer.writeUTF8String(topic);
    if (qos != .AtMostOnce) {
        if (packet_id) |pid| {
            try writer.writeTwoBytes(pid);
        } else {
            return error.MissingPacketId;
        }
    }

    // 写入 Payload
    try writer.writeBytes(payload);
}

/// 发送 PUBACK (QoS 1 确认)
pub fn sendPuback(writer: *packet.Writer, client: *Client, packet_id: u16) !void {
    writer.reset();
    try writer.startPacket(mqtt.Command.PUBACK);
    try writer.writeTwoBytes(packet_id);
    try writer.finishPacket();
    try writer.writeToStream(&client.stream);
    logger.debug("Server sent PUBACK to {s} (packet_id={d})", .{ client.identifer, packet_id });
}

/// 异步版本: 发送 PUBACK (QoS 1 确认) - 只准备数据不发送
pub fn sendPubackAsync(writer: *packet.Writer, packet_id: u16) !void {
    writer.reset();
    try writer.startPacket(mqtt.Command.PUBACK);
    try writer.writeTwoBytes(packet_id);
    try writer.finishPacket();
}

/// 发送 PUBREC (QoS 2 第一步)
pub fn sendPubrec(writer: *packet.Writer, client: *Client, packet_id: u16) !void {
    writer.reset();
    try writer.startPacket(mqtt.Command.PUBREC);
    try writer.writeTwoBytes(packet_id);
    try writer.finishPacket();
    try writer.writeToStream(&client.stream);
    logger.debug("Server sent PUBREC to {s} (packet_id={d})", .{ client.identifer, packet_id });
}

/// 异步版本: 发送 PUBREC (QoS 2 第一步) - 只准备数据不发送
pub fn sendPubrecAsync(writer: *packet.Writer, packet_id: u16) !void {
    writer.reset();
    try writer.startPacket(mqtt.Command.PUBREC);
    try writer.writeTwoBytes(packet_id);
    try writer.finishPacket();
}

/// 发送 PUBCOMP (QoS 2 第三步)
pub fn sendPubcomp(writer: *packet.Writer, client: *Client, packet_id: u16) !void {
    writer.reset();
    try writer.startPacket(mqtt.Command.PUBCOMP);
    try writer.writeTwoBytes(packet_id);
    try writer.finishPacket();
    try writer.writeToStream(&client.stream);
    logger.debug("Server sent PUBCOMP to {s} (packet_id={d})", .{ client.identifer, packet_id });
}
