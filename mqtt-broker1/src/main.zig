const std = @import("std");
const config = @import("config.zig");
const packet = @import("packet.zig");
const mqtt = @import("mqtt.zig");
const connect = @import("handle_connect.zig");
const ConnectError = @import("handle_connect.zig").ConnectError;
const SubscriptionTree = @import("subscription.zig").SubscriptionTree;
const subscribe = @import("handle_subscribe.zig");
const logger = @import("logger.zig");
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const time = std.time;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

const Client = @import("client.zig").Client;
const ClientError = @import("client.zig").ClientError;

/// 获取客户端显示名称的辅助函数
/// 使用线程局部存储避免每次都分配缓冲区
fn getClientDisplayName(client: *Client) []const u8 {
    // 使用线程局部静态缓冲区,避免重复分配
    const S = struct {
        threadlocal var buffer: [128]u8 = undefined;
    };
    return client.getDisplayName(&S.buffer) catch "Client";
}

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
        logger.info("Starting MQTT broker server", .{});
        const self_addr = try net.Address.resolveIp("0.0.0.0", port);
        var listener = try self_addr.listen(.{ .reuse_address = true });
        logger.info("Listening on port {d}", .{port});

        while (listener.accept()) |conn| {
            logger.info("Accepted client connection from: {any}", .{conn.address});

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
            logger.err("Error accepting client connection: {any}", .{err});
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

        logger.debug("Client {any} is connecting", .{client.address});

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
                            logger.info("{s} connection closed by peer: {any}", .{ getClientDisplayName(client), err });
                            return;
                        }
                        logger.err("{s} socket error: {any}", .{ getClientDisplayName(client), err });
                        return ClientError.ClientReadError;
                    }
                    break :blk @as(usize, @intCast(result));
                } else {
                    // 其他平台使用标准 read
                    break :blk client.stream.read(read_buffer) catch |err| {
                        logger.err("Error reading from {s}: {any}", .{ getClientDisplayName(client), err });
                        return ClientError.ClientReadError;
                    };
                }
            };

            if (length == 0) {
                logger.info("{s} sent 0 length packet, disconnected", .{getClientDisplayName(client)});
                return;
            }

            reader.start(length) catch |err| {
                logger.err("Error starting reader: {any}", .{err});
                return;
            };

            // read the buffer looking for packets
            try self.read(client, &reader, writer, length);
        }
    }

    /// Read the buffer looking for packets
    fn read(self: *MqttBroker, client: *Client, reader: *packet.Reader, writer: *packet.Writer, length: usize) !void {
        const client_name = getClientDisplayName(client);

        // 更新客户端最后活动时间
        client.updateActivity();
        logger.debug("Reading {d} bytes from {s} (last_activity: {d})", .{ length, client_name, client.last_activity });

        // multiple packets can be in the buffer, loop until its fully read
        while (reader.pos < reader.length) {
            logger.debug("Looking for packets in buffer, pos: {d} of length: {d}", .{ reader.pos, reader.length });

            // expect a control packet command
            const cmd = reader.readCommand() catch |err| {
                logger.warn("Unknown command in packet: {any}", .{err});
                break;
            };

            if (cmd == .DISCONNECT) {
                logger.info("{s} disconnected", .{client_name});
                // TODO - client cleanup like publish will, etc.
                return;
            } else {
                const remaining_length = try reader.readRemainingLength();
                logger.debug("Packet payload: {d} bytes", .{remaining_length});
            }

            switch (cmd) {
                .CONNECT => {
                    var reason_code = mqtt.ReasonCode.MalformedPacket;

                    const connect_packet = connect.read(reader, self.allocator) catch |err| {
                        logger.err("Fatal error reading CONNECT packet: {s}", .{@errorName(err)});
                        return;
                    };

                    const errors = connect_packet.getErrors();
                    if (errors.len > 0) {
                        logger.warn("CONNECT packet has {d} error(s)", .{errors.len});
                        for (errors) |err| {
                            logger.warn("  Error: {any}", .{err});
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
                        logger.warn("{s} connection rejected: {any}", .{ client_name, reason_code });
                        try connect.connack(writer, &client.stream, reason_code);
                        logger.debug("Server sent CONNACK (rejection) to {s}", .{client_name});
                        return;
                    } else {
                        // Set reason_code to Success if everything is okay
                        reason_code = mqtt.ReasonCode.Success;

                        // 设置客户端信息
                        client.identifer = connect_packet.client_identifier;
                        client.protocol_version = mqtt.ProtocolVersion.fromU8(connect_packet.protocol_version);
                        client.keep_alive = connect_packet.keep_alive;
                        client.clean_start = connect_packet.connect_flags.clean_session;
                        client.is_connected = true;
                        client.connect_time = time.milliTimestamp();
                        client.last_activity = client.connect_time;

                        // ack the connection (重新获取 client_name,因为 identifer 已更新)
                        const client_name_updated = getClientDisplayName(client);
                        logger.info("{s} connected successfully (keep_alive={d}s, clean_session={any})", .{ client_name_updated, client.keep_alive, client.clean_start });
                        try connect.connack(writer, &client.stream, reason_code);
                        logger.debug("Server sent CONNACK to {s}", .{client_name_updated});

                        // 保留详细的客户端信息打印用于调试
                        if (@import("builtin").mode == .Debug) {
                            client.debugPrint();
                        }
                    }
                },
                .SUBSCRIBE => {
                    const subscribe_packet = try subscribe.read(reader, client, self.allocator);

                    logger.debug("Processing SUBSCRIBE packet with {d} topic(s)", .{subscribe_packet.topics.items.len});
                    for (subscribe_packet.topics.items) |topic| {
                        try self.subscriptions.subscribe(topic.filter, client);
                        logger.info("{s} subscribed to topic: {s} (QoS {d})", .{ client_name, topic.filter, @intFromEnum(topic.options.qos) });
                    }

                    // the Server MUST respond with a SUBACK Packet [MQTT-3.8.4-1]
                    try subscribe.suback(writer, &client.stream, subscribe_packet.packet_id, client);
                    logger.debug("Server sent SUBACK to {s}", .{client_name});
                },
                .PUBLISH => {
                    logger.debug("{s} sent PUBLISH", .{client_name});
                    // TODO: 实现 PUBLISH 处理
                },
                .UNSUBSCRIBE => {
                    logger.debug("{s} sent UNSUBSCRIBE", .{client_name});
                    // TODO: 实现 UNSUBSCRIBE 处理
                },
                .PUBREC => {
                    logger.debug("{s} sent PUBREC", .{client_name});
                    // TODO: 实现 QoS 2 处理
                },
                .PINGREQ => {
                    logger.debug("{s} sent PINGREQ (heartbeat, last_activity: {d})", .{ client_name, client.last_activity });
                    // MQTT 3.1.1: 服务器必须响应 PINGRESP
                    writer.reset(); // 清空缓冲区,避免累积旧数据
                    try writer.writeByte(0xD0); // PINGRESP 包类型 (13 << 4 = 208 = 0xD0)
                    try writer.writeByte(0x00); // Remaining Length = 0
                    try writer.writeToStream(&client.stream);
                    logger.debug("Server sent PINGRESP to {s} (last_activity: {d})", .{ client_name, client.last_activity });
                },
                .DISCONNECT => {
                    logger.debug("{s} sent DISCONNECT", .{client_name});
                    // TODO: 实现优雅断开处理
                },
                else => {
                    logger.err("Unknown command {any} received from {s}", .{ @intFromEnum(cmd), client_name });
                    break;
                },
            }
        }
    }
};

pub fn main() !void {
    // 配置日志系统
    const is_debug_mode = @import("builtin").mode == .Debug;
    logger.setLevel(if (is_debug_mode) .debug else .info);

    logger.info("=== MQTT Broker Starting ===", .{});
    logger.info("Build mode: {s}", .{if (is_debug_mode) "Debug" else "Release"});
    logger.info("Log level: {s}", .{if (is_debug_mode) "DEBUG" else "INFO"});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var broker = MqttBroker.init(allocator);
    defer broker.deinit();

    // TODO have a config file that updates values in config.zig

    try broker.start(config.PORT);
}
