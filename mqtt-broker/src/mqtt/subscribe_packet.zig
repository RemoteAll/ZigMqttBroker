const std = @import("std");
const Allocator = std.mem.Allocator;
const mqtt = @import("../mqtt.zig");

pub const SubscribePacket = struct {
    packet_id: u16,
    subscription_identifier: ?u32,
    user_properties: std.ArrayList(UserProperty),
    topics: std.ArrayList(SubscribeTopic),

    pub fn init(allocator: Allocator, packet_id: u16) SubscribePacket {
        _ = allocator;
        return .{
            .packet_id = packet_id,
            .subscription_identifier = null,
            .user_properties = .{},
            .topics = .{},
        };
    }

    pub fn deinit(self: *SubscribePacket, allocator: Allocator) void {
        self.user_properties.deinit(allocator);
        self.topics.deinit(allocator);
    }

    pub const UserProperty = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const SubscriptionOptions = packed struct {
        reserved: u2 = 0,
        retain_handling: u2,
        retain_as_published: bool,
        no_local: bool,
        qos: mqtt.QoS,
    };

    pub const SubscribeTopic = struct {
        filter: []const u8,
        options: SubscriptionOptions,
    };
};
