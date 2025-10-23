const std = @import("std");
const Server = @import("server.zig").Server;
const Core = @import("mqtt.zig").Core;
const MQTT = @import("mqtt.zig");
const Store = @import("message_store.zig");
const Messages = @import("messages.zig");

pub fn main() !void {
    var store = try Store.init();

    var tst: []const u8 = "Hello, World!";
    try store.insertPublishMessage("TESTID", Messages.MQTTPublish{
        .header = @bitCast(Messages.PUBLISH_BYTE),
        .pkt_id = 1234,
        .topic = "test/topic",
        .payload = @constCast(tst[0..13]),
        .topic_len = 11,
        .payload_len = 13,
    });
    
    try store.getMessage("TESTID", 1234);

    var core = try Core.init(std.heap.page_allocator);
    var s = try Server.new(std.heap.page_allocator, "127.0.0.1", 8080, &core);
    defer s.deinit();

    try s.start(1);
}