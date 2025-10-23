const std = @import("std");

pub const MQTT_HEADER_LEN: usize = 2;
pub const MQTT_ACK_LEN: usize = 4;

pub const CONNACK_BYTE: u8 = 0x20;
pub const PUBLISH_BYTE: u8 = 0x30;
pub const PUBACK_BYTE: u8 = 0x40;
pub const PUBREC_BYTE: u8 = 0x50;
pub const PUBREL_BYTE: u8 = 0x60;
pub const PUBCOMP_BYTE: u8 = 0x70;
pub const SUBACK_BYTE: u8 = 0x90;
pub const UNSUBACK_BYTE: u8 = 0xB0;
pub const PINGRESP_BYTE: u8 = 0xD0;

pub const MAX_LEN_BYTES: usize = 4;

pub const PacketType = enum(u8) {
    CONNECT = 1,
    CONNACK = 2,
    PUBLISH = 3,
    PUBACK = 4,
    PUBREC = 5,
    PUBREL = 6,
    PUBCOMP = 7,
    SUBSCRIBE = 8,
    SUBACK = 9,
    UNSUBSCRIBE = 10,
    UNSUBACK = 11,
    PINGREQ = 12,
    PINGRESP = 13,
    DISCONNECT = 14,
};

pub const QosLevel = enum(u8) {
    AT_MOST_ONCE = 0,
    AT_LEAST_ONCE = 1,
    EXACTLY_ONCE = 2,
};

pub const MQTTHeader = packed struct(u8) {
    retain: u1 = 0,
    qos: u2 = 0,
    dup: u1 = 0,
    type: u4 = 0,

    pub fn format(
        self: MQTTHeader,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "Header:\n \tretain: {}\n\tqos: {}\n\tdup: {}\n\ttype: {}\n", .{
            self.retain,
            self.qos,
            self.dup,
            self.type,
        });
    }
};

fn newMQTTMessageHeader(header: MQTTHeader) MQTTMessage {
    return .{ .Header = header };
}

pub const MQTTConnect = struct {
    header: MQTTHeader = .{},
    flgs: packed struct(u8) {
        reserved: u1 = 0,
        clean_session: u1 = 0,
        will: u1 = 0,
        will_qos: u2 = 0,
        will_retain: u1 = 0,
        password: u1 = 0,
        username: u1 = 0,
    } = .{},
    payload: struct {
        keepalive: u16 = 0,
        client_id: []u8 = undefined,
        username: []u8 = undefined,
        password: []u8 = undefined,
        will_topic: []u8 = undefined,
        will_message: []u8 = undefined,
    } = .{},

    pub fn format(
        self: MQTTConnect,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "{}", .{
            self.header,
        });

        try std.fmt.format(out_stream, "Flags: \n\treserved: {}\n\tclean_session: {}\n\twill: {}\n\twill_qos: {}\n\twill_retain: {}\n\tpassword: {}\n\tusername:{}\n", .{
            self.flgs.reserved,
            self.flgs.clean_session,
            self.flgs.will,
            self.flgs.will_qos,
            self.flgs.will_retain,
            self.flgs.password,
            self.flgs.username,
        });

        try std.fmt.format(out_stream, "Payload: \n\tkeepalive: {}\n\tclient_id: {s}\n\tusername: {s}\n\tpassword: {s}\n\twill_topic: {s}\n\twill_message: {s}", .{
            self.payload.keepalive,
            self.payload.client_id,
            self.payload.username,
            self.payload.password,
            self.payload.will_topic,
            self.payload.will_message,
        });
    }
};

pub const MQTTConnack = struct {
    header: MQTTHeader = .{},
    flgs: packed struct(u8) {
        session_present: u1 = 0,
        reserved: u7 = 0,
    },
    return_code: u8 = 0,

    pub fn format(
        self: MQTTConnack,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "{}Flags: \n\tsession: {}\nReturn Code: {}\n", .{
            self.header,
            self.flgs.session_present,
            self.return_code,
        });
    }
};

pub fn newMQTTMessageConnack(header: MQTTHeader, cflags: u8, rc: u8) MQTTConnack {
    return MQTTConnack{
        .header = header,
        .flgs = @bitCast(cflags),
        .return_code = rc,
    };
}

pub const MQTTSubscribe = struct {
    header: MQTTHeader = .{},
    pkt_id: u16 = 0,
    tuples_len: u16 = 0,
    tuples: std.ArrayList(SubscribeTuple) = undefined,

    pub fn format(
        self: MQTTSubscribe,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "{}Pkt ID: {}\nTuples: {any}\n", .{
            self.header,
            self.pkt_id,
            self.tuples,
        });
    }
};

pub const SubscribeTuple = struct {
    topic_len: u16 = 0,
    topic: []u8 = undefined,
    qos: u8 = 0,

    pub fn format(
        self: SubscribeTuple,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "T: \n\tTopic: {s}\n\tQos: {}\n", .{
            self.topic,
            self.qos,
        });
    }
};

pub const MQTTUnsubscribe = struct {
    header: MQTTHeader = .{},
    pkt_id: u16 = 0,
    tuples_len: u16 = 0,
    tuples: std.ArrayList(UnsubscribeTuple) = undefined,

    pub fn format(
        self: MQTTUnsubscribe,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "{}Pkt ID: {}\nTuples: {any}\n", .{
            self.header,
            self.pkt_id,
            self.tuples,
        });
    }
};

pub const UnsubscribeTuple = struct {
    topic_len: u16 = 0,
    topic: []u8 = undefined,

    pub fn format(
        self: UnsubscribeTuple,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "T: \n\tTopic: {s}\n", .{
            self.topic,
        });
    }
};

pub const MQTTSuback = struct {
    header: MQTTHeader = .{},
    pkt_id: u16 = 0,
    return_codes_len: u16 = 0,
    return_codes: []u8 = undefined,

    pub fn format(
        self: MQTTSuback,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "{}Pkt ID: {}\nReturn Codes: {d}\n", .{
            self.header,
            self.pkt_id,
            self.return_codes,
        });
    }
};

pub fn newMQTTMessageSuback(header: MQTTHeader, pkt_id: u16, rcs: []u8) MQTTSuback {
    return MQTTSuback{
        .header = header,
        .pkt_id = pkt_id,
        .return_codes = rcs,
        .return_codes_len = @intCast(rcs.len),
    };
}

pub const MQTTPublish = struct {
    header: MQTTHeader = .{},
    pkt_id: u16 = 0,
    topic_len: u16 = 0,
    topic: []const u8 = undefined,
    payload_len: u16 = 0,
    payload: []u8 = undefined,

    pub fn format(
        self: MQTTPublish,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "{}Pkt ID: {}\nTopic: {s}\nPayload: {X}\n", .{
            self.header,
            self.pkt_id,
            self.topic,
            self.payload,
        });
    }
};

fn newMQTTMessagePublish(header: MQTTHeader, pkt_id: u16, topic: []const u8, payload: []const u8) MQTTPublish {
    return MQTTPublish{
        .header = header,
        .pkt_id = pkt_id,
        .topic = topic,
        .topic_len = @intCast(topic.len),
        .payload = payload,
        .payload_len = @intCast(payload.len),
    };
}

pub const MQTTAck = struct {
    header: MQTTHeader = .{},
    pkt_id: u16 = 0,

    pub fn format(
        self: MQTTAck,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        _ = options;
        try std.fmt.format(out_stream, "{}Pkt ID: {}\n", .{
            self.header,
            self.pkt_id,
        });
    }
};

pub fn newMQTTMessageAck(header: MQTTHeader, pkt_id: u16) MQTTAck {
    return MQTTAck{
        .header = header,
        .pkt_id = pkt_id,
    };
}

pub const MQTTPuback = MQTTAck;
pub const MQTTPubrec = MQTTAck;
pub const MQTTPubrel = MQTTAck;
pub const MQTTPubcomp = MQTTAck;
pub const MQTTUnsuback = MQTTAck;
pub const MQTTPingreq = MQTTAck;
pub const MQTTPingresp = MQTTAck;
pub const MQTTDisconnect = MQTTAck;

pub const MQTTMessageEnum = enum {
    Header,
    Ack,
    Connect,
    Connack,
    Suback,
    Publish,
    Subscribe,
    Unsubscribe,
    Disconnect,
    Ping,
    PubAck,
    PubRec,
    PubRel,
    PubComp,
};

pub const MQTTMessage = union(MQTTMessageEnum) {
    Header: MQTTHeader,
    Ack: MQTTAck,
    Connect: MQTTConnect,
    Connack: MQTTConnack,
    Suback: MQTTSuback,
    Publish: MQTTPublish,
    Subscribe: MQTTSubscribe,
    Unsubscribe: MQTTUnsubscribe,
    Disconnect: MQTTDisconnect,
    Ping: MQTTPingreq,
    PubAck: MQTTPuback,
    PubRec: MQTTPubrec,
    PubRel: MQTTPubrel,
    PubComp: MQTTPubcomp,

    pub fn format(
        self: MQTTMessage,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        switch (self) {
            .Header => |h| try h.format(fmt, options, out_stream),
            .Ack, .Disconnect, .Ping, .PubAck, .PubRec, .PubRel, .PubComp => |a| try a.format(fmt, options, out_stream),
            .Connect => |c| try c.format(fmt, options, out_stream),
            .Connack => |c| try c.format(fmt, options, out_stream),
            .Suback => |s| try s.format(fmt, options, out_stream),
            .Publish => |p| try p.format(fmt, options, out_stream),
            .Subscribe => |s| try s.format(fmt, options, out_stream),
            .Unsubscribe => |u| try u.format(fmt, options, out_stream),
        }
    }
};