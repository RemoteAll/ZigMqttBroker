const std = @import("std");
const config = @import("config.zig");
const packet = @import("packet.zig");
const mqtt = @import("mqtt.zig");
const connect = @import("handle_connect.zig");
const ConnectError = @import("handle_connect.zig").ConnectError;
const SubscriptionTree = @import("subscription.zig").SubscriptionTree;
const subscribe = @import("handle_subscribe.zig");
const unsubscribe = @import("handle_unsubscribe.zig");
const publish = @import("handle_publish.zig");
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

    /// 转发给单个订阅者(优化路径)
    fn forwardToSingle(self: *MqttBroker, subscriber: *Client, publish_packet: anytype, writer: anytype) !void {
        _ = self;
        if (!subscriber.is_connected) {
            logger.warn("   ⚠️  Skipping disconnected subscriber: {s}", .{subscriber.identifer});
            return;
        }

        writer.reset();
        try publish.writePublish(
            writer,
            publish_packet.topic,
            publish_packet.payload,
            .AtMostOnce,
            publish_packet.retain,
            false,
            null,
        );

        writer.writeToStream(&subscriber.stream) catch |err| {
            logger.err("   ❌ Failed to send to {s}: {any}", .{ subscriber.identifer, err });
            return err;
        };

        logger.debug("   ✅ Forwarded to {s}", .{subscriber.identifer});
    }

    /// 顺序转发给多个订阅者(2-5个,避免线程开销)
    fn forwardSequentially(self: *MqttBroker, subscribers: []*Client, publish_packet: anytype, writer: anytype) !void {
        _ = self;
        for (subscribers) |subscriber| {
            if (!subscriber.is_connected) {
                logger.warn("   ⚠️  Skipping disconnected subscriber: {s}", .{subscriber.identifer});
                continue;
            }

            writer.reset();
            try publish.writePublish(
                writer,
                publish_packet.topic,
                publish_packet.payload,
                .AtMostOnce,
                publish_packet.retain,
                false,
                null,
            );

            writer.writeToStream(&subscriber.stream) catch |err| {
                logger.err("   ❌ Failed to send to {s}: {any}", .{ subscriber.identifer, err });
                continue;
            };

            logger.debug("   ✅ Forwarded to {s}", .{subscriber.identifer});
        }
    }

    /// 并发转发给大量订阅者(>5个,使用线程池)
    fn forwardConcurrently(self: *MqttBroker, subscribers: []*Client, publish_packet: anytype) !void {
        // 预先序列化PUBLISH包(避免每个线程重复序列化)
        const temp_writer = try packet.Writer.init(self.allocator);
        defer temp_writer.deinit();

        try publish.writePublish(
            temp_writer,
            publish_packet.topic,
            publish_packet.payload,
            .AtMostOnce,
            publish_packet.retain,
            false,
            null,
        );

        const serialized_packet = temp_writer.buffer[0..temp_writer.pos];

        // 创建共享的数据包缓冲区
        const packet_copy = try self.allocator.dupe(u8, serialized_packet);
        defer self.allocator.free(packet_copy);

        // 使用线程批量发送
        var threads = try self.allocator.alloc(std.Thread, subscribers.len);
        defer self.allocator.free(threads);

        var thread_count: usize = 0;
        for (subscribers) |subscriber| {
            if (!subscriber.is_connected) {
                logger.warn("   ⚠️  Skipping disconnected subscriber: {s}", .{subscriber.identifer});
                continue;
            }

            const ForwardContext = struct {
                subscriber: *Client,
                packet_data: []const u8,
            };

            const ctx = ForwardContext{
                .subscriber = subscriber,
                .packet_data = packet_copy,
            };

            threads[thread_count] = try std.Thread.spawn(.{}, forwardWorker, .{ctx});
            thread_count += 1;
        }

        // 等待所有线程完成
        for (threads[0..thread_count]) |thread| {
            thread.join();
        }

        logger.debug("   ✅ Forwarded to {d} subscribers concurrently", .{thread_count});
    }

    /// 并发转发的工作线程
    fn forwardWorker(ctx: anytype) void {
        const stream = &ctx.subscriber.stream;
        stream.writeAll(ctx.packet_data) catch |err| {
            logger.err("   ❌ Failed to send to {s}: {any}", .{ ctx.subscriber.identifer, err });
            return;
        };
        logger.debug("   ✅ Forwarded to {s}", .{ctx.subscriber.identifer});
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
                        try connect.connack(writer, &client.stream, reason_code, false);
                        logger.debug("Server sent CONNACK (rejection) to {s}", .{client_name});
                        return;
                    } else {
                        // Set reason_code to Success if everything is okay
                        reason_code = mqtt.ReasonCode.Success;

                        // 设置客户端信息(需要拷贝 client_identifier,因为它指向 Reader 的临时缓冲区)
                        client.identifer = try self.allocator.dupe(u8, connect_packet.client_identifier);
                        client.protocol_version = mqtt.ProtocolVersion.fromU8(connect_packet.protocol_version);
                        client.keep_alive = connect_packet.keep_alive;
                        client.clean_start = connect_packet.connect_flags.clean_session;
                        client.is_connected = true;
                        client.connect_time = time.milliTimestamp();
                        client.last_activity = client.connect_time;

                        // 确定会话状态
                        // [MQTT-3.2.2-1] 如果 Clean Session = 1, Session Present 必须为 0
                        const session_present = if (connect_packet.connect_flags.clean_session)
                            false
                        else
                            false; // TODO: 实现会话持久化后,检查是否有该客户端的会话状态

                        // ack the connection (重新获取 client_name,因为 identifer 已更新)
                        const client_name_updated = getClientDisplayName(client);
                        logger.info("{s} connected successfully (keep_alive={d}s, clean_session={any})", .{ client_name_updated, client.keep_alive, client.clean_start });
                        try connect.connack(writer, &client.stream, reason_code, session_present);
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

                    // 读取 PUBLISH 包
                    const publish_packet = try publish.read(reader);

                    logger.info("{s} published to '{s}' (payload: {d} bytes)", .{ client_name, publish_packet.topic, publish_packet.payload.len });

                    // 根据 QoS 发送确认
                    switch (publish_packet.qos) {
                        .AtMostOnce => {}, // QoS 0 不需要确认
                        .AtLeastOnce => {
                            if (publish_packet.packet_id) |pid| {
                                try publish.sendPuback(writer, client, pid);
                            }
                        },
                        .ExactlyOnce => {
                            if (publish_packet.packet_id) |pid| {
                                try publish.sendPubrec(writer, client, pid);
                            }
                        },
                    }

                    // 查找匹配的订阅者 (传递发布者的 MQTT 客户端 ID 以支持 no_local)
                    var matched_clients = try self.subscriptions.match(publish_packet.topic, client.identifer, &self.allocator);
                    defer matched_clients.deinit(self.allocator);

                    logger.info("   📨 Found {d} matching subscriber(s)", .{matched_clients.items.len});

                    // 批量并发转发优化
                    const start_forward = std.time.nanoTimestamp();

                    if (matched_clients.items.len == 0) {
                        // 无订阅者,跳过
                    } else if (matched_clients.items.len == 1) {
                        // 单个订阅者,直接同步发送
                        try self.forwardToSingle(matched_clients.items[0], publish_packet, writer);
                    } else if (matched_clients.items.len <= 5) {
                        // 少量订阅者(2-5个),顺序发送(避免线程创建开销)
                        try self.forwardSequentially(matched_clients.items, publish_packet, writer);
                    } else {
                        // 大量订阅者(>5个),并发发送
                        try self.forwardConcurrently(matched_clients.items, publish_packet);
                    }

                    const end_forward = std.time.nanoTimestamp();
                    const forward_time_ns: i64 = @intCast(end_forward - start_forward);
                    const forward_time_ms = @as(f64, @floatFromInt(forward_time_ns)) / 1_000_000.0;
                    logger.debug("   ⏱️  Forward time: {d} ns ({d:.3} ms)", .{ forward_time_ns, forward_time_ms });

                    // 移动 reader 位置到末尾
                    reader.pos = reader.length;
                },
                .UNSUBSCRIBE => {
                    logger.debug("{s} sent UNSUBSCRIBE", .{client_name});

                    const unsubscribe_packet = try unsubscribe.read(reader, self.allocator);
                    defer {
                        unsubscribe_packet.deinit(self.allocator);
                        self.allocator.destroy(unsubscribe_packet);
                    }

                    logger.debug("Processing UNSUBSCRIBE packet with {d} topic(s)", .{unsubscribe_packet.topics.items.len});
                    for (unsubscribe_packet.topics.items) |topic| {
                        // 从主题树中移除订阅
                        const removed = try self.subscriptions.unsubscribe(topic, client);

                        if (removed) {
                            // 同步更新客户端的订阅列表
                            client.removeSubscription(topic);
                            logger.info("{s} unsubscribed from topic: {s}", .{ client_name, topic });
                        } else {
                            logger.warn("{s} attempted to unsubscribe from topic '{s}' but was not subscribed", .{ client_name, topic });
                        }
                    }

                    // 服务器必须响应 UNSUBACK 数据包 [MQTT-3.10.4-4]
                    // 注意:即使取消订阅失败,也要发送 UNSUBACK (MQTT 规范要求)
                    try unsubscribe.unsuback(writer, &client.stream, unsubscribe_packet.packet_id);
                    logger.debug("Server sent UNSUBACK to {s}", .{client_name});
                },
                .PUBREC => {
                    logger.debug("{s} sent PUBREC", .{client_name});
                    // 客户端发送 PUBREC 说明它收到了我们转发的 QoS 2 消息 (我们作为发布者)
                    // 当前实现转发时使用 QoS 0,所以暂不处理
                },
                .PUBREL => {
                    logger.debug("{s} sent PUBREL", .{client_name});
                    // QoS 2 第二步:客户端确认收到 PUBREC,我们需要发送 PUBCOMP
                    const packet_id = try reader.readTwoBytes();
                    try publish.sendPubcomp(writer, client, packet_id);

                    // 移动 reader 位置
                    reader.pos = reader.length;
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
