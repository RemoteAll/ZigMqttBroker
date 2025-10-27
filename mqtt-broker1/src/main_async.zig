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

    // 发送缓冲区 - 用于异步发送
    send_buffer: []u8,
    send_len: usize = 0,
    is_sending: bool = false,

    // Arena分配器用于此连接的所有内存分配
    arena: *ArenaAllocator,

    // 防止重复断开连接
    is_disconnecting: bool = false,

    /// ⚠️ 关键：保存此连接的 Clean Session 标志
    /// 因为 Client 对象可能被多个连接共享，不能依赖 client.clean_start
    /// 每个连接在断开时必须根据自己的 clean_session 标志来决定是否清理订阅
    connection_clean_session: bool = false,

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
        const send_buffer = try arena_allocator.alloc(u8, config.WRITE_BUFFER_SIZE);

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
            .send_buffer = send_buffer,
            .send_len = 0,
            .is_sending = false,
            .arena = arena,
            .is_disconnecting = false,
            .connection_clean_session = false, // 初始化为 false，在 CONNECT 时设置
        };

        return self;
    }

    pub fn deinit(self: *ClientConnection, base_allocator: Allocator) void {
        // ⚠️ 注意：此时 self.client 可能处于任何状态（ref_count 可能为 0 或 >0）
        // 不要过度依赖 self.client 的内容，因为它是 Arena 分配的

        // 尝试安全地获取引用计数（如果失败就跳过日志）
        const ref_count = self.client.getRefCount();

        if (ref_count > 0) {
            // 警告：仍有其他引用（订阅树等）持有该 Client 指针
            // 但由于使用 Arena 分配，Arena.deinit() 会释放所有内存
            // 这会导致订阅树中的指针变成悬垂指针

            // ⚠️ 注意：identifer 可能已经无效，尝试读取可能导致崩溃
            // 只记录 ID 和引用计数，不访问字符串字段
            logger.warn(
                "Client #{} still has {} reference(s) when deinit, potential dangling pointers!",
                .{ self.client.id, ref_count },
            );
        } else {
            logger.debug("Client #{} can be safely freed (ref_count=0)", .{self.client.id});
        }

        // ⚠️ 关键：先保存 arena 指针，因为 self 本身也在 arena 中！
        // arena.deinit() 会释放 self，之后不能再访问 self.arena
        const arena = self.arena;

        // 注意：Client 对象由 Arena 分配，不需要手动调用 Client.deinit()
        // 只需要确保 stream 已关闭（应该在 disconnect 中已经关闭）
        // Arena.deinit() 会自动释放所有分配的内存（包括 self 和 Client 对象）
        arena.deinit();
        base_allocator.destroy(arena);
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
            const is_windows = @import("builtin").os.tag == .windows;

            // 使用 comptime 检查错误类型以支持跨平台编译
            const is_operation_cancelled = if (is_windows)
                err == error.OperationCancelled
            else
                false;

            if (is_operation_cancelled) {
                // Windows 特有: CancelIoEx 取消的操作 - 这是我们主动调用的，完全正常
                logger.debug("Client {d} recv operation cancelled (normal disconnect)", .{self.id});
            } else switch (err) {
                error.SocketNotConnected => {
                    // Socket 已关闭或未连接 - 断开流程中的正常情况
                    logger.debug("Client {d} recv error (socket not connected)", .{self.id});
                },
                error.Unexpected => {
                    // Windows/Linux: socket 关闭导致的其他错误
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
            const need_cleanup = self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after recv error: {any}", .{disconnect_err});
                return;
            };
            if (need_cleanup) {
                self.deinit(self.broker.allocator);
            }
            return;
        };

        if (length == 0) {
            logger.info("Client {d} disconnected (EOF)", .{self.id});
            const need_cleanup = self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after EOF: {any}", .{disconnect_err});
                return;
            };
            if (need_cleanup) {
                self.deinit(self.broker.allocator);
            }
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
            const need_cleanup = self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after reader error: {any}", .{disconnect_err});
                return;
            };
            if (need_cleanup) {
                self.deinit(self.broker.allocator);
            }
            return;
        };

        // 解析并处理 MQTT 包
        const self_destroyed = self.processPackets() catch |err| {
            logger.err("Client {d} process error: {any}", .{ self.id, err });
            self.broker.metrics.incProtocolError();
            const need_cleanup = self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after process error: {any}", .{disconnect_err});
                return;
            };
            if (need_cleanup) {
                self.deinit(self.broker.allocator);
            }
            return;
        };

        // 如果 self 已被清理（处理了 DISCONNECT），不要再访问 self
        if (self_destroyed) {
            return;
        }

        // 继续读取下一批数据
        self.startRead(self.broker.io);
    }

    /// 异步发送数据 - 核心方法
    /// 将 writer 中的数据复制到 send_buffer 并提交异步发送请求
    pub fn sendAsync(self: *ClientConnection) !void {
        if (self.is_disconnecting) {
            logger.debug("Client {} send skipped (disconnecting)", .{self.id});
            return;
        }

        if (self.is_sending) {
            logger.warn("Client {} send skipped (already sending)", .{self.id});
            return error.SendInProgress;
        }

        const data_len = self.writer.getWrittenLength();
        if (data_len == 0) {
            logger.warn("Client {} send skipped (no data)", .{self.id});
            return;
        }

        if (data_len > self.send_buffer.len) {
            logger.err("Client {} send buffer overflow: {} > {}", .{ self.id, data_len, self.send_buffer.len });
            return error.SendBufferOverflow;
        }

        // 复制数据到发送缓冲区
        @memcpy(self.send_buffer[0..data_len], self.writer.buffer[0..data_len]);
        self.send_len = data_len;
        self.is_sending = true;

        // 提交异步发送请求
        self.state = .Writing;
        self.broker.io.send(
            *ClientConnection,
            self,
            onSendComplete,
            &self.send_completion,
            self.socket,
            self.send_buffer[0..data_len],
        );
    }

    /// send 完成回调
    fn onSendComplete(
        self: *ClientConnection,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        _ = completion;

        self.is_sending = false;

        if (self.is_disconnecting) {
            logger.debug("Client {} send callback ignored (disconnecting)", .{self.id});
            return;
        }

        const sent = result catch |err| {
            logger.err("Client {} send failed: {any}", .{ self.id, err });
            self.broker.metrics.incNetworkError();
            const need_cleanup = self.disconnect() catch |disconnect_err| {
                std.log.err("Failed to disconnect client after send error: {any}", .{disconnect_err});
                return;
            };
            if (need_cleanup) {
                self.deinit(self.broker.allocator);
            }
            return;
        };

        if (sent != self.send_len) {
            logger.err("Client {} partial send: {}/{} bytes", .{ self.id, sent, self.send_len });
            // TODO: 处理部分发送的情况
            self.broker.metrics.incNetworkError();
            return;
        }

        logger.debug("Client {} sent {} bytes successfully", .{ self.id, sent });
        self.broker.metrics.incMessageSent(sent);

        // 清空 writer 准备下次使用
        self.writer.reset();

        // 继续处理(如果有待处理的数据)
        if (self.state == .Writing) {
            self.state = .Reading;
        }
    }

    /// 处理接收到的 MQTT 包
    /// 返回值：true = self 已被清理（不要再访问），false = self 仍然有效
    fn processPackets(self: *ClientConnection) !bool {
        self.state = .Processing;

        while (self.reader.pos < self.reader.length) {
            const start_pos = self.reader.pos;

            const cmd = self.reader.readCommand() catch |err| {
                logger.warn("Client {d} unknown command: {any}", .{ self.id, err });
                break;
            };

            if (cmd == .DISCONNECT) {
                logger.info("Client {d} sent DISCONNECT", .{self.id});
                const need_cleanup = self.disconnect() catch |disconnect_err| {
                    std.log.err("Failed to disconnect client after DISCONNECT packet: {any}", .{disconnect_err});
                    return false; // 断开失败，self 仍然有效
                };
                if (need_cleanup) {
                    self.deinit(self.broker.allocator);
                }
                return true; // self 已被清理
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
                .CONNECT => {
                    self.handleConnect() catch |err| {
                        if (err == error.ConnectionRejected) {
                            // 连接被拒绝，需要断开并清理
                            const need_cleanup = self.disconnect() catch true;
                            if (need_cleanup) {
                                self.deinit(self.broker.allocator);
                            }
                            return true; // self 已被清理
                        }
                        return err; // 其他错误传播
                    };
                },
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

        // 正常处理完所有包，self 仍然有效
        return false;
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

            // 发送 CONNACK 拒绝(使用异步版本)
            self.writer.reset();
            try connect.connackAsync(self.writer, false, reason_code);
            try self.sendAsync();
            logger.warn("Client {d} connection rejected: {any}", .{ self.id, reason_code });

            // 抛出错误让调用者处理断开（不在这里 deinit）
            return error.ConnectionRejected;
        }

        // 连接成功
        reason_code = mqtt.ReasonCode.Success;

        // 设置客户端信息
        self.client.identifer = try self.arena.allocator().dupe(u8, connect_packet.client_identifier);
        self.client.protocol_version = mqtt.ProtocolVersion.fromU8(connect_packet.protocol_version);
        self.client.keep_alive = connect_packet.keep_alive;
        self.client.clean_start = connect_packet.connect_flags.clean_session;

        // ⚠️ 关键：保存此连接的 Clean Session 标志（不依赖共享的 Client 对象）
        self.connection_clean_session = connect_packet.connect_flags.clean_session;

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

        // 标记是否需要从持久化恢复订阅
        // 只有在以下情况才需要恢复：没有活跃旧连接（新连接）但有持久化订阅
        var needs_restore_from_persistence = false;

        if (self.broker.clients.get(mqtt_client_id)) |old_conn| {
            logger.info("Client {s} is reconnecting (old_conn #{d}), handling session...", .{ mqtt_client_id, old_conn.id });

            // 根据 Clean Session 标志决定如何处理旧会话
            if (connect_packet.connect_flags.clean_session) {
                // Clean Session = 1: 清除旧会话的所有订阅（包括持久化）
                logger.info("Clean Session = 1, clearing old subscriptions for {s}", .{mqtt_client_id});
                self.broker.subscriptions.unsubscribeAll(old_conn.client);
            } else {
                // Clean Session = 0: 复用旧连接的 Client 对象,保留订阅指针有效
                logger.info("Clean Session = 0, reusing old Client object for {s}", .{mqtt_client_id});

                // ⚠️ 关键修复：复用旧的 Client 对象,避免订阅树中的指针失效
                // 旧的 client 指针已经在订阅树中被引用,必须保持其有效性
                self.client = old_conn.client;
                self.client.is_connected = true; // 恢复连接状态

                // 重要：复用旧 Client 时，订阅已经在内存中，不需要从持久化恢复
                needs_restore_from_persistence = false;
            }

            // 关闭旧连接的 socket 和网络资源
            self.broker.io.close_socket(old_conn.socket);
            // 注意：Clean Session = 0 时不释放 old_conn.client，因为我们复用了它
        } else {
            // 没有活跃的旧连接
            if (!connect_packet.connect_flags.clean_session and has_persisted_subscriptions) {
                // Clean Session = 0 且有持久化订阅，需要恢复
                needs_restore_from_persistence = true;
                logger.info("Client {s} is new connection with persisted subscriptions, will restore", .{mqtt_client_id});
            }
        }

        // 将新连接注册到 broker（重连时会替换旧连接）
        try self.broker.clients.put(mqtt_client_id, self);

        // 确定会话状态
        // [MQTT-3.2.2-1] 如果 Clean Session = 1, Session Present 必须为 0
        // [MQTT-3.2.2-2] 如果 Clean Session = 0, Session Present 取决于是否有保存的会话
        const session_present = if (connect_packet.connect_flags.clean_session)
            false // Clean Session = 1 时必须返回 false
        else
            (has_existing_session or has_persisted_subscriptions); // Clean Session = 0 时,如果有旧会话或持久化订阅则返回 true

        // 发送 CONNACK (使用异步版本)
        self.writer.reset();
        try connect.connackAsync(self.writer, session_present, reason_code);
        try self.sendAsync();

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

        // 只有在明确需要从持久化恢复时才调用 restoreClientSubscriptions
        // 避免重复恢复（复用旧 Client 对象时订阅已经在内存中）
        if (needs_restore_from_persistence) {
            logger.info("Restoring subscriptions from persistence for client {s}", .{self.client.identifer});
            self.broker.subscriptions.restoreClientSubscriptions(self.client) catch |err| {
                logger.err("Failed to restore subscriptions for client {s}: {any}", .{ self.client.identifer, err });
            };
        } else if (has_existing_session and !connect_packet.connect_flags.clean_session) {
            logger.info("Client {s} reused old Client object, subscriptions already in memory", .{self.client.identifer});
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

        // 发送 SUBACK (使用异步版本)
        self.writer.reset();
        try subscribe.subackAsync(self.writer, subscribe_packet.packet_id, self.client);
        try self.sendAsync();
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

        // 根据 QoS 发送确认 (使用异步版本)
        switch (publish_packet.qos) {
            .AtMostOnce => {},
            .AtLeastOnce => {
                if (publish_packet.packet_id) |pid| {
                    try publish.sendPubackAsync(self.writer, pid);
                    try self.sendAsync();
                }
            },
            .ExactlyOnce => {
                if (publish_packet.packet_id) |pid| {
                    try publish.sendPubrecAsync(self.writer, pid);
                    try self.sendAsync();
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

            // 智能转发策略：根据订阅者数量选择最优方法
            // 1 个订阅者：直接发送（无需序列化共享）
            // 2-9 个订阅者：顺序转发（共享序列化，循环简单）
            // config.BATCH_FORWARD_THRESHOLD+ 个订阅者：批量转发（共享序列化 + 批量 I/O）
            if (matched_clients.items.len == 1) {
                try self.forwardToSingle(matched_clients.items[0], publish_packet);
            } else if (matched_clients.items.len < config.BATCH_FORWARD_THRESHOLD) {
                try self.forwardSequentially(matched_clients.items, publish_packet);
            } else {
                try self.forwardBatched(matched_clients.items, publish_packet);
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

        // 发送 UNSUBACK (使用异步版本)
        self.writer.reset();
        try unsubscribe.unsubackAsync(self.writer, unsubscribe_packet.packet_id);
        try self.sendAsync();
    }

    fn handlePingreq(self: *ClientConnection) !void {
        logger.info("📡 Received PINGREQ from client {} ({s})", .{ self.id, self.client.identifer });
        self.writer.reset();
        try self.writer.writeByte(0xD0); // PINGRESP 包类型
        try self.writer.writeByte(0); // Remaining length = 0

        // 使用异步发送
        self.sendAsync() catch |err| {
            std.log.err("❌ CRITICAL: Failed to send PINGRESP: {any}", .{err});
            std.log.err("   Client {} will timeout and reconnect!", .{self.id});
            return error.SendAsyncFailed;
        };
        logger.info("✅ PINGRESP queued for async send to client {}", .{self.id});
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
        try self.sendAsync();

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
        try self.sendAsync();

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

    /// 转发给单个订阅者 - 异步版本
    fn forwardToSingle(self: *ClientConnection, subscriber: *Client, publish_packet: anytype) !void {
        if (!subscriber.is_connected) return;

        // 使用 MQTT Client ID 从 broker 的客户端映射中查找
        const subscriber_conn = self.broker.clients.get(subscriber.identifer) orelse {
            logger.warn("Subscriber {s} not found in broker clients map", .{subscriber.identifer});
            return;
        };

        // 检查订阅者是否正在发送(避免覆盖发送缓冲区)
        if (subscriber_conn.is_sending) {
            logger.warn("Subscriber {s} is busy sending, message dropped", .{subscriber.identifer});
            self.broker.metrics.incMessageDropped();
            return;
        }

        // 使用订阅者自己的 writer 来构建消息
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

        // 异步发送
        subscriber_conn.sendAsync() catch |err| {
            logger.err("Failed to forward to {s}: {any}", .{ subscriber.identifer, err });
            self.broker.metrics.incNetworkError();
            return;
        };

        // 记录转发指标
        self.broker.metrics.incPublishSent();
        logger.debug("Forwarded to {s} (async)", .{subscriber.identifer});
    }

    /// 顺序转发给多个订阅者 - 异步版本(共享序列化结果)
    fn forwardSequentially(self: *ClientConnection, subscribers: []*Client, publish_packet: anytype) !void {
        // 性能优化：先构建一次 PUBLISH 包，然后共享给所有订阅者
        // 避免重复序列化,节省 CPU 和内存

        // 1. 使用临时 arena 分配器构建一次 PUBLISH 包
        var temp_writer = try packet.Writer.init(self.arena.allocator());
        try publish.writePublish(
            temp_writer,
            publish_packet.topic,
            publish_packet.payload,
            .AtMostOnce,
            publish_packet.retain,
            false,
            null,
        );

        // 2. 获取序列化后的字节切片（共享给所有订阅者）
        const serialized_message = temp_writer.buffer[0..temp_writer.pos];
        const message_size = serialized_message.len;

        // 3. 异步发送给所有订阅者
        var sent_count: usize = 0;
        var dropped_count: usize = 0;
        var error_count: usize = 0;

        for (subscribers) |subscriber| {
            if (!subscriber.is_connected) continue;

            // 使用 MQTT Client ID 从 broker 的客户端映射中查找
            const subscriber_conn = self.broker.clients.get(subscriber.identifer) orelse {
                logger.warn("Subscriber {s} not found in broker clients map", .{subscriber.identifer});
                error_count += 1;
                continue;
            };

            // 检查是否正在发送(避免覆盖发送缓冲区)
            if (subscriber_conn.is_sending) {
                logger.debug("Subscriber {s} busy, message dropped", .{subscriber.identifer});
                dropped_count += 1;
                self.broker.metrics.incMessageDropped();
                continue;
            }

            // 检查缓冲区大小
            if (message_size > subscriber_conn.send_buffer.len) {
                logger.err("Message too large for {s}: {} > {}", .{ subscriber.identifer, message_size, subscriber_conn.send_buffer.len });
                error_count += 1;
                continue;
            }

            // 直接复制预序列化的消息到订阅者的发送缓冲区
            @memcpy(subscriber_conn.send_buffer[0..message_size], serialized_message);
            subscriber_conn.send_len = message_size;
            subscriber_conn.is_sending = true;

            // 提交异步发送请求
            subscriber_conn.state = .Writing;
            self.broker.io.send(
                *ClientConnection,
                subscriber_conn,
                ClientConnection.onSendComplete,
                &subscriber_conn.send_completion,
                subscriber_conn.socket,
                subscriber_conn.send_buffer[0..message_size],
            );

            // 记录转发指标
            self.broker.metrics.incPublishSent();
            sent_count += 1;
        }

        // 批量日志记录（避免过多日志调用）
        if (sent_count > 10) {
            logger.info("Forwarded to {d} subscribers ({d} dropped, {d} errors)", .{ sent_count, dropped_count, error_count });
        } else if (sent_count > 0) {
            logger.debug("Forwarded to {d} subscribers", .{sent_count});
        }
    }

    /// 批量异步转发 - 高性能版本
    /// 充分利用 io_uring 的批量提交能力
    /// 适用场景：大量订阅者（config.BATCH_FORWARD_THRESHOLD+）
    fn forwardBatched(self: *ClientConnection, subscribers: []*Client, publish_packet: anytype) !void {
        // 1. 序列化一次 PUBLISH 包（共享序列化结果）
        var temp_writer = try packet.Writer.init(self.arena.allocator());
        try publish.writePublish(
            temp_writer,
            publish_packet.topic,
            publish_packet.payload,
            .AtMostOnce,
            publish_packet.retain,
            false,
            null,
        );

        const serialized_message = temp_writer.buffer[0..temp_writer.pos];
        const message_size = serialized_message.len;

        var total_sent: usize = 0;
        var total_dropped: usize = 0;
        var total_errors: usize = 0;

        // 2. 批量异步发送给所有订阅者
        // io_uring 会自动批量提交,充分利用 SQ (Submission Queue) 的批处理能力
        for (subscribers) |subscriber| {
            if (!subscriber.is_connected) continue;

            // 查找订阅者连接
            const subscriber_conn = self.broker.clients.get(subscriber.identifer) orelse {
                logger.warn("Subscriber {s} not found in broker clients map", .{subscriber.identifer});
                total_errors += 1;
                continue;
            };

            // 检查是否正在发送
            if (subscriber_conn.is_sending) {
                logger.debug("Subscriber {s} busy, message dropped", .{subscriber.identifer});
                total_dropped += 1;
                self.broker.metrics.incMessageDropped();
                continue;
            }

            // 检查缓冲区大小
            if (message_size > subscriber_conn.send_buffer.len) {
                logger.err("Message too large for {s}: {} > {}", .{ subscriber.identifer, message_size, subscriber_conn.send_buffer.len });
                total_errors += 1;
                continue;
            }

            // 复制消息到订阅者的发送缓冲区
            @memcpy(subscriber_conn.send_buffer[0..message_size], serialized_message);
            subscriber_conn.send_len = message_size;
            subscriber_conn.is_sending = true;

            // 提交异步发送请求
            // io_uring 会将多个请求批量提交到内核,减少系统调用开销
            subscriber_conn.state = .Writing;
            self.broker.io.send(
                *ClientConnection,
                subscriber_conn,
                ClientConnection.onSendComplete,
                &subscriber_conn.send_completion,
                subscriber_conn.socket,
                subscriber_conn.send_buffer[0..message_size],
            );

            // 记录指标
            self.broker.metrics.incPublishSent();
            total_sent += 1;
        }

        // 3. 批量日志记录
        logger.info("Batched async forward to {d} subscribers ({d} dropped, {d} errors)", .{ total_sent, total_dropped, total_errors });
    }

    /// 断开连接
    /// 返回值：true = 需要调用 deinit() 清理，false = 不需要（已转移到 orphan_clients 或重复调用）
    fn disconnect(self: *ClientConnection) !bool {
        // 防止重复断开连接
        if (self.is_disconnecting) {
            return false; // 重复调用，不需要清理
        }
        self.is_disconnecting = true;

        self.state = .Disconnecting;
        logger.info("Client {d} ({s}) disconnecting (connection_clean_session={})", .{ self.id, self.client.identifer, self.connection_clean_session });

        // 记录连接关闭
        self.broker.metrics.incConnectionClosed();

        // 标记客户端为已断开(但不立即释放)
        self.client.is_connected = false;

        // 记录断开时间（用于会话过期判断）
        self.client.disconnect_time = std.time.milliTimestamp();

        // ⚠️ 关键修复：根据此连接的 clean_session 标志决定是否清理订阅
        // 不能依赖 self.client.clean_start，因为 Client 对象可能被多个连接共享
        // [MQTT-3.1.2-6] Clean Session = 1: 断开时必须删除会话状态
        // [MQTT-3.1.2-5] Clean Session = 0: 断开时保留会话状态
        if (self.connection_clean_session) {
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
                // 无法转移，只能泄漏 - 返回 true 让调用者清理 ClientConnection
                return true;
            };

            // ⚠️ 复制基本字段（标量类型）
            orphan_client.id = self.client.id;
            orphan_client.protocol_version = self.client.protocol_version;
            // ⚠️ stream 已经关闭，设置为无效 handle 防止误用
            orphan_client.stream = net.Stream{ .handle = IO.INVALID_SOCKET };
            orphan_client.address = self.client.address; // 地址可以安全复制
            orphan_client.is_connected = false; // ✅ 强制设为 false（已断开）
            orphan_client.connect_time = self.client.connect_time;
            orphan_client.last_activity = self.client.last_activity;
            orphan_client.disconnect_time = self.client.disconnect_time;
            orphan_client.clean_start = self.client.clean_start;
            orphan_client.session_expiry_interval = self.client.session_expiry_interval;
            orphan_client.keep_alive = self.client.keep_alive;
            orphan_client.will_qos = self.client.will_qos;
            orphan_client.will_retain = self.client.will_retain;
            orphan_client.will_delay_interval = self.client.will_delay_interval;
            orphan_client.receive_maximum = self.client.receive_maximum;
            orphan_client.maximum_packet_size = self.client.maximum_packet_size;
            orphan_client.topic_alias_maximum = self.client.topic_alias_maximum;
            orphan_client.packet_id_counter = self.client.packet_id_counter;

            // ⚠️ 深拷贝 identifer（关键：避免悬垂指针）
            const identifer_copy = try self.broker.allocator.dupe(u8, self.client.identifer);
            orphan_client.identifer = identifer_copy;

            // ⚠️ 设置正确的 allocator（全局 allocator，不是 Arena）
            orphan_client.allocator = self.broker.allocator;

            // ⚠️ 深拷贝可选字符串字段
            orphan_client.username = if (self.client.username) |u|
                self.broker.allocator.dupe(u8, u) catch null
            else
                null;
            orphan_client.password = if (self.client.password) |p|
                self.broker.allocator.dupe(u8, p) catch null
            else
                null;
            orphan_client.will_topic = if (self.client.will_topic) |t|
                self.broker.allocator.dupe(u8, t) catch null
            else
                null;
            orphan_client.will_payload = if (self.client.will_payload) |p|
                self.broker.allocator.dupe(u8, p) catch null
            else
                null;

            // ✅ 关键修复：重新初始化所有容器（使用空字面量）
            // 不能浅拷贝，因为原容器内部指针指向 Arena 内存
            // Zig 0.15.2: ArrayList 不再存储 allocator，deinit 时需要传入
            orphan_client.subscriptions = .{};
            orphan_client.incoming_queue = .{};
            orphan_client.outgoing_queue = .{};
            orphan_client.user_properties = std.StringHashMap([]const u8).init(self.broker.allocator);
            orphan_client.inflight_messages = std.AutoHashMap(u16, Client.Message).init(self.broker.allocator);

            // TODO: 如果需要保留订阅内容，需要深拷贝 subscriptions 列表
            // 当前为了简化，订阅信息保留在订阅树中，这里容器为空

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
            // 注意：使用相同的 identifer_copy 作为 HashMap 的 key
            self.broker.orphan_clients.put(
                identifer_copy,
                orphan_client,
            ) catch |err| {
                logger.err("Failed to add orphan client to broker: {any}", .{err});
                self.broker.allocator.free(identifer_copy);
                self.broker.allocator.destroy(orphan_client);
                return false; // 失败也不需要清理（泄漏了）
            };

            logger.info("Client {s} successfully transferred to orphan_clients", .{self.client.identifer});

            // 现在可以安全释放 ClientConnection 和它的 Arena
            // orphan_client 已经独立管理
            // ✅ 返回 true 表示调用者需要调用 deinit()
            return true;
        } else {
            // ref_count <= 1: 只有 ClientConnection 持有引用，可以安全释放
            logger.debug("Client {s} (#{}) can be safely freed (ref_count={})", .{ self.client.identifer, self.client.id, ref_count });

            // 释放 ClientConnection 自己持有的引用
            // 这样后续 deinit() 中检查 ref_count 时就是 0 了
            _ = self.client.release();

            // ✅ 返回 true 表示调用者需要调用 deinit()
            return true;
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

        // 创建客户端连接池（支持动态扩展）
        var client_pool = ClientConnectionPool.init(allocator);

        // 只预热初始大小的连接池（通常 1K-5K）
        // 这样前期内存占用很小，不会浪费
        try client_pool.preheat(config.INITIAL_POOL_SIZE);
        logger.info(
            "Client pool initialized: initial_size={d}, max_size={d}",
            .{ config.INITIAL_POOL_SIZE, config.MAX_POOL_SIZE },
        );

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
            const client_id = entry.key_ptr.*;
            const client = entry.value_ptr.*;
            const ref_count = client.getRefCount();
            logger.info("Cleaning up orphan client {s} (ref_count={})", .{ client.identifer, ref_count });

            // 强制清理订阅释放引用
            self.subscriptions.unsubscribeAll(client);

            // 现在应该可以安全释放了
            client.deinit();

            // 释放 HashMap 持有的 key 与 Client 实例
            // 注意：StringHashMap 不会替我们释放 key 内存
            self.allocator.free(client_id);
            self.allocator.destroy(client);
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

        // 进入事件循环（阻塞模式，避免CPU忙等待）
        // 使用 run_for_ns 而非 run，确保在没有事件时阻塞等待而非轮询
        logger.info("Entering event loop...", .{});
        while (true) {
            // 阻塞等待最多30秒（或直到有事件/超时发生）
            // iobeetle 会根据已注册的定时器（如心跳、统计）自动计算实际等待时间
            // 实际等待时间 = min(30秒, 下一个定时器到期时间)
            // 这样可以避免无谓的频繁唤醒，同时保证定时器准时触发
            // 注意：任何网络事件（连接、数据到达等）都会立即中断等待
            self.io.run_for_ns(30 * std.time.ns_per_s) catch |err| {
                // IO 错误通常是由于已关闭的 socket 触发的，这是正常的断开流程
                // 记录错误但继续运行，保持服务器可用
                logger.debug("IO error (likely closed socket or transient issue): {any}", .{err});
                // 继续运行而不是退出，让服务器保持可用
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

        // 自动扩展连接池（如果需要）
        // 当实际连接接近预热大小时，提前扩展以避免分配延迟
        self.autoExpandPoolIfNeeded();

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

    /// 自动扩展连接池
    /// 当活跃连接接近预热大小时，提前扩展以避免新连接分配延迟
    fn autoExpandPoolIfNeeded(self: *MqttBroker) void {
        const current_connections = self.clients.count();
        const expansion_threshold = (config.INITIAL_POOL_SIZE * 80) / 100; // 预热大小的 80%

        // 检查是否需要扩展
        if (current_connections >= expansion_threshold) {
            // 计算新的预热大小：当前大小的 1.5 倍，但不超过 MAX_POOL_SIZE
            const next_size = @min(
                (config.INITIAL_POOL_SIZE * 3) / 2,
                config.MAX_POOL_SIZE,
            );

            // 只在还有扩展空间且池大小有增长时才扩展
            if (next_size > config.INITIAL_POOL_SIZE) {
                const expand_count = next_size - config.INITIAL_POOL_SIZE;
                self.client_pool.preheat(expand_count) catch |err| {
                    logger.warn(
                        "Failed to auto-expand pool: {any} (current: {d}, target: {d})",
                        .{ err, config.INITIAL_POOL_SIZE, next_size },
                    );
                    return;
                };
                logger.info(
                    "Auto-expanded pool: +{d} connections (total preheated: {d})",
                    .{ expand_count, next_size },
                );
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 设置日志级别（根据配置）
    logger.setLevel(switch (config.DEFAULT_LOG_LEVEL) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    });

    const broker = try MqttBroker.init(allocator);
    defer broker.deinit();

    try broker.start(1883);
}
