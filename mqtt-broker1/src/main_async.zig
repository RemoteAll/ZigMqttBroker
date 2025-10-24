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
const Metrics = @import("metrics.zig").Metrics;
const SubscriptionPersistence = @import("persistence.zig").SubscriptionPersistence;
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const time = std.time;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const ArenaAllocator = std.heap.ArenaAllocator;

const Client = @import("client.zig").Client;

// 导入 iobeetle IO 模块
const IO = @import("iobeetle/io.zig").IO;

// MemoryPool 类型定义
const ClientConnectionPool = std.heap.MemoryPoolExtra(ClientConnection, .{ .growable = false });

/// 客户端连接状态机
const ConnectionState = enum {
    Accepting, // 正在接受连接
    Reading, // 正在读取数据
    Processing, // 正在处理 MQTT 包
    Writing, // 正在写入响应
    Disconnecting, // 正在断开连接
};

/// 异步客户端连接上下文
const ClientConnection = struct {
    id: u64,
    socket: IO.socket_t,
    state: ConnectionState,
    client: *Client,
    broker: *MqttBroker,

    // IO completion 结构体
    accept_completion: IO.Completion = undefined,
    recv_completion: IO.Completion = undefined,
    send_completion: IO.Completion = undefined,
    close_completion: IO.Completion = undefined,

    // 读写缓冲区
    read_buffer: []u8,
    reader: packet.Reader,
    writer: *packet.Writer,

    // Arena分配器用于此连接的所有内存分配
    arena: *ArenaAllocator,

    // 防止重复断开连接
    is_disconnecting: bool = false,

    pub fn init(
        base_allocator: Allocator,
        id: u64,
        socket: IO.socket_t,
        broker: *MqttBroker,
    ) !*ClientConnection {
        // 创建Arena分配器
        const arena = try base_allocator.create(ArenaAllocator);
        errdefer base_allocator.destroy(arena);
        arena.* = ArenaAllocator.init(base_allocator);

        const arena_allocator = arena.allocator();

        const self = try arena_allocator.create(ClientConnection);

        // 创建 Client 实例(临时使用空地址和流)
        const dummy_address = try net.Address.parseIp("0.0.0.0", 0);
        const dummy_stream = net.Stream{ .handle = socket };
        const client = try Client.init(arena_allocator, id, mqtt.ProtocolVersion.Invalid, dummy_stream, dummy_address);

        const read_buffer = try arena_allocator.alloc(u8, config.READ_BUFFER_SIZE);

        const writer = try packet.Writer.init(arena_allocator);

        self.* = .{
            .id = id,
            .socket = socket,
            .state = .Accepting,
            .client = client,
            .broker = broker,
            .read_buffer = read_buffer,
            .reader = packet.Reader.init(read_buffer),
            .writer = writer,
            .arena = arena,
            .is_disconnecting = false,
        };

        return self;
    }

    pub fn deinit(self: *ClientConnection, base_allocator: Allocator) void {
        // 检查 Client 对象的引用计数
        const ref_count = self.client.getRefCount();
        if (ref_count > 0) {
            // 警告：仍有其他引用（订阅树等）持有该 Client 指针
            // 但由于使用 Arena 分配，Arena.deinit() 会释放所有内存
            // 这会导致订阅树中的指针变成悬垂指针
            logger.warn(
                "Client {s} (#{}) still has {} reference(s) when deinit, potential dangling pointers!",
                .{ self.client.identifer, self.client.id, ref_count },
            );

            // 解决方案：确保在 deinit 前调用 unsubscribeAll
            // 或者实现延迟清理机制
        } else {
            logger.debug("Client {s} (#{}) can be safely freed (ref_count=0)", .{ self.client.identifer, self.client.id });
        }

        // Arena会自动释放所有分配的内存（包括 Client 对象）
        self.arena.deinit();
        base_allocator.destroy(self.arena);
    }

    /// 开始异步读取数据
    pub fn startRead(self: *ClientConnection, io: *IO) void {
        self.state = .Reading;
        io.recv(
            *ClientConnection,
            self,
            onRecvComplete,
            &self.recv_completion,
            self.socket,
            self.read_buffer,
        );
    }

    /// recv 完成回调
    fn onRecvComplete(
        self: *ClientConnection,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        _ = completion;

        // 如果已经在断开连接，忽略此回调
        if (self.is_disconnecting) {
            logger.debug("Client {d} recv callback ignored (already disconnecting)", .{self.id});
            return;
        }

        const length = result catch |err| {
            // 区分不同类型的错误
            switch (err) {
                // 正常的断开/取消操作 - 使用 DEBUG 级别
                error.OperationCancelled => {
                    // CancelIoEx 取消的操作 - 这是我们主动调用的，完全正常
                    logger.debug("Client {d} recv operation cancelled (normal disconnect)", .{self.id});
                },
                error.SocketNotConnected => {
                    // Socket 已关闭或未连接 - 断开流程中的正常情况
                    logger.debug("Client {d} recv error (socket not connected)", .{self.id});
                },
                error.Unexpected => {
                    // Windows socket 关闭导致的其他错误
                    logger.debug("Client {d} recv error (unexpected): {any}", .{ self.id, err });
                },
                error.ConnectionResetByPeer => {
                    // 客户端主动断开或网络中断 - 这是正常的
                    logger.info("Client {d} ({s}) disconnected by peer", .{ self.id, self.client.identifer });
                    self.broker.metrics.incNetworkError();
                },
                else => {
                    // 其他非预期错误 - 使用 ERROR 级别
                    logger.err("Client {d} recv error: {any}", .{ self.id, err });
                    self.broker.metrics.incNetworkError();
                },
            }
            self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after recv error: {any}", .{disconnect_err});
            };
            return;
        };

        if (length == 0) {
            logger.info("Client {d} disconnected (EOF)", .{self.id});
            self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after EOF: {any}", .{disconnect_err});
            };
            return;
        }

        logger.debug("Client {d} received {d} bytes", .{ self.id, length });

        // 更新指标
        self.broker.metrics.incMessageReceived(length);

        // 更新客户端活动时间
        self.client.updateActivity();

        // 处理接收到的数据
        self.reader.start(length) catch |err| {
            logger.err("Client {d} reader.start error: {any}", .{ self.id, err });
            self.broker.metrics.incProtocolError();
            self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after reader error: {any}", .{disconnect_err});
            };
            return;
        };

        // 解析并处理 MQTT 包
        self.processPackets() catch |err| {
            logger.err("Client {d} process error: {any}", .{ self.id, err });
            self.broker.metrics.incProtocolError();
            self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after process error: {any}", .{disconnect_err});
            };
            return;
        };

        // 继续读取下一批数据
        self.startRead(self.broker.io);
    }

    /// 处理接收到的 MQTT 包
    fn processPackets(self: *ClientConnection) !void {
        self.state = .Processing;

        while (self.reader.pos < self.reader.length) {
            const start_pos = self.reader.pos;

            const cmd = self.reader.readCommand() catch |err| {
                logger.warn("Client {d} unknown command: {any}", .{ self.id, err });
                break;
            };

            if (cmd == .DISCONNECT) {
                logger.info("Client {d} sent DISCONNECT", .{self.id});
                self.disconnect() catch |disconnect_err| {
                    std.log.err("Failed to disconnect client after DISCONNECT packet: {any}", .{disconnect_err});
                };
                return;
            }

            const remaining_length = try self.reader.readRemainingLength();

            // 计算当前包的结束位置
            const packet_end_pos = self.reader.pos + remaining_length;

            // 检查是否有完整的包数据
            if (packet_end_pos > self.reader.length) {
                // 数据不完整,回退到包开始位置,等待更多数据
                self.reader.pos = start_pos;
                break;
            }

            logger.debug("Client {d} packet type={any} payload={d} bytes", .{ self.id, cmd, remaining_length });

            switch (cmd) {
                .CONNECT => try self.handleConnect(),
                .SUBSCRIBE => try self.handleSubscribe(),
                .PUBLISH => try self.handlePublish(),
                .UNSUBSCRIBE => try self.handleUnsubscribe(),
                .PINGREQ => try self.handlePingreq(),
                .PUBACK => try self.handlePuback(),
                .PUBREC => try self.handlePubrec(),
                .PUBREL => try self.handlePubrel(),
                .PUBCOMP => try self.handlePubcomp(),
                else => {
                    logger.warn("Client {d} unhandled packet type: {any}", .{ self.id, cmd });
                },
            }

            // 无论handler是否正确处理,都强制跳转到下一个包的起始位置
            // 这样可以避免包边界混乱的问题
            self.reader.pos = packet_end_pos;
        }
    }

    fn handleConnect(self: *ClientConnection) !void {
        var reason_code = mqtt.ReasonCode.MalformedPacket;

        const connect_packet = connect.read(&self.reader, self.arena.allocator()) catch |err| {
            logger.err("Client {d} CONNECT parse error: {any}", .{ self.id, err });
            return;
        };

        const errors = connect_packet.getErrors();
        if (errors.len > 0) {
            logger.warn("Client {d} CONNECT has {d} errors", .{ self.id, errors.len });

            // 输出所有错误的详细信息
            for (errors, 0..) |packet_error, i| {
                logger.warn("  Error {d}: {s} at byte position {d}", .{ i + 1, @errorName(packet_error.err), packet_error.byte_position });
            }

            // 根据错误类型设置 reason_code
            reason_code = switch (errors[0].err) {
                ConnectError.UsernameMustBePresent,
                ConnectError.PasswordMustBePresent,
                ConnectError.PasswordMustNotBeSet,
                => mqtt.ReasonCode.BadUserNameOrPassword,

                ConnectError.ClientIdNotUTF8,
                ConnectError.ClientIdTooLong,
                ConnectError.ClientIdTooShort,
                ConnectError.InvalidClientId,
                => mqtt.ReasonCode.ClientIdentifierNotValid,

                else => mqtt.ReasonCode.MalformedPacket,
            };

            // 发送 CONNACK 拒绝
            try connect.connack(self.writer, &self.client.stream, reason_code, false);
            self.broker.metrics.incMessageSent(4); // CONNACK 固定4字节(包含字节统计)
            logger.warn("Client {d} connection rejected: {any}", .{ self.id, reason_code });
            self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after CONNACK rejection: {any}", .{disconnect_err});
            };
            return;
        }

        // 连接成功
        reason_code = mqtt.ReasonCode.Success;

        // 设置客户端信息
        self.client.identifer = try self.arena.allocator().dupe(u8, connect_packet.client_identifier);
        self.client.protocol_version = mqtt.ProtocolVersion.fromU8(connect_packet.protocol_version);
        self.client.keep_alive = connect_packet.keep_alive;
        self.client.clean_start = connect_packet.connect_flags.clean_session;

        // 设置会话过期时间
        // MQTT 3.1.1: 使用服务器配置的默认值（协议本身不支持此字段）
        // MQTT 5.0: 应该从 CONNECT 包的属性中读取（待实现）
        if (self.client.clean_start) {
            // Clean Session = 1: 会话立即过期
            self.client.session_expiry_interval = 0;
        } else {
            // Clean Session = 0: 使用默认过期时间
            // TODO: MQTT 5.0 应该从 connect_packet 的 Session Expiry Interval 属性读取
            self.client.session_expiry_interval = config.DEFAULT_SESSION_EXPIRY_SEC;
        }

        self.client.is_connected = true;
        self.client.connect_time = time.milliTimestamp();
        self.client.last_activity = self.client.connect_time;

        // 检查是否是重连（同一个 MQTT Client ID）
        const mqtt_client_id = self.client.identifer;
        const has_existing_session = self.broker.clients.get(mqtt_client_id) != null;

        // 检查是否有持久化的订阅（用于判断 session_present）
        const has_persisted_subscriptions = blk: {
            var subs = self.broker.persistence.getClientSubscriptions(mqtt_client_id, self.arena.allocator()) catch null;
            if (subs) |*s| {
                defer {
                    for (s.items) |sub| {
                        self.arena.allocator().free(sub.topic_filter);
                    }
                    s.deinit(self.arena.allocator());
                }
                break :blk s.items.len > 0;
            }
            break :blk false;
        };

        if (self.broker.clients.get(mqtt_client_id)) |old_conn| {
            logger.info("Client {s} is reconnecting (old_conn #{d}), handling session...", .{ mqtt_client_id, old_conn.id });

            // 根据 Clean Session 标志决定如何处理旧会话
            if (connect_packet.connect_flags.clean_session) {
                // Clean Session = 1: 清除旧会话的所有订阅（包括持久化）
                logger.info("Clean Session = 1, clearing old subscriptions for {s}", .{mqtt_client_id});
                self.broker.subscriptions.unsubscribeAll(old_conn.client);
            } else {
                // Clean Session = 0: 保留订阅，但需要更新订阅树中的 Client 指针
                // 这样订阅树中的指针指向新的 Client 对象
                logger.info("Clean Session = 0, preserving subscriptions for {s}", .{mqtt_client_id});
                // 订阅树中的 *Client 指针会在下面的 put 操作后自动指向新的 client
            }

            // 关闭旧连接的 socket 和网络资源
            self.broker.io.close_socket(old_conn.socket);
            // 注意：不调用 old_conn.deinit()，因为订阅树可能还在引用 old_conn.client
            // 而是让新连接复用旧会话的 Client 对象
        }

        // 将新连接注册到 broker（重连时会替换旧连接）
        try self.broker.clients.put(mqtt_client_id, self);

        // 确定会话状态
        // [MQTT-3.2.2-1] 如果 Clean Session = 1, Session Present 必须为 0
        // [MQTT-3.2.2-2] 如果 Clean Session = 0, Session Present 取决于是否有保存的会话
        const session_present = if (connect_packet.connect_flags.clean_session)
            false // Clean Session = 1 时必须返回 false
        else
            (has_existing_session or has_persisted_subscriptions); // Clean Session = 0 时，如果有旧会话或持久化订阅则返回 true

        // 发送 CONNACK
        try connect.connack(self.writer, &self.client.stream, reason_code, session_present);
        self.broker.metrics.incMessageSent(4); // CONNACK 固定4字节(包含字节统计)

        // 根据 Clean Session 标志判断连接类型
        const connection_type = if (connect_packet.connect_flags.clean_session)
            "NEW/CLEAN" // Clean Session = 1: 明确要求清除旧会话
        else if (session_present)
            "RECONNECT" // Clean Session = 0 且找到旧会话
        else
            "NEW/PERSISTENT"; // Clean Session = 0 但没有旧会话（首次连接或会话已过期）

        logger.info("Client {d} ({s}) connected successfully [{s}] (CleanSession={}, SessionPresent={})", .{
            self.id,
            self.client.identifer,
            connection_type,
            connect_packet.connect_flags.clean_session,
            session_present,
        });

        // 如果 session_present = true，恢复持久化的订阅到主题树
        if (session_present and !connect_packet.connect_flags.clean_session) {
            self.broker.subscriptions.restoreClientSubscriptions(self.client) catch |err| {
                logger.err("Failed to restore subscriptions for client {s}: {any}", .{ self.client.identifer, err });
            };
        }
    }

    fn handleSubscribe(self: *ClientConnection) !void {
        const subscribe_packet = try subscribe.read(&self.reader, self.client, self.arena.allocator());

        logger.debug("Client {d} SUBSCRIBE {d} topics", .{ self.id, subscribe_packet.topics.items.len });

        for (subscribe_packet.topics.items) |topic| {
            try self.broker.subscriptions.subscribe(topic.filter, self.client);
            self.broker.metrics.incSubscription();
            logger.info("Client {d} ({s}) subscribed to: {s}", .{ self.id, self.client.identifer, topic.filter });
        }

        try subscribe.suback(self.writer, &self.client.stream, subscribe_packet.packet_id, self.client);
        // SUBACK: 固定头(2) + 包ID(2) + 返回码(topics数量)
        const suback_size = 2 + 2 + subscribe_packet.topics.items.len;
        self.broker.metrics.incMessageSent(suback_size); // 包含字节统计
    }

    fn handlePublish(self: *ClientConnection) !void {
        const publish_packet = try publish.read(&self.reader);

        // 更新指标
        self.broker.metrics.incPublishReceived();

        logger.info("Client {d} ({s}) published to '{s}' ({d} bytes)", .{
            self.id,
            self.client.identifer,
            publish_packet.topic,
            publish_packet.payload.len,
        });

        // 根据 QoS 发送确认
        switch (publish_packet.qos) {
            .AtMostOnce => {},
            .AtLeastOnce => {
                if (publish_packet.packet_id) |pid| {
                    try publish.sendPuback(self.writer, self.client, pid);
                    self.broker.metrics.incMessageSent(4); // PUBACK 固定4字节(包含字节统计)
                }
            },
            .ExactlyOnce => {
                if (publish_packet.packet_id) |pid| {
                    try publish.sendPubrec(self.writer, self.client, pid);
                    self.broker.metrics.incMessageSent(4); // PUBREC 固定4字节(包含字节统计)
                }
            },
        }

        // 转发给订阅者
        var arena_allocator = self.arena.allocator();
        var matched_clients = try self.broker.subscriptions.match(
            publish_packet.topic,
            self.client.identifer,
            &arena_allocator,
        );
        defer matched_clients.deinit(arena_allocator);

        if (matched_clients.items.len > 0) {
            logger.debug("Forwarding to {d} subscribers", .{matched_clients.items.len});

            // 使用智能转发策略(metrics在forward函数内部更新)
            if (matched_clients.items.len == 1) {
                try self.forwardToSingle(matched_clients.items[0], publish_packet);
            } else {
                try self.forwardSequentially(matched_clients.items, publish_packet);
            }
        }
    }

    fn handleUnsubscribe(self: *ClientConnection) !void {
        const unsubscribe_packet = try unsubscribe.read(&self.reader, self.arena.allocator());

        for (unsubscribe_packet.topics.items) |topic_filter| {
            _ = try self.broker.subscriptions.unsubscribe(topic_filter, self.client);
            self.broker.metrics.decSubscription();
            logger.info("Client {d} ({s}) unsubscribed from: {s}", .{ self.id, self.client.identifer, topic_filter });
        }

        try unsubscribe.unsuback(self.writer, &self.client.stream, unsubscribe_packet.packet_id);
    }

    fn handlePingreq(self: *ClientConnection) !void {
        self.writer.reset();
        try self.writer.writeByte(0xD0); // PINGRESP 包类型
        try self.writer.writeByte(0); // Remaining length = 0
        try self.writer.writeToStream(&self.client.stream);
        logger.debug("Client {d} PINGREQ -> PINGRESP", .{self.id});
    }

    /// 处理 PUBACK (QoS 1 发布确认)
    fn handlePuback(self: *ClientConnection) !void {
        // 读取 packet_id (2 字节)
        const packet_id = try self.reader.readTwoBytes();
        logger.debug("Client {d} ({s}) sent PUBACK for packet {d}", .{ self.id, self.client.identifer, packet_id });

        // TODO: 从待确认队列中移除对应的消息
        // 这里应该维护一个 pending_messages 映射来跟踪等待确认的消息
    }

    /// 处理 PUBREC (QoS 2 发布接收 - 第一步)
    fn handlePubrec(self: *ClientConnection) !void {
        // 读取 packet_id (2 字节)
        const packet_id = try self.reader.readTwoBytes();
        logger.debug("Client {d} ({s}) sent PUBREC for packet {d}", .{ self.id, self.client.identifer, packet_id });

        // 响应 PUBREL (QoS 2 第二步)
        self.writer.reset();
        try self.writer.writeByte(0x62); // PUBREL 包类型 (0110 0010)
        try self.writer.writeByte(2); // Remaining length = 2 (packet_id)
        try self.writer.writeTwoBytes(packet_id);
        try self.writer.writeToStream(&self.client.stream);

        // 记录发送的 PUBREL 消息
        self.broker.metrics.incMessageSent(4);

        logger.debug("Client {d} sent PUBREL for packet {d}", .{ self.id, packet_id });
    }

    /// 处理 PUBREL (QoS 2 发布释放 - 第二步,来自客户端)
    fn handlePubrel(self: *ClientConnection) !void {
        // 读取 packet_id (2 字节)
        const packet_id = try self.reader.readTwoBytes();
        logger.debug("Client {d} ({s}) sent PUBREL for packet {d}", .{ self.id, self.client.identifer, packet_id });

        // 响应 PUBCOMP (QoS 2 第三步 - 完成)
        self.writer.reset();
        try self.writer.writeByte(0x70); // PUBCOMP 包类型 (0111 0000)
        try self.writer.writeByte(2); // Remaining length = 2 (packet_id)
        try self.writer.writeTwoBytes(packet_id);
        try self.writer.writeToStream(&self.client.stream);

        // 记录发送的 PUBCOMP 消息
        self.broker.metrics.incMessageSent(4);

        logger.debug("Client {d} sent PUBCOMP for packet {d}", .{ self.id, packet_id });

        // TODO: 从待处理队列中移除对应的消息
    }

    /// 处理 PUBCOMP (QoS 2 发布完成 - 第三步确认)
    fn handlePubcomp(self: *ClientConnection) !void {
        // 读取 packet_id (2 字节)
        const packet_id = try self.reader.readTwoBytes();
        logger.debug("Client {d} ({s}) sent PUBCOMP for packet {d}", .{ self.id, self.client.identifer, packet_id });

        // QoS 2 流程完成，从待确认队列中移除消息
        // TODO: 实现 pending_qos2_messages 映射
    }

    /// 转发给单个订阅者
    fn forwardToSingle(self: *ClientConnection, subscriber: *Client, publish_packet: anytype) !void {
        if (!subscriber.is_connected) return;

        // 使用 MQTT Client ID 从 broker 的客户端映射中查找
        const subscriber_conn = self.broker.clients.get(subscriber.identifer) orelse {
            logger.warn("Subscriber {s} not found in broker clients map", .{subscriber.identifer});
            return;
        };

        // 使用订阅者自己的 writer 来发送消息
        subscriber_conn.writer.reset();
        try publish.writePublish(
            subscriber_conn.writer,
            publish_packet.topic,
            publish_packet.payload,
            .AtMostOnce,
            publish_packet.retain,
            false,
            null,
        );

        const bytes_sent = subscriber_conn.writer.pos;
        try subscriber_conn.writer.writeToStream(&subscriber.stream);

        // 记录转发指标
        self.broker.metrics.incPublishSent();
        self.broker.metrics.incMessageSent(bytes_sent);

        logger.debug("Forwarded to {s}", .{subscriber.identifer});
    }

    /// 顺序转发给多个订阅者（高性能版本：共享序列化结果）
    fn forwardSequentially(self: *ClientConnection, subscribers: []*Client, publish_packet: anytype) !void {
        // 性能优化：先构建一次 PUBLISH 包，然后共享给所有订阅者
        // 对于大规模订阅（100万+设备），避免重复序列化

        // 1. 使用发布者的 writer 构建一次 PUBLISH 包
        self.writer.reset();
        try publish.writePublish(
            self.writer,
            publish_packet.topic,
            publish_packet.payload,
            .AtMostOnce,
            publish_packet.retain,
            false,
            null,
        );

        // 2. 获取序列化后的字节切片（零拷贝共享）
        const serialized_message = self.writer.buffer[0..self.writer.pos];
        const message_size = serialized_message.len;

        // 3. 将预序列化的消息直接发送给所有订阅者
        var sent_count: usize = 0;
        var error_count: usize = 0;

        for (subscribers) |subscriber| {
            if (!subscriber.is_connected) continue;

            // 使用 MQTT Client ID 从 broker 的客户端映射中查找
            const subscriber_conn = self.broker.clients.get(subscriber.identifer) orelse {
                logger.warn("Subscriber {s} not found in broker clients map", .{subscriber.identifer});
                error_count += 1;
                continue;
            };

            // 直接写入预序列化的字节流（零拷贝）
            subscriber_conn.client.stream.writeAll(serialized_message) catch |err| {
                logger.err("Failed to forward to {s}: {any}", .{ subscriber.identifer, err });
                self.broker.metrics.incNetworkError();
                error_count += 1;
                continue;
            };

            // 记录转发指标
            self.broker.metrics.incPublishSent();
            self.broker.metrics.incMessageSent(message_size);
            sent_count += 1;
        }

        // 批量日志记录（避免100万次日志调用）
        if (sent_count > 10) {
            logger.info("Forwarded to {d} subscribers ({d} errors)", .{ sent_count, error_count });
        } else {
            for (subscribers) |subscriber| {
                if (subscriber.is_connected) {
                    logger.debug("Forwarded to {s}", .{subscriber.identifer});
                }
            }
        }
    }

    /// 断开连接
    fn disconnect(self: *ClientConnection) !void {
        // 防止重复断开连接
        if (self.is_disconnecting) {
            return;
        }
        self.is_disconnecting = true;

        self.state = .Disconnecting;
        logger.info("Client {d} ({s}) disconnecting (clean_start={})", .{ self.id, self.client.identifer, self.client.clean_start });

        // 记录连接关闭
        self.broker.metrics.incConnectionClosed();

        // 标记客户端为已断开(但不立即释放)
        self.client.is_connected = false;

        // 记录断开时间（用于会话过期判断）
        self.client.disconnect_time = std.time.milliTimestamp();

        // 根据 Clean Session 标志决定是否清理订阅
        // [MQTT-3.1.2-6] Clean Session = 1: 断开时必须删除会话状态
        // [MQTT-3.1.2-5] Clean Session = 0: 断开时保留会话状态
        if (self.client.clean_start) {
            // Clean Session = 1: 清理订阅(从主题树和持久化)
            logger.info("Client {s} disconnecting with Clean Session = 1, clearing all subscriptions", .{self.client.identifer});
            self.broker.subscriptions.unsubscribeAll(self.client);
        } else {
            // Clean Session = 0: 保留订阅,仅标记为离线
            // 订阅仍在主题树中,但消息转发时会跳过(因为 is_connected = false)
            logger.info("Client {s} disconnecting with Clean Session = 0, preserving subscriptions for reconnection", .{self.client.identifer});
        }

        // 关闭 socket（这会取消所有待处理的 IO 操作）
        // 注意：关闭 socket 后，不应再有新的 IO 操作回调触发
        self.broker.io.close_socket(self.socket);

        // 从 broker 移除客户端连接（使用 MQTT Client ID）
        // 注意：只有当前连接才移除，避免移除新的重连
        if (self.client.identifer.len > 0) {
            if (self.broker.clients.get(self.client.identifer)) |current_conn| {
                // 只有当 HashMap 中的连接就是当前连接时才移除
                if (current_conn == self) {
                    _ = self.broker.clients.remove(self.client.identifer);
                }
            }
        }

        // 检查引用计数决定是否立即释放
        const ref_count = self.client.getRefCount();
        if (ref_count > 1) {
            // ⚠️ 仍有订阅树等持有引用，不能立即释放 Client 对象
            // 将 Client 对象转移到 Broker 的 orphan_clients 管理
            logger.info(
                "Client {s} (#{}) still has {} reference(s), transferring to orphan_clients for lifecycle management",
                .{ self.client.identifer, self.client.id, ref_count - 1 },
            );

            // 将 Client 对象从 Arena 分配器"转移"到 Broker 的全局 allocator
            // 注意：这里需要创建一个新的 Client 副本，因为原 Client 由 Arena 管理
            const orphan_client = self.broker.allocator.create(Client) catch |err| {
                logger.err("Failed to create orphan client: {any}", .{err});
                // 无法转移，只能泄漏
                return;
            };

            // 复制 Client 数据（浅拷贝，共享字符串指针）
            orphan_client.* = self.client.*;

            // 重新初始化引用计数（继承当前的订阅引用）
            orphan_client.ref_count = std.atomic.Value(u32).init(@intCast(ref_count - 1));

            // 更新订阅树中的指针指向新的 orphan_client
            // 这一步很关键：替换订阅树中所有指向旧 Client 的引用
            self.broker.subscriptions.replaceClientPointer(self.client, orphan_client) catch |err| {
                logger.err("Failed to replace client pointer in subscription tree: {any}", .{err});
                self.broker.allocator.destroy(orphan_client);
                return;
            };

            // 将 orphan_client 加入 broker 管理
            self.broker.orphan_clients.put(
                try self.broker.allocator.dupe(u8, self.client.identifer),
                orphan_client,
            ) catch |err| {
                logger.err("Failed to add orphan client to broker: {any}", .{err});
                self.broker.allocator.destroy(orphan_client);
                return;
            };

            logger.info("Client {s} successfully transferred to orphan_clients", .{self.client.identifer});

            // 现在可以安全释放 ClientConnection 和它的 Arena
            // orphan_client 已经独立管理
            self.deinit(self.broker.allocator);
        } else {
            // ref_count <= 1: 只有 ClientConnection 持有引用，可以安全释放
            logger.debug("Client {s} (#{}) can be safely freed (ref_count=1)", .{ self.client.identifer, self.client.id });

            // 清理资源
            self.deinit(self.broker.allocator);
        }
    }
};

/// 异步 MQTT Broker
pub const MqttBroker = struct {
    allocator: Allocator,
    io: *IO,
    clients: std.StringHashMap(*ClientConnection), // MQTT Client ID -> ClientConnection
    next_client_id: u64, // 仅用于日志记录的连接序号
    subscriptions: SubscriptionTree,
    server_socket: IO.socket_t,
    accept_completion: IO.Completion = undefined,

    // 新增字段: 内存池、统计定时器、指标
    client_pool: ClientConnectionPool,
    stats_completion: IO.Completion = undefined,
    metrics: Metrics,

    // 订阅持久化管理器
    persistence: *SubscriptionPersistence,

    // 孤儿 Client 对象: Clean Session = 0 断开时保留的 Client 对象
    // 这些 Client 已从 ClientConnection 分离,由 Broker 直接管理生命周期
    // Key: MQTT Client ID, Value: *Client
    orphan_clients: std.StringHashMap(*Client),

    pub fn init(allocator: Allocator) !*MqttBroker {
        const io = try allocator.create(IO);
        io.* = try IO.init(config.IO_ENTRIES, 0);

        // 创建并预热客户端连接池
        var client_pool = ClientConnectionPool.init(allocator);
        try client_pool.preheat(config.MAX_CLIENTS_POOL);
        logger.info("Client pool preheated with {d} connections", .{config.MAX_CLIENTS_POOL});

        // 初始化订阅持久化管理器
        const persistence = try allocator.create(SubscriptionPersistence);
        persistence.* = try SubscriptionPersistence.init(allocator, "data/subscriptions.json");

        // 从文件加载已保存的订阅
        persistence.loadFromFile() catch |err| {
            logger.warn("Failed to load persisted subscriptions: {any}", .{err});
        };

        var subscriptions = SubscriptionTree.init(allocator);
        subscriptions.setPersistence(persistence);

        const self = try allocator.create(MqttBroker);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clients = std.StringHashMap(*ClientConnection).init(allocator),
            .next_client_id = 1,
            .subscriptions = subscriptions,
            .server_socket = IO.INVALID_SOCKET,
            .client_pool = client_pool,
            .metrics = Metrics.init(),
            .persistence = persistence,
            .orphan_clients = std.StringHashMap(*Client).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *MqttBroker) void {
        logger.info("Shutting down MQTT broker...", .{});

        // 输出最终统计信息
        self.metrics.logStats();

        // 清理所有客户端连接
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const conn = entry.value_ptr.*;
            self.io.close_socket(conn.socket);
            conn.deinit(self.allocator);
        }
        self.clients.deinit();

        // 清理孤儿 Client 对象
        var orphan_it = self.orphan_clients.iterator();
        while (orphan_it.next()) |entry| {
            const client = entry.value_ptr.*;
            const ref_count = client.getRefCount();
            logger.info("Cleaning up orphan client {s} (ref_count={})", .{ client.identifer, ref_count });

            // 强制清理订阅释放引用
            self.subscriptions.unsubscribeAll(client);

            // 现在应该可以安全释放了
            client.deinit();
        }
        self.orphan_clients.deinit();

        // 关闭服务器 socket
        if (self.server_socket != IO.INVALID_SOCKET) {
            self.io.close_socket(self.server_socket);
        }

        self.subscriptions.deinit();

        // 清理持久化管理器
        self.persistence.deinit();
        self.allocator.destroy(self.persistence);

        // 清理内存池
        self.client_pool.deinit();

        self.io.deinit();
        self.allocator.destroy(self.io);
        self.allocator.destroy(self);

        logger.info("MQTT broker shutdown complete", .{});
    }

    /// 检查并清理过期的 orphan_clients
    /// 根据 MQTT 规范，Clean Session = 0 的会话应该在 session_expiry_interval 后过期
    pub fn cleanupExpiredSessions(self: *MqttBroker) void {
        const now = std.time.milliTimestamp();
        var to_remove: std.ArrayList([]const u8) = .{};
        defer to_remove.deinit(self.allocator);

        // 遍历所有 orphan_clients，检查是否过期
        var it = self.orphan_clients.iterator();
        while (it.next()) |entry| {
            const client_id = entry.key_ptr.*;
            const client = entry.value_ptr.*;

            // 计算断开时长（毫秒）
            const disconnected_ms = now - client.disconnect_time;
            const session_expiry_ms: i64 = @as(i64, client.session_expiry_interval) * 1000;

            // 检查是否过期
            // session_expiry_interval = 0 表示会话在断开时立即过期
            // session_expiry_interval = 0xFFFFFFFF 表示会话永不过期
            const is_expired = if (client.session_expiry_interval == 0)
                true // 立即过期
            else if (client.session_expiry_interval == 0xFFFFFFFF)
                false // 永不过期
            else
                disconnected_ms >= session_expiry_ms;

            if (is_expired) {
                logger.info(
                    "Session expired for orphan client {s} (disconnected for {}ms, expiry={}s)",
                    .{ client_id, disconnected_ms, client.session_expiry_interval },
                );
                to_remove.append(self.allocator, client_id) catch continue;
            }
        }

        // 清理过期的 orphan_clients
        for (to_remove.items) |client_id| {
            if (self.orphan_clients.fetchRemove(client_id)) |kv| {
                const client = kv.value;
                const ref_count = client.getRefCount();

                logger.info(
                    "Removing expired orphan client {s} (ref_count={})",
                    .{ client_id, ref_count },
                );

                // 强制清理订阅以释放引用
                self.subscriptions.unsubscribeAll(client);

                // 从持久化存储中删除
                if (self.persistence.removeAllSubscriptions(client_id)) {
                    logger.debug("Removed persisted subscriptions for expired client {s}", .{client_id});
                } else |err| {
                    logger.warn("Failed to remove persisted subscriptions for {s}: {any}", .{ client_id, err });
                }

                // 释放 client_id 字符串内存
                self.allocator.free(client_id);

                // 释放 Client 对象
                client.deinit();
                self.allocator.destroy(client);
            }
        }

        if (to_remove.items.len > 0) {
            logger.info("Cleaned up {} expired session(s)", .{to_remove.items.len});
        }
    }

    /// 启动异步 MQTT Broker
    pub fn start(self: *MqttBroker, port: u16) !void {
        logger.info("Starting async MQTT broker on port {d}", .{port});

        // 创建监听 socket
        self.server_socket = try self.io.open_socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        errdefer self.io.close_socket(self.server_socket);

        // 绑定并监听
        const address = try net.Address.parseIp("0.0.0.0", port);
        const resolved_addr = try self.io.listen(
            self.server_socket,
            address,
            .{
                .rcvbuf = 0,
                .sndbuf = 0,
                .keepalive = null,
                .user_timeout_ms = 0,
                .nodelay = true,
                .backlog = 128,
            },
        );

        logger.info("Listening on {any}", .{resolved_addr});

        // 开始接受连接
        self.startAccept();

        // 启动统计定时器
        self.startStatsRoutine();

        // 进入事件循环
        logger.info("Entering event loop...", .{});
        while (true) {
            self.io.run() catch |err| {
                // IO 错误通常是由于已关闭的 socket 触发的，这是正常的断开流程
                // 只记录非预期的严重错误，其他错误忽略以保持服务器运行
                switch (err) {
                    error.Unexpected => {
                        // Socket 已关闭导致的 Unexpected 错误（如 WSAENOTSOCK）是正常的
                        // 不需要记录，继续运行
                        logger.debug("IO unexpected error (likely closed socket): {any}", .{err});
                    },
                    else => {
                        // 其他严重错误才需要关注
                        logger.err("IO critical error: {any}", .{err});
                        // 继续运行而不是退出，让服务器保持可用
                    },
                }
            };
        }
    }

    /// 开始异步接受连接
    fn startAccept(self: *MqttBroker) void {
        logger.debug("Starting accept operation (socket={any})...", .{self.server_socket});
        self.io.accept(
            *MqttBroker,
            self,
            onAcceptComplete,
            &self.accept_completion,
            self.server_socket,
        );
        logger.debug("Accept operation submitted", .{});
    }

    /// 启动统计定时器
    fn startStatsRoutine(self: *MqttBroker) void {
        self.io.timeout(
            *MqttBroker,
            self,
            onStatsTimeout,
            &self.stats_completion,
            config.STATS_INTERVAL_NS,
        );
    }

    /// 统计定时器回调
    fn onStatsTimeout(
        self: *MqttBroker,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        _ = completion;
        _ = result catch |err| {
            logger.err("Stats timeout error: {any}", .{err});
            return;
        };

        // 输出统计信息
        self.metrics.logStats();

        // 检查并清理过期的会话
        self.cleanupExpiredSessions();

        // 重新启动定时器
        self.startStatsRoutine();
    }

    /// accept 完成回调
    fn onAcceptComplete(
        self: *MqttBroker,
        completion: *IO.Completion,
        result: IO.AcceptError!IO.socket_t,
    ) void {
        _ = completion;

        logger.debug("Accept callback triggered", .{});

        const client_socket = result catch |err| {
            logger.err("Accept error: {any}", .{err});
            self.metrics.incNetworkError();
            // 继续接受新连接
            self.startAccept();
            return;
        };

        logger.info("Accepted socket: {any}", .{client_socket});

        // 检查连接数限制
        if (self.clients.count() >= config.MAX_CONNECTIONS) {
            logger.warn("Connection limit reached ({d}), refusing new connection", .{config.MAX_CONNECTIONS});
            self.metrics.incConnectionRefused();
            self.io.close_socket(client_socket);
            self.startAccept();
            return;
        }

        logger.info("Accepted new connection (socket={any})", .{client_socket});
        self.metrics.incConnectionAccepted();

        // 创建客户端连接（序号仅用于日志）
        const client_id = self.getNextClientId();
        const conn = ClientConnection.init(self.allocator, client_id, client_socket, self) catch |err| {
            logger.err("Failed to create client connection: {any}", .{err});
            self.io.close_socket(client_socket);
            self.metrics.incConnectionRefused();
            self.startAccept();
            return;
        };

        // 注意：不在这里注册客户端，而是在 handleConnect 中使用 MQTT Client ID 注册

        // 开始读取客户端数据
        conn.startRead(self.io);

        // 继续接受新连接
        self.startAccept();
    }

    fn getNextClientId(self: *MqttBroker) u64 {
        const id = self.next_client_id;
        self.next_client_id += 1;
        return id;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const broker = try MqttBroker.init(allocator);
    defer broker.deinit();

    try broker.start(1883);
}
