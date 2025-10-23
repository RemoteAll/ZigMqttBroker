const std = @import("std");
const messages = @import("messages.zig");

const AnyWriter = std.io.AnyWriter;
const AnyReader = std.io.AnyReader;
const Allocator = std.mem.Allocator;
const QosLevel = messages.QosLevel;
const PacketType = messages.PacketType;

pub fn encodeLength(writer: AnyWriter, len: usize) !usize {
    var bytes: usize = 0;
    var l = len;

    while (l > 0) {
        if (bytes + 1 > messages.MAX_LEN_BYTES) {
            return 0;
        }

        var d = l % 128;
        l /= 128;

        if (l > 0) {
            d |= 128;
        }

        try writer.writeByte(@intCast(d));
        bytes += 1;
    }

    return bytes;
}

pub fn decodeLength(reader: AnyReader) !usize {
    var c: u8 = 128;
    var multiplier: usize = 1;
    var value: usize = 0;

    while ((c & 128) != 0) {
        c = try reader.readByte();
        value += @as(usize, @intCast(c & 127)) * multiplier;
        multiplier *= 128;
    }

    return value;
}

pub fn decodeLengthSize(reader: AnyReader) !struct {usize, usize} {
    var c: u8 = 128;
    var multiplier: usize = 1;
    var value: usize = 0;

    var bytes_read: usize = 0;
    while ((c & 128) != 0) {
        c = try reader.readByte();
        bytes_read += 1;
        value += @as(usize, @intCast(c & 127)) * multiplier;
        multiplier *= 128;
    }

    return .{value, bytes_read};
}

// DECODER FUNCTIONS

pub fn decodeString(allocator: Allocator, reader: AnyReader) ![]u8 {
    const len = try reader.readInt(u16, .big);
    var buffer = try allocator.alloc(u8, len);
    errdefer allocator.free(buffer);

    _ = try reader.read(buffer[0..len]);
    return buffer;
}

pub fn decodeProtocolName(reader: AnyReader) !void {
    const len = try reader.readInt(u16, .big);
    if (len != 4) {
        std.debug.print("Len is: {d} instead of 4\n", .{len});
        return error.InvalidProtocolName;
    }

    var name_buffer: [4]u8 = undefined;
    _ = try reader.read(name_buffer[0..4]);

    if (!std.mem.eql(u8, &name_buffer, "MQTT")) {
        return error.InvalidProtocolName;
    }
}

pub fn readMQTTConnect(allocator: Allocator, header: messages.MQTTHeader, reader: AnyReader) !messages.MQTTMessage {
    var connect = messages.MQTTConnect{};

    // Read header
    connect.header = header;

    // Decode payload length
    const len = try decodeLength(reader);
    std.debug.print("Remaining len is: {d}\n", .{len});

    // Check correct protocol name
    try decodeProtocolName(reader);

    _ = try reader.readByte(); // Read protocol level

    // Read connect flags
    connect.flgs = @bitCast(try reader.readByte());

    // Read keepalive
    connect.payload.keepalive = try reader.readInt(u16, .big);

    // Read cid length
    const cid_len = try reader.readInt(u16, .big);
    std.debug.print("CID len is: {d}\n", .{cid_len});

    // Check CID and read it
    if (cid_len > 0) {
        var cid_buffer = try allocator.alloc(u8, cid_len);
        errdefer allocator.free(cid_buffer);

        _ = try reader.read(cid_buffer[0..cid_len]);
        connect.payload.client_id = cid_buffer;
    }

    if (connect.flgs.will == 1) {
        connect.payload.will_topic = try decodeString(allocator, reader);
        connect.payload.will_message = try decodeString(allocator, reader);
    }

    if (connect.flgs.username == 1) {
        connect.payload.username = try decodeString(allocator, reader);
    }

    if (connect.flgs.password == 1) {
        connect.payload.password = try decodeString(allocator, reader);
    }

    return .{ .Connect = connect };
}

pub fn readMQTTPublish(allocator: Allocator, header: messages.MQTTHeader, reader: AnyReader) !messages.MQTTMessage {
    var publish = messages.MQTTPublish{};

    // Read header
    publish.header = header;

    // Decode payload length
    var message_len = try decodeLength(reader);

    publish.topic = try decodeString(allocator, reader);
    publish.topic_len = @intCast(publish.topic.len);

    if (publish.header.qos > @intFromEnum(QosLevel.AT_MOST_ONCE)) {
        publish.pkt_id = try reader.readInt(u16, .big);
        message_len -= 2;
    }

    message_len -= 2 * publish.topic_len;
    publish.payload_len = @intCast(message_len);

    publish.payload = try allocator.alloc(u8, message_len);
    errdefer allocator.free(publish.payload);

    _ = try reader.read(publish.payload[0..message_len]);

    return .{ .Publish = publish};
}

pub fn readMQTTSubscribe(allocator: Allocator, header: messages.MQTTHeader, reader: AnyReader) !messages.MQTTMessage {
    var subscribe = messages.MQTTSubscribe{
        .tuples = std.ArrayList(messages.SubscribeTuple).init(allocator),
    };

    // Read header
    subscribe.header = header;

    // Decode payload length
    var message_len = try decodeLength(reader);

    subscribe.pkt_id = try reader.readInt(u16, .big);
    message_len -= 2;

    var i: usize = 0;
    while (message_len > 0) : (i += 1) {
        message_len -= 2;
        var tuple = messages.SubscribeTuple{
            .topic = try decodeString(allocator, reader),
            .qos = try reader.readInt(u8, .big),
        };

        tuple.topic_len = @intCast(tuple.topic.len);

        message_len -= tuple.topic_len;
        try subscribe.tuples.append(tuple);
        message_len -= 1;
    }

    subscribe.tuples_len = @intCast(i);

    return .{ .Subscribe = subscribe};
}

pub fn readMQTTUnsubscribe(allocator: Allocator, header: messages.MQTTHeader, reader: AnyReader) !messages.MQTTMessage {
    var unsubscribe = messages.MQTTUnsubscribe{
        .tuples = std.ArrayList(messages.UnsubscribeTuple).init(allocator),
    };

    // Read header
    unsubscribe.header = header;

    // Decode payload length
    var message_len = try decodeLength(reader);

    unsubscribe.pkt_id = try reader.readInt(u16, .big);
    message_len -= 2;

    var i: usize = 0;
    while (message_len > 0) : (i += 1) {
        message_len -= 2;
        var tuple = messages.UnsubscribeTuple{
            .topic = try decodeString(allocator, reader),
        };

        tuple.topic_len = @intCast(tuple.topic.len);

        message_len -= tuple.topic_len;
        try unsubscribe.tuples.append(tuple);
    }

    unsubscribe.tuples_len = @intCast(i);

    return .{ .Unsubscribe = unsubscribe};
}

pub fn readMQTTAck(_: Allocator, header: messages.MQTTHeader, reader: AnyReader) !messages.MQTTMessage {
    var ack = messages.MQTTAck{};

    // Read header
    ack.header = header;

    // Decode payload length
    _ = try decodeLength(reader);

    ack.pkt_id = try reader.readInt(u16, .big);

    return .{ .Ack = ack };
}

pub fn readMQTTPacket(allocator: Allocator, reader: AnyReader) !messages.MQTTMessage {
    const mqtt_header: messages.MQTTHeader = @bitCast(try reader.readByte());

    std.debug.print("Header is: {any}\n", .{mqtt_header});

    switch (@as(PacketType, @enumFromInt(mqtt_header.type))) {
        PacketType.DISCONNECT => return .{ .Disconnect = messages.MQTTAck{.header = mqtt_header} },
        PacketType.PINGREQ,
        PacketType.PINGRESP => return .{ .Header = mqtt_header },

        PacketType.CONNECT => return readMQTTConnect(allocator, mqtt_header, reader),
        PacketType.PUBLISH => return readMQTTPublish(allocator, mqtt_header, reader),

        PacketType.PUBACK,
        PacketType.PUBREC,
        PacketType.PUBREL,
        PacketType.PUBCOMP => return readMQTTAck(allocator, mqtt_header, reader),

        PacketType.SUBSCRIBE => return readMQTTSubscribe(allocator, mqtt_header, reader),
        PacketType.UNSUBSCRIBE => return readMQTTUnsubscribe(allocator, mqtt_header, reader),

        else => return error.InvalidPacketType,
    }
}

// ENCODER FUNCTIONS

pub fn writeMQTTHeader(writer: AnyWriter, header: messages.MQTTHeader) !usize {
    try writer.writeByte(@bitCast(header));
    const written = try encodeLength(writer, 0);

    return 1 + written;
}

pub fn writeMQTTAck(writer: AnyWriter, message: messages.MQTTAck) !usize {
    try writer.writeByte(@bitCast(message.header));
    const written = try encodeLength(writer, messages.MQTT_HEADER_LEN);
    try writer.writeInt(u16, message.pkt_id, .big);

    return 3 + written;
}

pub fn writeMQTTConnack(writer: AnyWriter, message: messages.MQTTConnack) !usize {
    try writer.writeByte(@bitCast(message.header));
    const written = try encodeLength(writer, messages.MQTT_HEADER_LEN);
    try writer.writeByte(@bitCast(message.flgs));
    try writer.writeInt(u8, message.return_code, .big);

    return 3 + written;
}

pub fn writeMQTTSuback(writer: AnyWriter, message: messages.MQTTSuback) !usize {
    try writer.writeByte(@bitCast(message.header));
    var written = try encodeLength(writer, message.return_codes_len + 2);
    try writer.writeInt(u16, message.pkt_id, .big);

    for (0..message.return_codes_len) |idx| {
        try writer.writeInt(u8, message.return_codes[idx], .big);
        written += 1;
    }

    return 3 + written;
}

pub fn writeMQTTPublish(writer: AnyWriter, message: messages.MQTTPublish) !usize {
    var pkt_len: usize = messages.MQTT_HEADER_LEN + 2 + message.topic_len + message.payload_len;
    if (message.header.qos > @intFromEnum(QosLevel.AT_MOST_ONCE)) {
        pkt_len += 2;
    }

    var remaining_len_offset: usize = 0;
    if (pkt_len - 1 > 0x200000) {
        remaining_len_offset = 3;
    } else if (pkt_len - 1 > 0x4000) {
        remaining_len_offset = 2;
    } else if (pkt_len - 1 > 0x80) {
        remaining_len_offset = 1;
    }

    pkt_len += remaining_len_offset;

    try writer.writeByte(@bitCast(message.header));

    const len = pkt_len - messages.MQTT_HEADER_LEN - remaining_len_offset;
    var written = try encodeLength(writer, len);

    try writer.writeInt(u16, message.topic_len, .big);
    written += try writer.write(message.topic);

    if (message.header.qos > @intFromEnum(QosLevel.AT_MOST_ONCE)) {
        try writer.writeInt(u16, message.pkt_id, .big);
        written += 2;
    }


    written += try writer.write(message.payload);

    return written + 3;
}

pub const WriteMQTTError = error{
    InvalidPacketType,
    InvalidProtocolName,
    WriteMQTTError,
};

pub fn writeMQTTMessage(writer: AnyWriter, message: messages.MQTTMessage, msg_type: u8) WriteMQTTError!usize {
    return switch (@as(PacketType, @enumFromInt(msg_type))) {
        PacketType.PINGREQ, PacketType.PINGRESP => writeMQTTAck(writer, message.Ping),
        PacketType.CONNACK => writeMQTTConnack(writer, message.Connack),
        PacketType.PUBLISH => writeMQTTPublish(writer, message.Publish),

        PacketType.PUBACK,
        PacketType.PUBREC,
        PacketType.PUBREL,
        PacketType.PUBCOMP => writeMQTTAck(writer, message.Ack),

        PacketType.SUBACK => writeMQTTSuback(writer, message.Suback),
        PacketType.UNSUBACK => writeMQTTAck(writer, message.Ack),

        else => return error.InvalidPacketType,
    } catch {
        return error.WriteMQTTError;
    };
}


test "Encode len" {
    var buf: [4]u8 = undefined;
    @memset(&buf, 0);
    var stream = std.io.fixedBufferStream(&buf);

    _ = try encodeLength(stream.writer().any(), 128*128);

    const expected: [4]u8 = .{0x80, 0x80, 0x01, 0x00};
    try std.testing.expectEqual(expected, buf);
}

test "Decode len" {
    var input: [4]u8 = .{0x80, 0x80, 0x01, 0x00};
    var stream = std.io.fixedBufferStream(&input);

    const got = try decodeLength(stream.reader().any());
    try std.testing.expectEqual(128*128, got);
}

test "Decode connect flags" {
    var input: [1]u8 = .{0b11001100};
    var stream = std.io.fixedBufferStream(&input);

    const got = try stream.reader().readByte();

    var c = messages.MQTTConnect{};
    c.flgs = @bitCast(got);

    try std.testing.expectEqual(0, c.flgs.reserved);
    try std.testing.expectEqual(0, c.flgs.clean_session);
    try std.testing.expectEqual(1, c.flgs.will);
    try std.testing.expectEqual(1, c.flgs.will_qos);
    try std.testing.expectEqual(0, c.flgs.will_retain);
    try std.testing.expectEqual(1, c.flgs.username);
    try std.testing.expectEqual(1, c.flgs.password);
}

test "Decode connect" {
    var input = [_]u8{0x10, 0x10, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3C, 0x00, 0x04, 0x44, 0x49, 0x47, 0x49};
    var stream = std.io.fixedBufferStream(&input);

    const got = try readMQTTPacket(std.testing.allocator, stream.reader().any());
    defer std.testing.allocator.free(got.Connect.payload.client_id);

    std.debug.print("FLAGS: {any}\n", .{got.Connect.flgs});

    try std.testing.expect(std.mem.eql(u8, "DIGI", got.Connect.payload.client_id));
}
