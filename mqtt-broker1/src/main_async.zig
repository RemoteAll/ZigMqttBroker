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
        // Arena会自动释放所有分配的内存
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
            // 只记录非预期的错误（排除因关闭 socket 导致的错误）
            if (err != error.Unexpected) {
                logger.err("Client {d} recv error: {any}", .{ self.id, err });
                self.broker.metrics.incNetworkError();
            }
            self.disconnect();
            return;
        };

        if (length == 0) {
            logger.info("Client {d} disconnected (EOF)", .{self.id});
            self.disconnect();
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
            self.disconnect();
            return;
        };

        // 解析并处理 MQTT 包
        self.processPackets() catch |err| {
            logger.err("Client {d} process error: {any}", .{ self.id, err });
            self.broker.metrics.incProtocolError();
            self.disconnect();
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
                self.disconnect();
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
            try connect.connack(self.writer, &self.client.stream, reason_code);
            self.broker.metrics.incMessageSent(4); // CONNACK 固定4字节(包含字节统计)
            logger.warn("Client {d} connection rejected: {any}", .{ self.id, reason_code });
            self.disconnect();
            return;
        }

        // 连接成功
        reason_code = mqtt.ReasonCode.Success;

        // 设置客户端信息
        self.client.identifer = try self.arena.allocator().dupe(u8, connect_packet.client_identifier);
        self.client.protocol_version = mqtt.ProtocolVersion.fromU8(connect_packet.protocol_version);
        self.client.keep_alive = connect_packet.keep_alive;
        self.client.clean_start = connect_packet.connect_flags.clean_session;
        self.client.is_connected = true;
        self.client.connect_time = time.milliTimestamp();
        self.client.last_activity = self.client.connect_time;

        // 发送 CONNACK
        try connect.connack(self.writer, &self.client.stream, reason_code);
        self.broker.metrics.incMessageSent(4); // CONNACK 固定4字节(包含字节统计)
        logger.info("Client {d} ({s}) connected successfully", .{ self.id, self.client.identifer });
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

        const bytes_sent = self.writer.pos;
        try self.writer.writeToStream(&subscriber.stream);

        // 记录转发指标
        self.broker.metrics.incPublishSent();
        self.broker.metrics.incMessageSent(bytes_sent);

        logger.debug("Forwarded to {s}", .{subscriber.identifer});
    }

    /// 顺序转发给多个订阅者
    fn forwardSequentially(self: *ClientConnection, subscribers: []*Client, publish_packet: anytype) !void {
        for (subscribers) |subscriber| {
            if (!subscriber.is_connected) continue;

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

            const bytes_sent = self.writer.pos;
            self.writer.writeToStream(&subscriber.stream) catch |err| {
                logger.err("Failed to forward to {s}: {any}", .{ subscriber.identifer, err });
                self.broker.metrics.incNetworkError();
                continue;
            };

            // 记录转发指标
            self.broker.metrics.incPublishSent();
            self.broker.metrics.incMessageSent(bytes_sent);

            logger.debug("Forwarded to {s}", .{subscriber.identifer});
        }
    }

    /// 断开连接
    fn disconnect(self: *ClientConnection) void {
        // 防止重复断开连接
        if (self.is_disconnecting) {
            return;
        }
        self.is_disconnecting = true;

        self.state = .Disconnecting;
        logger.info("Client {d} ({s}) disconnecting", .{ self.id, self.client.identifer });

        // 记录连接关闭
        self.broker.metrics.incConnectionClosed();

        // 关闭 socket（这会取消所有待处理的 IO 操作）
        // 注意：关闭 socket 后，不应再有新的 IO 操作回调触发
        self.broker.io.close_socket(self.socket);

        // 从 broker 移除客户端
        // 这必须在关闭 socket 后执行，以确保不会有新的引用
        _ = self.broker.clients.remove(self.id);

        // 清理资源
        // 注意：此时 self 指针将失效，不能再使用
        self.deinit(self.broker.allocator);
    }
};

/// 异步 MQTT Broker
pub const MqttBroker = struct {
    allocator: Allocator,
    io: *IO,
    clients: AutoHashMap(u64, *ClientConnection),
    next_client_id: u64,
    subscriptions: SubscriptionTree,
    server_socket: IO.socket_t,
    accept_completion: IO.Completion = undefined,

    // 新增字段: 内存池、统计定时器、指标
    client_pool: ClientConnectionPool,
    stats_completion: IO.Completion = undefined,
    metrics: Metrics,

    pub fn init(allocator: Allocator) !*MqttBroker {
        const io = try allocator.create(IO);
        io.* = try IO.init(config.IO_ENTRIES, 0);

        // 创建并预热客户端连接池
        var client_pool = ClientConnectionPool.init(allocator);
        try client_pool.preheat(config.MAX_CLIENTS_POOL);
        logger.info("Client pool preheated with {d} connections", .{config.MAX_CLIENTS_POOL});

        const self = try allocator.create(MqttBroker);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clients = AutoHashMap(u64, *ClientConnection).init(allocator),
            .next_client_id = 1,
            .subscriptions = SubscriptionTree.init(allocator),
            .server_socket = IO.INVALID_SOCKET,
            .client_pool = client_pool,
            .metrics = Metrics.init(),
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

        // 关闭服务器 socket
        if (self.server_socket != IO.INVALID_SOCKET) {
            self.io.close_socket(self.server_socket);
        }

        self.subscriptions.deinit();

        // 清理内存池
        self.client_pool.deinit();

        self.io.deinit();
        self.allocator.destroy(self.io);
        self.allocator.destroy(self);

        logger.info("MQTT broker shutdown complete", .{});
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

        // 创建客户端连接 (从内存池获取)
        const client_id = self.getNextClientId();
        const conn = ClientConnection.init(self.allocator, client_id, client_socket, self) catch |err| {
            logger.err("Failed to create client connection: {any}", .{err});
            self.io.close_socket(client_socket);
            self.metrics.incConnectionRefused();
            self.startAccept();
            return;
        };

        // 注册客户端
        self.clients.put(client_id, conn) catch |err| {
            logger.err("Failed to register client: {any}", .{err});
            conn.deinit(self.allocator);
            self.metrics.incConnectionRefused();
            self.startAccept();
            return;
        };

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
