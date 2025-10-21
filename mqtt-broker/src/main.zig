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

            const client_id = self.getNextClientId();
            const client = try Client.init(self.allocator, client_id, mqtt.ProtocolVersion.Invalid, conn.stream, conn.address);
            try self.clients.put(client_id, client);

            // 创建独立线程处理每个客户端连接
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

        std.debug.print("=== Client {} connected from {any} ===\n", .{ client.id, client.address });
        std.debug.print("Read buffer size: {}\n", .{read_buffer.len});

        // client event loop
        while (true) {
            std.debug.print("\n[Client {}] Waiting to read data...\n", .{client.id});

            // 使用更底层的 recv 来读取 socket 数据
            const length = blk: {
                if (@import("builtin").os.tag == .windows) {
                    // Windows 平台使用 recv
                    const windows = std.os.windows;
                    const ws2_32 = windows.ws2_32;
                    const result = ws2_32.recv(client.stream.handle, read_buffer.ptr, @intCast(read_buffer.len), 0);
                    if (result == ws2_32.SOCKET_ERROR) {
                        const err = ws2_32.WSAGetLastError();
                        std.debug.print("[Client {}] Windows socket error code: {}\n", .{ client.id, err });
                        if (err == .WSAECONNRESET or err == .WSAECONNABORTED) {
                            std.log.info("Client {} connection closed by peer", .{client.id});
                            return;
                        }
                        std.log.err("Client {} socket error: {any}", .{ client.id, err });
                        return ClientError.ClientReadError;
                    }
                    break :blk @as(usize, @intCast(result));
                } else {
                    // Unix/Linux 平台使用标准 read
                    break :blk client.stream.read(read_buffer) catch |err| {
                        std.debug.print("[Client {}] Read error: {any}\n", .{ client.id, err });
                        switch (err) {
                            error.ConnectionResetByPeer, error.BrokenPipe => {
                                std.log.info("Client {} connection closed: {any}", .{ client.id, err });
                                return;
                            },
                            else => {
                                std.log.err("Error reading from client {}: {any}", .{ client.id, err });
                                return ClientError.ClientReadError;
                            },
                        }
                    };
                }
            };

            std.debug.print("[Client {}] Read {} bytes\n", .{ client.id, length });

            if (length == 0) {
                std.log.info("Client {} sent 0 length packet, disconnected", .{client.id});
                return;
            }

            // 打印接收到的原始数据（十六进制和ASCII）
            std.debug.print("[Client {}] Raw data (hex): ", .{client.id});
            for (read_buffer[0..length]) |byte| {
                std.debug.print("{X:0>2} ", .{byte});
            }
            std.debug.print("\n", .{});

            std.debug.print("[Client {}] Raw data (ASCII): ", .{client.id});
            for (read_buffer[0..length]) |byte| {
                if (byte >= 32 and byte <= 126) {
                    std.debug.print("{c}", .{byte});
                } else {
                    std.debug.print(".", .{});
                }
            }
            std.debug.print("\n", .{});

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
                std.log.info("Client {} disconnected", .{client.id});
                // TODO - client cleanup like publish will, etc.
                return;
            } else {
                const remaining_length = try reader.readRemainingLength();
                std.debug.print("{} bytes in packet payload\n", .{remaining_length});
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

                        // ack the connection
                        std.debug.print("Client {} connected successfully\n", .{client.id});
                        try connect.connack(writer, &client.stream, reason_code);
                        std.debug.print("Server sent CONNACK to Client {}\n", .{client.id});

                        client.debugPrint();
                    }
                },
                .SUBSCRIBE => {
                    const subscribe_packet = try subscribe.read(reader, client, self.allocator);
                    defer {
                        subscribe_packet.deinit(self.allocator);
                        self.allocator.destroy(subscribe_packet);
                    }

                    // std.debug.print("Subscribe packet: {any}\n", .{subscribe_packet});
                    std.debug.print("Processing SUBSCRIBE with packet_id: {}\n", .{subscribe_packet.packet_id});
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

                    // 调试:打印原始 PUBLISH 包
                    std.debug.print("Original PUBLISH packet: ", .{});
                    for (reader.buffer[0..reader.length]) |b| {
                        std.debug.print("{X:0>2} ", .{b});
                    }
                    std.debug.print("\n", .{});

                    // 读取 topic
                    const topic = try reader.readUTF8String(false) orelse {
                        std.log.err("PUBLISH packet missing topic", .{});
                        break;
                    };

                    std.debug.print("PUBLISH topic: {s}\n", .{topic});

                    // 计算 payload 的长度
                    const payload_start = reader.pos;
                    const payload_length = reader.length - payload_start;
                    const payload = reader.buffer[payload_start..reader.length];

                    std.debug.print("PUBLISH payload ({} bytes): {s}\n", .{ payload_length, payload });

                    // 查找匹配的订阅者
                    var matched_clients = try self.subscriptions.match(topic, &self.allocator);
                    defer matched_clients.deinit(self.allocator);

                    std.debug.print("Found {} matching subscribers\n", .{matched_clients.items.len});

                    // 转发消息给每个订阅者(包括发送者自己)
                    for (matched_clients.items) |subscriber| {
                        std.debug.print("Forwarding message to client {}\n", .{subscriber.id});

                        // 为每个订阅者创建新的 writer
                        var subscriber_writer = try packet.Writer.init(self.allocator);
                        defer self.allocator.destroy(subscriber_writer);

                        // 构建 PUBLISH 包发送给订阅者
                        try subscriber_writer.startPacket(mqtt.Command.PUBLISH);

                        // 写入 topic
                        try subscriber_writer.writeUTF8String(topic);

                        // 写入 payload (逐字节写入)
                        std.debug.print("Writing {} bytes of payload\n", .{payload.len});
                        for (payload) |byte| {
                            try subscriber_writer.writeByte(byte);
                        }

                        // 调试:打印 finishPacket 之前的内容
                        std.debug.print("Before finishPacket ({} bytes): ", .{subscriber_writer.pos});
                        for (subscriber_writer.buffer[0..@min(subscriber_writer.pos, 50)]) |b| {
                            std.debug.print("{X:0>2} ", .{b});
                        }
                        std.debug.print("\n", .{});

                        try subscriber_writer.finishPacket();

                        // 调试:打印发送的包内容
                        std.debug.print("After finishPacket ({} bytes): ", .{subscriber_writer.pos});
                        for (subscriber_writer.buffer[0..subscriber_writer.pos]) |b| {
                            std.debug.print("{X:0>2} ", .{b});
                        }
                        std.debug.print("\n", .{});

                        try subscriber_writer.writeToStream(&subscriber.stream);

                        std.debug.print("Message forwarded to client {}\n", .{subscriber.id});
                    }

                    // 移动 reader 位置到末尾
                    reader.pos = reader.length;
                },
                .UNSUBSCRIBE => {
                    std.debug.print("Client {} sent UNSUBSCRIBE\n", .{client.id});

                    // 读取 packet ID
                    const packet_id = try reader.readTwoBytes();
                    std.debug.print("UNSUBSCRIBE packet_id: {}\n", .{packet_id});

                    // 读取要取消订阅的主题
                    const topic = try reader.readUTF8String(false) orelse {
                        std.log.err("UNSUBSCRIBE packet missing topic", .{});
                        break;
                    };

                    std.debug.print("Unsubscribing from topic: {s}\n", .{topic});

                    // TODO: 实现从订阅树中移除客户端订阅
                    // try self.subscriptions.unsubscribe(topic, client);

                    // 发送 UNSUBACK
                    try writer.startPacket(mqtt.Command.UNSUBACK);
                    try writer.writeTwoBytes(packet_id);
                    try writer.finishPacket();
                    try writer.writeToStream(&client.stream);

                    std.debug.print("Server sent UNSUBACK to Client {}\n", .{client.id});

                    // 移动 reader 位置到末尾
                    reader.pos = reader.length;
                },
                .PUBREC => {
                    std.debug.print("Client {} sent PUBREC\n", .{client.id});
                },
                .PINGREQ => {
                    std.debug.print(">>> Client {} sent PINGREQ (heartbeat) <<<\n", .{client.id});

                    // 发送 PINGRESP
                    try writer.startPacket(mqtt.Command.PINGRESP);
                    try writer.finishPacket();
                    try writer.writeToStream(&client.stream);

                    std.debug.print("<<< Server sent PINGRESP to Client {} (heartbeat response) <<<\n", .{client.id});
                },
                .DISCONNECT => {
                    std.debug.print("Client {} sent DISCONNECT\n", .{client.id});
                },
                else => {
                    std.log.err("Unknown command {} received from client {}", .{ @intFromEnum(cmd), client.id });
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
