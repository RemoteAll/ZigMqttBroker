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
        std.log.info("==================================================", .{});
        std.log.info("🚀 MQTT Broker Starting", .{});
        std.log.info("==================================================", .{});
        const self_addr = try net.Address.resolveIp("0.0.0.0", port);
        var listener = try self_addr.listen(.{ .reuse_address = true });
        std.log.info("📡 Listening on port {}", .{port});
        std.log.info("==================================================\n", .{});

        while (listener.accept()) |conn| {
            const client_id = self.getNextClientId();

            std.log.info("\n╔════════════════════════════════════════════════╗", .{});
            std.log.info("║ 🔌 NEW CLIENT CONNECTION", .{});
            std.log.info("╠════════════════════════════════════════════════╣", .{});
            std.log.info("║ Client ID: {}", .{client_id});
            std.log.info("║ Address:   {any}", .{conn.address});
            std.log.info("╚════════════════════════════════════════════════╝\n", .{});

            const client = try Client.init(self.allocator, client_id, mqtt.ProtocolVersion.Invalid, conn.stream, conn.address);
            try self.clients.put(client_id, client);

            // 创建独立线程处理每个客户端连接
            const thread = try std.Thread.spawn(.{}, handleClient, .{ self, client });
            thread.detach(); // 分离线程,允许并发处理多个客户端
        } else |err| {
            std.log.err("❌ Error accepting client connection: {any}", .{err});
        }
    }

    fn getNextClientId(self: *MqttBroker) u64 {
        const id = self.next_client_id;
        self.next_client_id += 1;
        return id;
    }

    /// 记录并发送数据到客户端
    fn logAndSend(self: *MqttBroker, writer: *packet.Writer, client: *Client, packet_type: []const u8) !void {
        _ = self; // 当前未使用,但保留以便未来扩展
        const data = writer.buffer[0..writer.pos];

        std.log.info("\n┌────────────────────────────────────────────────┐", .{});
        std.log.info("│ 📤 SENDING to Client {}", .{client.id});
        std.log.info("├────────────────────────────────────────────────┤", .{});
        std.log.info("│ Packet Type: {s}", .{packet_type});
        std.log.info("│ Length: {} bytes", .{data.len});
        std.log.info("├────────────────────────────────────────────────┤", .{});
        std.log.info("│ HEX:", .{});

        // 十六进制格式 (每行16字节)
        var i: usize = 0;
        while (i < data.len) : (i += 16) {
            const end = @min(i + 16, data.len);
            std.debug.print("│ {X:0>4}:  ", .{i});

            // 打印十六进制
            for (data[i..end], 0..) |byte, j| {
                std.debug.print("{X:0>2} ", .{byte});
                if (j == 7) std.debug.print(" ", .{}); // 中间加空格
            }

            // 填充空白
            const remaining = 16 - (end - i);
            var pad: usize = 0;
            while (pad < remaining) : (pad += 1) {
                std.debug.print("   ", .{});
                if (pad == 7) std.debug.print(" ", .{});
            }

            // 打印ASCII
            std.debug.print(" │ ", .{});
            for (data[i..end]) |byte| {
                if (byte >= 32 and byte <= 126) {
                    std.debug.print("{c}", .{byte});
                } else {
                    std.debug.print(".", .{});
                }
            }
            std.debug.print("\n", .{});
        }
        std.log.info("└────────────────────────────────────────────────┘\n", .{});

        // 使用线程安全的写入方法
        try client.safeWriteToStream(data);
    }

    /// add a new client to the broker with a threaded event loop
    fn handleClient(self: *MqttBroker, client: *Client) !void {
        const writer = try packet.Writer.init(self.allocator);

        const read_buffer = try self.allocator.alloc(u8, config.READ_BUFFER_SIZE);
        var reader = packet.Reader.init(read_buffer);

        defer {
            std.log.info("\n╔════════════════════════════════════════════════╗", .{});
            std.log.info("║ 🔌 CLIENT DISCONNECTED", .{});
            std.log.info("╠════════════════════════════════════════════════╣", .{});
            std.log.info("║ Client ID: {}", .{client.id});
            std.log.info("╚════════════════════════════════════════════════╝\n", .{});

            // 标记客户端为已断开,避免其他线程尝试写入
            client.is_connected = false;

            _ = self.clients.remove(client.id);
            client.deinit();
            writer.deinit();
            self.allocator.free(read_buffer);
        }

        // client event loop
        while (true) {

            // 使用更底层的 recv 来读取 socket 数据
            const length = blk: {
                if (@import("builtin").os.tag == .windows) {
                    // Windows 平台使用 recv
                    const windows = std.os.windows;
                    const ws2_32 = windows.ws2_32;
                    const result = ws2_32.recv(client.stream.handle, read_buffer.ptr, @intCast(read_buffer.len), 0);
                    if (result == ws2_32.SOCKET_ERROR) {
                        const err = ws2_32.WSAGetLastError();
                        if (err == .WSAECONNRESET or err == .WSAECONNABORTED) {
                            std.log.info("⚠️  Client {} connection closed by peer", .{client.id});
                            return;
                        }
                        std.log.err("❌ Client {} socket error: {any}", .{ client.id, err });
                        return ClientError.ClientReadError;
                    }
                    break :blk @as(usize, @intCast(result));
                } else {
                    // Unix/Linux 平台使用标准 read
                    break :blk client.stream.read(read_buffer) catch |err| {
                        switch (err) {
                            error.ConnectionResetByPeer, error.BrokenPipe => {
                                std.log.info("⚠️  Client {} connection closed: {any}", .{ client.id, err });
                                return;
                            },
                            else => {
                                std.log.err("❌ Error reading from client {}: {any}", .{ client.id, err });
                                return ClientError.ClientReadError;
                            },
                        }
                    };
                }
            };

            if (length == 0) {
                std.log.info("⚠️  Client {} sent 0 length packet, disconnected", .{client.id});
                return;
            }

            // 打印接收到的完整原始数据
            std.log.info("\n┌────────────────────────────────────────────────┐", .{});
            std.log.info("│ 📥 RECEIVED from Client {}", .{client.id});
            std.log.info("├────────────────────────────────────────────────┤", .{});
            std.log.info("│ Length: {} bytes", .{length});
            std.log.info("├────────────────────────────────────────────────┤", .{});

            // 十六进制格式 (每行16字节)
            std.log.info("│ HEX:", .{});
            var i: usize = 0;
            while (i < length) : (i += 16) {
                const end = @min(i + 16, length);
                std.debug.print("│ {X:0>4}:  ", .{i});

                // 打印十六进制
                for (read_buffer[i..end], 0..) |byte, j| {
                    std.debug.print("{X:0>2} ", .{byte});
                    if (j == 7) std.debug.print(" ", .{}); // 中间加空格
                }

                // 填充空白
                const remaining = 16 - (end - i);
                var pad: usize = 0;
                while (pad < remaining) : (pad += 1) {
                    std.debug.print("   ", .{});
                    if (pad == 7) std.debug.print(" ", .{});
                }

                // 打印ASCII
                std.debug.print(" │ ", .{});
                for (read_buffer[i..end]) |byte| {
                    if (byte >= 32 and byte <= 126) {
                        std.debug.print("{c}", .{byte});
                    } else {
                        std.debug.print(".", .{});
                    }
                }
                std.debug.print("\n", .{});
            }
            std.log.info("└────────────────────────────────────────────────┘\n", .{});

            reader.start(length) catch |err| {
                std.log.err("❌ Error starting reader: {any}", .{err});
                return;
            };

            // read the buffer looking for packets
            try self.read(client, &reader, writer, length);
        }
    }

    /// Read the buffer looking for packets
    fn read(self: *MqttBroker, client: *Client, reader: *packet.Reader, writer: *packet.Writer, length: usize) !void {
        _ = length; // 不再需要打印这个

        // multiple packets can be in the buffer, loop until its fully read
        while (reader.pos < reader.length) {

            // expect a control packet command
            const cmd = reader.readCommand() catch |err| {
                std.log.err("❌ Unknown command in packet: {}", .{err});
                break;
            };

            if (cmd == .DISCONNECT) {
                std.log.info("👋 Client {} sent DISCONNECT", .{client.id});
                // TODO - client cleanup like publish will, etc.
                return;
            } else {
                _ = try reader.readRemainingLength();
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
                        std.log.err("❌ Client {} connected unsuccessfully (reason: {s})", .{ client.id, @tagName(reason_code) });
                        try connect.connack(writer, client, reason_code);
                        std.log.info("📤 Server sent CONNACK (failed) to Client {}", .{client.id});
                        return;
                    } else {
                        // Set reason_code to Success if everything is okay
                        reason_code = mqtt.ReasonCode.Success;

                        // ack the connection
                        std.log.info("✅ Client {} CONNECT successful", .{client.id});
                        client.is_connected = true; // 标记客户端已连接
                        try connect.connack(writer, client, reason_code);
                        std.log.info("📤 Server sent CONNACK (success) to Client {}", .{client.id});
                    }
                },
                .SUBSCRIBE => {
                    const subscribe_packet = try subscribe.read(reader, client, self.allocator);
                    defer {
                        subscribe_packet.deinit(self.allocator);
                        self.allocator.destroy(subscribe_packet);
                    }

                    std.log.info("📬 Client {} SUBSCRIBE (packet_id: {})", .{ client.id, subscribe_packet.packet_id });
                    for (subscribe_packet.topics.items) |topic| {
                        try self.subscriptions.subscribe(topic.filter, client);
                        std.log.info("   ➕ Subscribed to: {s}", .{topic.filter});
                    }

                    // the Server MUST respond with a SUBACK Packet [MQTT-3.8.4-1]
                    try subscribe.suback(writer, client, subscribe_packet.packet_id);
                    std.log.info("📤 Server sent SUBACK to Client {}", .{client.id});
                },
                .PUBLISH => {
                    // 读取 topic
                    const topic = try reader.readUTF8String(false) orelse {
                        std.log.err("❌ PUBLISH packet missing topic", .{});
                        break;
                    };

                    // 计算 payload 的长度
                    const payload_start = reader.pos;
                    const payload_length = reader.length - payload_start;
                    const payload = reader.buffer[payload_start..reader.length];

                    std.log.info("📨 Client {} PUBLISH", .{client.id});
                    std.log.info("   📍 Topic: {s}", .{topic});
                    std.log.info("   📦 Payload: {} bytes", .{payload_length});
                    if (payload_length > 0 and payload_length <= 100) {
                        std.log.info("   💬 Content: {s}", .{payload});
                    }

                    // 查找匹配的订阅者
                    var matched_clients = try self.subscriptions.match(topic, &self.allocator);
                    defer matched_clients.deinit(self.allocator);

                    std.log.info("   🔍 Found {} matching subscriber(s)", .{matched_clients.items.len});

                    // 转发消息给每个订阅者(包括发送者自己)
                    for (matched_clients.items) |subscriber| {
                        // 检查订阅者连接状态
                        if (!subscriber.is_connected) {
                            std.log.warn("   ⚠️  Skipping disconnected client {}", .{subscriber.id});
                            continue;
                        }

                        // 为每个订阅者创建新的 writer
                        var subscriber_writer = try packet.Writer.init(self.allocator);
                        defer subscriber_writer.deinit();

                        // 构建 PUBLISH 包发送给订阅者
                        try subscriber_writer.startPacket(mqtt.Command.PUBLISH);

                        // 写入 topic
                        try subscriber_writer.writeUTF8String(topic);

                        // 写入 payload
                        for (payload) |byte| {
                            try subscriber_writer.writeByte(byte);
                        }

                        try subscriber_writer.finishPacket();

                        // 使用线程安全的写入方法发送数据
                        const data = subscriber_writer.buffer[0..subscriber_writer.pos];
                        subscriber.safeWriteToStream(data) catch |err| {
                            std.log.err("   ❌ Failed to send PUBLISH to client {}: {any}", .{ subscriber.id, err });
                            continue;
                        };

                        std.log.info("   ✅ Forwarded to client {}", .{subscriber.id});
                    }

                    // 移动 reader 位置到末尾
                    reader.pos = reader.length;
                },
                .UNSUBSCRIBE => {
                    std.log.info("📭 Client {} sent UNSUBSCRIBE", .{client.id});

                    // 读取 packet ID
                    const packet_id = try reader.readTwoBytes();
                    std.log.info("   Packet ID: {}", .{packet_id});

                    // 读取要取消订阅的主题
                    const topic = try reader.readUTF8String(false) orelse {
                        std.log.err("UNSUBSCRIBE packet missing topic", .{});
                        break;
                    };

                    std.log.info("   Topic: {s}", .{topic});

                    // TODO: 实现从订阅树中移除客户端订阅
                    // try self.subscriptions.unsubscribe(topic, client);

                    // 发送 UNSUBACK
                    try writer.startPacket(mqtt.Command.UNSUBACK);
                    try writer.writeTwoBytes(packet_id);
                    try writer.finishPacket();
                    try self.logAndSend(writer, client, "UNSUBACK");

                    // 移动 reader 位置到末尾
                    reader.pos = reader.length;
                },
                .PUBREC => {
                    std.log.info("📥 Client {} sent PUBREC", .{client.id});
                },
                .PINGREQ => {
                    std.log.info("💓 Client {} sent PINGREQ (heartbeat)", .{client.id});

                    // 发送 PINGRESP
                    try writer.startPacket(mqtt.Command.PINGRESP);
                    try writer.finishPacket();
                    try self.logAndSend(writer, client, "PINGRESP");
                },
                .DISCONNECT => {
                    std.log.info("👋 Client {} sent DISCONNECT", .{client.id});
                },
                else => {
                    std.log.err("❌ Unknown command {} received from client {}", .{ @intFromEnum(cmd), client.id });
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
