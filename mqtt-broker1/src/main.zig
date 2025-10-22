const std = @import("std");
const config = @import("config.zig");
const packet = @import("packet.zig");
const mqtt = @import("mqtt.zig");
const connect = @import("handle_connect.zig");
const ConnectError = @import("handle_connect.zig").ConnectError;
const SubscriptionTree = @import("subscription.zig").SubscriptionTree;
const subscribe = @import("handle_subscribe.zig");
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const time = std.time;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

const Client = @import("client.zig").Client;
const ClientError = @import("client.zig").ClientError;

// MQTT broker
const MqttBroker = struct {
    allocator: Allocator,
    clients: AutoHashMap(u64, *Client),
    next_client_id: u64,
    subscriptions: SubscriptionTree,

    pub fn init(allocator: Allocator) MqttBroker {
        return MqttBroker{
            .allocator = allocator,
            .clients = AutoHashMap(u64, *Client).init(allocator),
            .next_client_id = 1,
            .subscriptions = SubscriptionTree.init(allocator),
        };
    }

    pub fn deinit(self: *MqttBroker) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr.*;
            client.deinit();
        }
        self.clients.deinit();
        self.subscriptions.deinit();
    }

    // start the server on the given port
    pub fn start(self: *MqttBroker, port: u16) !void {
        std.log.info("Starting mqtt server", .{});
        const self_addr = try net.Address.resolveIp("0.0.0.0", port);
        var listener = try self_addr.listen(.{ .reuse_address = true });
        std.log.info("Listening on {any}", .{self_addr});

        while (listener.accept()) |conn| {
            std.log.info("Accepted client connection from: {any}", .{conn.address});

            // 优化: 设置 TCP_NODELAY 禁用 Nagle 算法,减少延迟
            if (@import("builtin").os.tag == .windows) {
                const windows = std.os.windows;
                const ws2_32 = windows.ws2_32;
                const enable: c_int = 1;
                _ = ws2_32.setsockopt(conn.stream.handle, ws2_32.IPPROTO.TCP, ws2_32.TCP.NODELAY, @ptrCast(&enable), @sizeOf(c_int));
            } else {
                const enable: c_int = 1;
                _ = std.posix.setsockopt(conn.stream.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&enable)) catch {};
            }

            const client_id = self.getNextClientId();
            const client = try Client.init(self.allocator, client_id, mqtt.ProtocolVersion.Invalid, conn.stream, conn.address);
            try self.clients.put(client_id, client);

            // er... use a threadpool for clients? or is this OK
            const thread = try std.Thread.spawn(.{}, handleClient, .{ self, client });
            thread.detach(); // 分离线程,允许并发处理多个客户端
        } else |err| {
            std.log.info("Error accepting client connection: {any}", .{err});
        }
    }

    fn getNextClientId(self: *MqttBroker) u64 {
        const id = self.next_client_id;
        self.next_client_id += 1;
        return id;
    }

    /// add a new client to the broker with a threaded event loop
    fn handleClient(self: *MqttBroker, client: *Client) !void {
        const writer = try packet.Writer.init(self.allocator);

        const read_buffer = try self.allocator.alloc(u8, config.READ_BUFFER_SIZE);
        var reader = packet.Reader.init(read_buffer);

        defer {
            _ = self.clients.remove(client.id);
            client.deinit();
            writer.deinit();
            self.allocator.free(read_buffer);
        }

        std.debug.print("Client {any} is connecting\n", .{client.address});

        // client event loop
        while (true) {
            // 使用更底层的 recv 来读取 socket 数据,在 Windows 上更可靠
            const length = blk: {
                if (@import("builtin").os.tag == .windows) {
                    // Windows 平台使用 recv
                    const windows = std.os.windows;
                    const ws2_32 = windows.ws2_32;
                    const result = ws2_32.recv(client.stream.handle, read_buffer.ptr, @intCast(read_buffer.len), 0);
                    if (result == ws2_32.SOCKET_ERROR) {
                        const err = ws2_32.WSAGetLastError();
                        if (err == .WSAECONNRESET or err == .WSAECONNABORTED) {
                            std.log.info("Client {any} connection closed by peer: {any}", .{ client.id, err });
                            return;
                        }
                        std.log.err("Client {any} socket error: {any}", .{ client.id, err });
                        return ClientError.ClientReadError;
                    }
                    break :blk @as(usize, @intCast(result));
                } else {
                    // 其他平台使用标准 read
                    break :blk client.stream.read(read_buffer) catch |err| {
                        std.log.err("Error reading from client {any}: {any}", .{ client.id, err });
                        return ClientError.ClientReadError;
                    };
                }
            };

            if (length == 0) {
                std.log.info("Client {any} sent 0 length packet, disconnected", .{client.id});
                return;
            }

            reader.start(length) catch |err| {
                std.log.err("Error starting reader: {any}", .{err});
                return;
            };

            // read the buffer looking for packets
            try self.read(client, &reader, writer, length);
        }
    }

    /// Read the buffer looking for packets
    fn read(self: *MqttBroker, client: *Client, reader: *packet.Reader, writer: *packet.Writer, length: usize) !void {
        std.debug.print("Reading bytes from client {} {any}\n", .{ client.id, reader.buffer[0..length] });

        // multiple packets can be in the buffer, loop until its fully read
        while (reader.pos < reader.length) {
            std.debug.print("Looking for packets in buffer, pos: {} of length: {}\n", .{ reader.pos, reader.length });

            // expect a control packet command
            const cmd = reader.readCommand() catch |err| {
                std.debug.print("Unknown command in packet {}\n", .{err});
                break;
            };

            if (cmd == .DISCONNECT) {
                std.log.info("Client {any} disconnected", .{client.id});
                // TODO - client cleanup like publish will, etc.
                return;
            } else {
                const remaining_length = try reader.readRemainingLength();
                std.debug.print("{any} bytes in packet payload\n", .{remaining_length});
            }

            switch (cmd) {
                .CONNECT => {
                    var reason_code = mqtt.ReasonCode.MalformedPacket;

                    const connect_packet = connect.read(reader, self.allocator) catch |err| {
                        std.log.err("Fatal error reading CONNECT packet: {s}", .{@errorName(err)});
                        return;
                    };

                    const errors = connect_packet.getErrors();
                    if (errors.len > 0) {
                        std.debug.print("{d} Errors reading packet:\n", .{errors.len});
                        for (errors) |err| {
                            std.debug.print("Error: {}\n", .{err});
                        }
                        switch (errors[0].err) {
                            ConnectError.UsernameMustBePresent, ConnectError.PasswordMustBePresent, ConnectError.PasswordMustNotBeSet => {
                                reason_code = mqtt.ReasonCode.BadUserNameOrPassword;
                            },
                            ConnectError.ClientIdNotUTF8, ConnectError.ClientIdTooLong, ConnectError.ClientIdTooShort, ConnectError.InvalidClientId => {
                                reason_code = mqtt.ReasonCode.ClientIdentifierNotValid;
                            },
                            else => {
                                reason_code = mqtt.ReasonCode.MalformedPacket;
                            },
                        }

                        // ack the connection and disconnect
                        std.debug.print("Client {} connected unsuccessfully\n", .{client.id});
                        try connect.connack(writer, &client.stream, reason_code);
                        std.debug.print("Server sent CONNACK to Client {}\n", .{client.id});
                        // try connect.disconnect(writer, &client.stream, reason_code);
                        // std.debug.print("Server sent DISCONNECT to Client {}\n", .{client.id});
                        return;
                    } else {
                        // Set reason_code to Success if everything is okay
                        reason_code = mqtt.ReasonCode.Success;

                        // 设置客户端信息
                        client.identifer = connect_packet.client_identifier;
                        client.keep_alive = connect_packet.keep_alive;
                        client.clean_start = connect_packet.connect_flags.clean_session;
                        client.is_connected = true;
                        client.connect_time = time.milliTimestamp();

                        // ack the connection
                        std.debug.print("Client {} connected successfully\n", .{client.id});
                        try connect.connack(writer, &client.stream, reason_code);
                        std.debug.print("Server sent CONNACK to Client {}\n", .{client.id});

                        client.debugPrint();
                    }
                },
                .SUBSCRIBE => {
                    const subscribe_packet = try subscribe.read(reader, client, self.allocator);

                    std.debug.print("Subscribe packet: {any}\n", .{subscribe_packet});
                    for (subscribe_packet.topics.items) |topic| {
                        try self.subscriptions.subscribe(topic.filter, client);
                        std.debug.print("Client {} subscribed to topic {s}\n", .{ client.id, topic.filter });
                    }

                    std.debug.print("self.subscriptions: {any}\n", .{self.subscriptions});

                    // the Server MUST respond with a SUBACK Packet [MQTT-3.8.4-1]
                    try subscribe.suback(writer, &client.stream, subscribe_packet.packet_id, client);

                    std.debug.print("Server sent SUBACK to Client {}\n", .{client.id});
                },
                .PUBLISH => {
                    std.debug.print("Client {} sent PUBLISH\n", .{client.id});
                },
                .UNSUBSCRIBE => {
                    std.debug.print("Client {} sent UNSUBSCRIBE\n", .{client.id});
                },
                .PUBREC => {
                    std.debug.print("Client {} sent PUBREC\n", .{client.id});
                },
                .PINGREQ => {
                    std.debug.print("Client {} sent PINGREQ\n", .{client.id});
                    // MQTT 3.1.1: 服务器必须响应 PINGRESP
                    writer.reset(); // 清空缓冲区,避免累积旧数据
                    try writer.writeByte(0xD0); // PINGRESP 包类型 (13 << 4 = 208 = 0xD0)
                    try writer.writeByte(0x00); // Remaining Length = 0
                    try writer.writeToStream(&client.stream);
                    std.debug.print("Server sent PINGRESP to Client {}\n", .{client.id});
                },
                .DISCONNECT => {
                    std.debug.print("Client {} sent DISCONNECT\n", .{client.id});
                },
                else => {
                    std.log.err("Unknown command {any} received from client {any}", .{ @intFromEnum(cmd), client.id });
                    break;
                },
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var broker = MqttBroker.init(allocator);
    defer broker.deinit();

    // TODO have a config file that updates values in config.zig

    try broker.start(config.PORT);
}
