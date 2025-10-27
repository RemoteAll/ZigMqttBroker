const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const posix = std.posix;
const packet = @import("packet.zig");
const mqtt = @import("mqtt.zig");
const Client = @import("client.zig").Client;
const SubscribePacket = @import("mqtt/subscribe_packet.zig").SubscribePacket;
const assert = std.debug.assert;

pub const SubscribeError = error{
    InvalidPacket,
    TopicMustBePresent,
    InvalidQoS,
};

const SubackReturnCode = enum(u8) {
    SuccessQos0 = 0x00,
    SuccessQos1 = 0x01,
    SuccessQos2 = 0x02,
    Failure = 0x80,

    pub fn fromValue(value: u8) ?SubackReturnCode {
        return switch (value) {
            0x00 => .SuccessQos0,
            0x01 => .SuccessQos1,
            0x02 => .SuccessQos2,
            0x80 => .Failure,
            else => null,
        };
    }
};

pub fn read(reader: *packet.Reader, client: *Client, allocator: Allocator) !*SubscribePacket {
    const packet_id = try reader.readTwoBytes();

    // 在堆上分配 SubscribePacket，而不是栈上
    const sp = try allocator.create(SubscribePacket);
    errdefer allocator.destroy(sp);

    sp.* = SubscribePacket.init(allocator, packet_id);
    errdefer sp.deinit(allocator);

    sp.subscription_identifier = null;
    // todo - complete  createing the subscprtion packet

    const topic_filter = try reader.readUTF8String(false) orelse {
        std.debug.print("ERROR: Topic filter is null or empty\n", .{});
        return SubscribeError.TopicMustBePresent;
    };

    if (topic_filter.len == 0) {
        std.debug.print("ERROR: Topic filter length is 0\n", .{});
        return SubscribeError.TopicMustBePresent;
    }

    std.debug.print("DEBUG: Subscribing to topic: '{s}' (length: {d})\n", .{ topic_filter, topic_filter.len });

    // The upper 6 bits of the Requested QoS byte are not used in the current version of the protocol.
    // They are reserved for future use.
    // The Server MUST treat a SUBSCRIBE packet as malformed and close the Network Connection if any of Reserved bits
    // in the payload are non-zero, or QoS is not 0,1 or 2 [MQTT-3-8.3-4].
    const qos = try reader.readByte();
    const topic_filter_qos = mqtt.QoS.fromU8(qos) orelse return SubscribeError.InvalidQoS;

    try sp.topics.append(allocator, SubscribePacket.SubscribeTopic{
        .filter = topic_filter,
        .options = SubscribePacket.SubscriptionOptions{
            .reserved = 0,
            .retain_handling = 0,
            .retain_as_published = false,
            .no_local = false,
            .qos = topic_filter_qos,
        },
    });
    _ = client;

    // const subscription = Client.Subscription{
    //     .topic_filter = topic_filter,
    //     .qos = topic_filter_qos,
    //     .no_local = false,
    //     .retain_as_published = false,
    //     .retain_handling = .SendRetained,
    //     .subscription_identifier = null,
    // };
    // try client.addSubscription(subscription);

    return sp;
}

pub fn suback(writer: *packet.Writer, stream: *net.Stream, packet_id: u16, client: *Client) (packet.PacketWriterError || SubscribeError || posix.WriteError)!void {
    std.debug.print("Sending SUBACK to client {}\n", .{client.id});

    try writer.startPacket(mqtt.Command.SUBACK);

    // variable header
    try writer.writeTwoBytes(packet_id);

    // return code
    try writer.writeByte(@intFromEnum(SubackReturnCode.SuccessQos0));

    try writer.finishPacket();

    writer.writeToStream(stream) catch |err| {
        std.log.err("❌ CRITICAL: Failed to write SUBACK to stream: {any}", .{err});
        std.log.err("   This will cause client timeout and reconnection!", .{});
        return error.StreamWriteError;
    };

    std.log.info("✅ SUBACK sent successfully to client {}", .{client.id});
}

/// 异步版本的 suback - 只准备数据,不直接发送
pub fn subackAsync(writer: *packet.Writer, packet_id: u16, client: *Client) !void {
    std.debug.print("Preparing SUBACK for client {}\n", .{client.id});

    try writer.startPacket(mqtt.Command.SUBACK);

    // variable header
    try writer.writeTwoBytes(packet_id);

    // return code
    try writer.writeByte(@intFromEnum(SubackReturnCode.SuccessQos0));

    try writer.finishPacket();
}
