const std = @import("std");
const Messages = @import("messages.zig");
const config = @import("config.zig");

const sqlite = @import("sqlite");

db: sqlite.Db,

const Self = @This();

pub fn init() !Self {
    const db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = "mydata.db" },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .SingleThread,
    });

    return .{
        .db = db,
    };
}

pub fn insertPublishMessage(self: *Self, client_id: []const u8, message: Messages.MQTTPublish) !void {
    const query =
        \\INSERT INTO pub_messages(sender_id, pkt_id, topic, payload) VALUES(?, ?, ?, ?)
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();


    try stmt.exec(.{}, .{
        .sender_id = client_id,
        .pkt_id = message.pkt_id,
        .topic = message.topic,
        .payload = sqlite.Blob{
            .data = message.payload,
        },
    });
}

pub fn getMessage(self: *Self, client_id: []const u8, pkt_id: u16) !void {
    const query =
        \\SELECT * FROM pub_messages WHERE sender_id = ? AND pkt_id = ?
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();


    const row = try stmt.oneAlloc(struct {
        id: usize,
        sender_id: []const u8,
        pkt_id: u16,
        topic: []const u8,
        payload: sqlite.Blob,
    }, std.heap.page_allocator, .{}, .{
        .sender_id = client_id,
        .pkt_id = pkt_id,
    });

    if (row) |r| {
        std.log.info("ROW: {any}", .{r});
    }
}

pub const PublishDBMessage = struct {
    id: usize,
    sender_id: []const u8,
    pkt_id: u16,
    topic: []const u8,
    payload: sqlite.Blob,
};

fn messageToBytes(message: *const Messages.MQTTMessage) []const u8 {
    const T = @typeInfo(@TypeOf(message)).pointer.child;

    std.log.info("TYPE: {}", .{T});
    const struct_size = @sizeOf(T);

    const byte_ptr: [*]const u8 = @ptrCast(message);

    std.log.info("LEN: {}", .{struct_size});

    std.log.info("MESSAGE BEFORE: {} \nAFTER: {}", .{message.*, @as(@TypeOf(message), @alignCast(@ptrCast(byte_ptr[0..struct_size]))).*});

    return byte_ptr[0..struct_size];
}