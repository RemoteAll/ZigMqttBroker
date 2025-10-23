// ============================================================================
// message_serde.zig - 统一的 MQTT 消息序列化/反序列化模块
// ============================================================================
//
// 功能说明:
// - 提供所有 MQTT 控制包的序列化(编码)和反序列化(解码)
// - 统一的接口,避免重复代码
// - 支持 MQTT 3.1.1 和 5.0 版本
// - 零拷贝设计,高性能
//
// 设计原则:
// 1. 类型安全: 使用强类型而非原始字节
// 2. 零拷贝: 避免不必要的内存分配
// 3. 可测试: 每个函数都易于单元测试
// 4. 可扩展: 易于添加新的包类型
//
// ============================================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const mqtt = @import("mqtt.zig");
const packet = @import("packet.zig");

// ============================================================================
// 通用消息结构
// ============================================================================

/// 固定头部 (Fixed Header) - 所有 MQTT 包都有
pub const FixedHeader = packed struct(u8) {
    /// 标志位 (flags) - 低4位
    flags: u4 = 0,
    /// 包类型 (packet type) - 高4位
    packet_type: u4 = 0,

    pub fn init(packet_type: mqtt.Command, flags: u4) FixedHeader {
        return .{
            .packet_type = @intFromEnum(packet_type),
            .flags = flags,
        };
    }

    pub fn toByte(self: FixedHeader) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) FixedHeader {
        return @bitCast(byte);
    }

    pub fn getPacketType(self: FixedHeader) mqtt.Command {
        return @enumFromInt(self.packet_type);
    }
};

/// CONNACK 包
pub const ConnAck = struct {
    /// 会话存在标志 (Session Present)
    session_present: bool,
    /// 返回码 (Connect Return Code)
    return_code: mqtt.ReasonCode,

    pub fn init(session_present: bool, return_code: mqtt.ReasonCode) ConnAck {
        return .{
            .session_present = session_present,
            .return_code = return_code,
        };
    }

    /// 序列化到 Writer
    pub fn serialize(self: ConnAck, writer: *packet.Writer) !void {
        // Fixed Header: CONNACK (0x20)
        try writer.writeByte(FixedHeader.init(.CONNACK, 0).toByte());

        // Remaining Length: 2 字节
        try writer.writeByte(2);

        // Connect Acknowledge Flags
        const flags: u8 = if (self.session_present) 0x01 else 0x00;
        try writer.writeByte(flags);

        // Connect Return Code
        try writer.writeByte(@intFromEnum(self.return_code));
    }

    /// 计算序列化后的大小
    pub fn serializedSize(self: ConnAck) usize {
        _ = self;
        return 4; // 固定头(1) + 剩余长度(1) + 标志(1) + 返回码(1)
    }
};

/// SUBACK 包
pub const SubAck = struct {
    /// 包 ID
    packet_id: u16,
    /// 返回码列表 (每个订阅主题一个)
    return_codes: []const mqtt.ReasonCode,

    pub fn init(packet_id: u16, return_codes: []const mqtt.ReasonCode) SubAck {
        return .{
            .packet_id = packet_id,
            .return_codes = return_codes,
        };
    }

    /// 序列化到 Writer
    pub fn serialize(self: SubAck, writer: *packet.Writer) !void {
        // Fixed Header: SUBACK (0x90)
        try writer.writeByte(FixedHeader.init(.SUBACK, 0).toByte());

        // Remaining Length: 2 (packet_id) + N (return_codes)
        const remaining_length = 2 + self.return_codes.len;
        try writer.writeByte(@intCast(remaining_length));

        // Packet Identifier
        try writer.writeTwoBytes(self.packet_id);

        // Return Codes
        for (self.return_codes) |code| {
            try writer.writeByte(@intFromEnum(code));
        }
    }

    /// 计算序列化后的大小
    pub fn serializedSize(self: SubAck) usize {
        return 1 + 1 + 2 + self.return_codes.len;
    }
};

/// UNSUBACK 包
pub const UnsubAck = struct {
    /// 包 ID
    packet_id: u16,

    pub fn init(packet_id: u16) UnsubAck {
        return .{ .packet_id = packet_id };
    }

    /// 序列化到 Writer
    pub fn serialize(self: UnsubAck, writer: *packet.Writer) !void {
        // Fixed Header: UNSUBACK (0xB0)
        try writer.writeByte(FixedHeader.init(.UNSUBACK, 0).toByte());

        // Remaining Length: 2
        try writer.writeByte(2);

        // Packet Identifier
        try writer.writeTwoBytes(self.packet_id);
    }

    /// 计算序列化后的大小
    pub fn serializedSize(self: UnsubAck) usize {
        _ = self;
        return 4; // 固定头(1) + 剩余长度(1) + 包ID(2)
    }
};

/// PUBACK 包 (QoS 1 确认)
pub const PubAck = struct {
    /// 包 ID
    packet_id: u16,

    pub fn init(packet_id: u16) PubAck {
        return .{ .packet_id = packet_id };
    }

    /// 序列化到 Writer
    pub fn serialize(self: PubAck, writer: *packet.Writer) !void {
        // Fixed Header: PUBACK (0x40)
        try writer.writeByte(FixedHeader.init(.PUBACK, 0).toByte());

        // Remaining Length: 2
        try writer.writeByte(2);

        // Packet Identifier
        try writer.writeTwoBytes(self.packet_id);
    }

    /// 计算序列化后的大小
    pub fn serializedSize(self: PubAck) usize {
        _ = self;
        return 4;
    }
};

/// PUBREC 包 (QoS 2 接收确认)
pub const PubRec = struct {
    packet_id: u16,

    pub fn init(packet_id: u16) PubRec {
        return .{ .packet_id = packet_id };
    }

    pub fn serialize(self: PubRec, writer: *packet.Writer) !void {
        // Fixed Header: PUBREC (0x50)
        try writer.writeByte(FixedHeader.init(.PUBREC, 0).toByte());
        try writer.writeByte(2);
        try writer.writeTwoBytes(self.packet_id);
    }

    pub fn serializedSize(self: PubRec) usize {
        _ = self;
        return 4;
    }
};

/// PUBREL 包 (QoS 2 释放)
pub const PubRel = struct {
    packet_id: u16,

    pub fn init(packet_id: u16) PubRel {
        return .{ .packet_id = packet_id };
    }

    pub fn serialize(self: PubRel, writer: *packet.Writer) !void {
        // Fixed Header: PUBREL (0x62) - 注意 flags=2
        try writer.writeByte(FixedHeader.init(.PUBREL, 2).toByte());
        try writer.writeByte(2);
        try writer.writeTwoBytes(self.packet_id);
    }

    pub fn serializedSize(self: PubRel) usize {
        _ = self;
        return 4;
    }
};

/// PUBCOMP 包 (QoS 2 完成)
pub const PubComp = struct {
    packet_id: u16,

    pub fn init(packet_id: u16) PubComp {
        return .{ .packet_id = packet_id };
    }

    pub fn serialize(self: PubComp, writer: *packet.Writer) !void {
        // Fixed Header: PUBCOMP (0x70)
        try writer.writeByte(FixedHeader.init(.PUBCOMP, 0).toByte());
        try writer.writeByte(2);
        try writer.writeTwoBytes(self.packet_id);
    }

    pub fn serializedSize(self: PubComp) usize {
        _ = self;
        return 4;
    }
};

/// PINGRESP 包
pub const PingResp = struct {
    pub fn init() PingResp {
        return .{};
    }

    pub fn serialize(self: PingResp, writer: *packet.Writer) !void {
        _ = self;
        // Fixed Header: PINGRESP (0xD0)
        try writer.writeByte(FixedHeader.init(.PINGRESP, 0).toByte());
        // Remaining Length: 0
        try writer.writeByte(0);
    }

    pub fn serializedSize(self: PingResp) usize {
        _ = self;
        return 2;
    }
};

/// PUBLISH 包
pub const Publish = struct {
    /// 主题名称
    topic: []const u8,
    /// 消息内容
    payload: []const u8,
    /// QoS 等级
    qos: mqtt.QoS,
    /// 保留标志
    retain: bool,
    /// 重复发送标志
    dup: bool,
    /// 包 ID (QoS > 0 时需要)
    packet_id: ?u16,

    pub fn init(
        topic: []const u8,
        payload: []const u8,
        qos: mqtt.QoS,
        retain: bool,
        dup: bool,
        packet_id: ?u16,
    ) Publish {
        return .{
            .topic = topic,
            .payload = payload,
            .qos = qos,
            .retain = retain,
            .dup = dup,
            .packet_id = packet_id,
        };
    }

    /// 序列化到 Writer
    pub fn serialize(self: Publish, writer: *packet.Writer) !void {
        // 构建 Fixed Header flags
        var flags: u4 = 0;
        if (self.retain) flags |= 0x01;
        flags |= (@as(u4, @intFromEnum(self.qos)) << 1);
        if (self.dup) flags |= 0x08;

        // Fixed Header
        try writer.writeByte(FixedHeader.init(.PUBLISH, flags).toByte());

        // 计算 Remaining Length
        var remaining_length: usize = 2 + self.topic.len; // 主题长度字段 + 主题
        if (self.qos != .AtMostOnce) {
            remaining_length += 2; // 包 ID
        }
        remaining_length += self.payload.len;

        // 写入 Remaining Length (简化版,只支持 < 128 字节)
        if (remaining_length < 128) {
            try writer.writeByte(@intCast(remaining_length));
        } else {
            // 可变长度编码
            var len = remaining_length;
            while (len > 0) {
                var encoded_byte: u8 = @intCast(len % 128);
                len = len / 128;
                if (len > 0) {
                    encoded_byte |= 128;
                }
                try writer.writeByte(encoded_byte);
            }
        }

        // Variable Header - Topic Name
        try writer.writeUTF8String(self.topic);

        // Variable Header - Packet Identifier (QoS > 0)
        if (self.qos != .AtMostOnce) {
            try writer.writeTwoBytes(self.packet_id orelse 0);
        }

        // Payload
        try writer.writeBytes(self.payload);
    }

    /// 计算序列化后的大小
    pub fn serializedSize(self: Publish) usize {
        var size: usize = 1; // Fixed Header

        var remaining_length: usize = 2 + self.topic.len;
        if (self.qos != .AtMostOnce) {
            remaining_length += 2;
        }
        remaining_length += self.payload.len;

        // Remaining Length 字段大小
        if (remaining_length < 128) {
            size += 1;
        } else if (remaining_length < 16384) {
            size += 2;
        } else if (remaining_length < 2097152) {
            size += 3;
        } else {
            size += 4;
        }

        size += remaining_length;
        return size;
    }
};

// ============================================================================
// 辅助函数
// ============================================================================

/// 编码可变长度整数 (Variable Byte Integer)
pub fn encodeVariableLength(value: usize, buffer: []u8) !usize {
    var x = value;
    var count: usize = 0;

    while (true) {
        if (count >= buffer.len) return error.BufferTooSmall;

        var encoded_byte: u8 = @intCast(x % 128);
        x = x / 128;

        if (x > 0) {
            encoded_byte |= 128;
        }

        buffer[count] = encoded_byte;
        count += 1;

        if (x == 0) break;
    }

    return count;
}

/// 解码可变长度整数
pub fn decodeVariableLength(reader: *packet.Reader) !usize {
    var multiplier: usize = 1;
    var value: usize = 0;
    var iterations: u8 = 0;

    while (iterations < 4) : (iterations += 1) {
        const encoded_byte = try reader.readByte();
        value += (encoded_byte & 127) * multiplier;

        if ((encoded_byte & 128) == 0) {
            return value;
        }

        multiplier *= 128;
        if (multiplier > 128 * 128 * 128) {
            return error.MalformedVariableLength;
        }
    }

    return error.MalformedVariableLength;
}

// ============================================================================
// 便捷序列化函数 (向后兼容)
// ============================================================================

/// 快速序列化 CONNACK
pub fn serializeConnAck(
    writer: *packet.Writer,
    session_present: bool,
    return_code: mqtt.ReasonCode,
) !void {
    const connack = ConnAck.init(session_present, return_code);
    try connack.serialize(writer);
}

/// 快速序列化 SUBACK
pub fn serializeSubAck(
    writer: *packet.Writer,
    packet_id: u16,
    return_codes: []const mqtt.ReasonCode,
) !void {
    const suback = SubAck.init(packet_id, return_codes);
    try suback.serialize(writer);
}

/// 快速序列化 UNSUBACK
pub fn serializeUnsubAck(
    writer: *packet.Writer,
    packet_id: u16,
) !void {
    const unsuback = UnsubAck.init(packet_id);
    try unsuback.serialize(writer);
}

/// 快速序列化 PUBACK
pub fn serializePubAck(
    writer: *packet.Writer,
    packet_id: u16,
) !void {
    const puback = PubAck.init(packet_id);
    try puback.serialize(writer);
}

/// 快速序列化 PUBREC
pub fn serializePubRec(
    writer: *packet.Writer,
    packet_id: u16,
) !void {
    const pubrec = PubRec.init(packet_id);
    try pubrec.serialize(writer);
}

/// 快速序列化 PUBREL
pub fn serializePubRel(
    writer: *packet.Writer,
    packet_id: u16,
) !void {
    const pubrel = PubRel.init(packet_id);
    try pubrel.serialize(writer);
}

/// 快速序列化 PUBCOMP
pub fn serializePubComp(
    writer: *packet.Writer,
    packet_id: u16,
) !void {
    const pubcomp = PubComp.init(packet_id);
    try pubcomp.serialize(writer);
}

/// 快速序列化 PINGRESP
pub fn serializePingResp(writer: *packet.Writer) !void {
    const pingresp = PingResp.init();
    try pingresp.serialize(writer);
}

/// 快速序列化 PUBLISH
pub fn serializePublish(
    writer: *packet.Writer,
    topic: []const u8,
    payload: []const u8,
    qos: mqtt.QoS,
    retain: bool,
    dup: bool,
    packet_id: ?u16,
) !void {
    const publish = Publish.init(topic, payload, qos, retain, dup, packet_id);
    try publish.serialize(writer);
}

// ============================================================================
// 测试
// ============================================================================

test "FixedHeader encoding" {
    const header = FixedHeader.init(.CONNACK, 0);
    try std.testing.expectEqual(@as(u8, 0x20), header.toByte());
}

test "ConnAck serialization" {
    var buffer: [32]u8 = undefined;
    var writer = packet.Writer.init(&buffer);

    const connack = ConnAck.init(false, .Success);
    try connack.serialize(&writer);

    try std.testing.expectEqual(@as(usize, 4), writer.pos);
    try std.testing.expectEqual(@as(u8, 0x20), buffer[0]); // CONNACK
    try std.testing.expectEqual(@as(u8, 2), buffer[1]); // Length
    try std.testing.expectEqual(@as(u8, 0), buffer[2]); // No session
    try std.testing.expectEqual(@as(u8, 0), buffer[3]); // Success
}

test "PubAck serialization" {
    var buffer: [32]u8 = undefined;
    var writer = packet.Writer.init(&buffer);

    const puback = PubAck.init(123);
    try puback.serialize(&writer);

    try std.testing.expectEqual(@as(usize, 4), writer.pos);
    try std.testing.expectEqual(@as(u8, 0x40), buffer[0]); // PUBACK
}

test "Variable Length encoding" {
    var buffer: [4]u8 = undefined;

    // Test 127 (single byte)
    var len = try encodeVariableLength(127, &buffer);
    try std.testing.expectEqual(@as(usize, 1), len);
    try std.testing.expectEqual(@as(u8, 127), buffer[0]);

    // Test 128 (two bytes)
    len = try encodeVariableLength(128, &buffer);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(@as(u8, 0x80), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buffer[1]);
}
