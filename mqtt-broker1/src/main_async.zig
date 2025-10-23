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

// 导入 iobeetle IO 模块
const IO = @import("iobeetle/io.zig").IO;

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

    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        id: u64,
        socket: IO.socket_t,
        broker: *MqttBroker,
    ) !*ClientConnection {
        const self = try allocator.create(ClientConnection);
        errdefer allocator.destroy(self);

        // 创建 Client 实例(临时使用空地址和流)
        const dummy_address = try net.Address.parseIp("0.0.0.0", 0);
        const dummy_stream = net.Stream{ .handle = socket };
        const client = try Client.init(allocator, id, mqtt.ProtocolVersion.Invalid, dummy_stream, dummy_address);
        errdefer client.deinit();

        const read_buffer = try allocator.alloc(u8, config.READ_BUFFER_SIZE);
        errdefer allocator.free(read_buffer);

        const writer = try packet.Writer.init(allocator);
        errdefer writer.deinit();

        self.* = .{
            .id = id,
            .socket = socket,
            .state = .Accepting,
            .client = client,
            .broker = broker,
            .read_buffer = read_buffer,
            .reader = packet.Reader.init(read_buffer),
            .writer = writer,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *ClientConnection) void {
        self.client.deinit();
        self.allocator.free(self.read_buffer);
        self.writer.deinit();
        self.allocator.destroy(self);
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

        const length = result catch |err| {
            logger.err("Client {d} recv error: {any}", .{ self.id, err });
            self.disconnect();
            return;
        };

        if (length == 0) {
            logger.info("Client {d} disconnected (EOF)", .{self.id});
            self.disconnect();
            return;
        }

        logger.debug("Client {d} received {d} bytes", .{ self.id, length });

        // 更新客户端活动时间
        self.client.updateActivity();

        // 处理接收到的数据
        self.reader.start(length) catch |err| {
            logger.err("Client {d} reader.start error: {any}", .{ self.id, err });
            self.disconnect();
            return;
        };

        // 解析并处理 MQTT 包
        self.processPackets() catch |err| {
            logger.err("Client {d} process error: {any}", .{ self.id, err });
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
            logger.debug("Client {d} packet type={any} payload={d} bytes", .{ self.id, cmd, remaining_length });

            switch (cmd) {
                .CONNECT => try self.handleConnect(),
                .SUBSCRIBE => try self.handleSubscribe(),
                .PUBLISH => try self.handlePublish(),
                .UNSUBSCRIBE => try self.handleUnsubscribe(),
                .PINGREQ => try self.handlePingreq(),
                else => {
                    logger.warn("Client {d} unhandled packet type: {any}", .{ self.id, cmd });
                },
            }
        }
    }

    fn handleConnect(self: *ClientConnection) !void {
        var reason_code = mqtt.ReasonCode.MalformedPacket;

        const connect_packet = connect.read(&self.reader, self.allocator) catch |err| {
            logger.err("Client {d} CONNECT parse error: {any}", .{ self.id, err });
            return;
        };

        const errors = connect_packet.getErrors();
        if (errors.len > 0) {
            logger.warn("Client {d} CONNECT has {d} errors", .{ self.id, errors.len });

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
            logger.warn("Client {d} connection rejected: {any}", .{ self.id, reason_code });
            self.disconnect();
            return;
        }

        // 连接成功
        reason_code = mqtt.ReasonCode.Success;

        // 设置客户端信息
        self.client.identifer = try self.allocator.dupe(u8, connect_packet.client_identifier);
        self.client.protocol_version = mqtt.ProtocolVersion.fromU8(connect_packet.protocol_version);
        self.client.keep_alive = connect_packet.keep_alive;
        self.client.clean_start = connect_packet.connect_flags.clean_session;
        self.client.is_connected = true;
        self.client.connect_time = time.milliTimestamp();
        self.client.last_activity = self.client.connect_time;

        // 发送 CONNACK
        try connect.connack(self.writer, &self.client.stream, reason_code);
        logger.info("Client {d} ({s}) connected successfully", .{ self.id, self.client.identifer });
    }

    fn handleSubscribe(self: *ClientConnection) !void {
        const subscribe_packet = try subscribe.read(&self.reader, self.client, self.allocator);

        logger.debug("Client {d} SUBSCRIBE {d} topics", .{ self.id, subscribe_packet.topics.items.len });

        for (subscribe_packet.topics.items) |topic| {
            try self.broker.subscriptions.subscribe(topic.filter, self.client);
            logger.info("Client {d} ({s}) subscribed to: {s}", .{ self.id, self.client.identifer, topic.filter });
        }

        try subscribe.suback(self.writer, &self.client.stream, subscribe_packet.packet_id, self.client);
    }

    fn handlePublish(self: *ClientConnection) !void {
        const publish_packet = try publish.read(&self.reader);

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
                }
            },
            .ExactlyOnce => {
                if (publish_packet.packet_id) |pid| {
                    try publish.sendPubrec(self.writer, self.client, pid);
                }
            },
        }

        // 转发给订阅者
        var matched_clients = try self.broker.subscriptions.match(
            publish_packet.topic,
            self.client.identifer,
            &self.allocator,
        );
        defer matched_clients.deinit(self.allocator);

        if (matched_clients.items.len > 0) {
            logger.debug("Forwarding to {d} subscribers", .{matched_clients.items.len});

            // 使用智能转发策略
            if (matched_clients.items.len == 1) {
                try self.forwardToSingle(matched_clients.items[0], publish_packet);
            } else {
                try self.forwardSequentially(matched_clients.items, publish_packet);
            }
        }
    }

    fn handleUnsubscribe(self: *ClientConnection) !void {
        const unsubscribe_packet = try unsubscribe.read(&self.reader, self.allocator);

        for (unsubscribe_packet.topics.items) |topic_filter| {
            _ = try self.broker.subscriptions.unsubscribe(topic_filter, self.client);
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

        try self.writer.writeToStream(&subscriber.stream);
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

            self.writer.writeToStream(&subscriber.stream) catch |err| {
                logger.err("Failed to forward to {s}: {any}", .{ subscriber.identifer, err });
                continue;
            };

            logger.debug("Forwarded to {s}", .{subscriber.identifer});
        }
    }

    /// 断开连接
    fn disconnect(self: *ClientConnection) void {
        self.state = .Disconnecting;
        logger.info("Client {d} ({s}) disconnecting", .{ self.id, self.client.identifer });

        // 从 broker 移除客户端
        _ = self.broker.clients.remove(self.id);

        // 关闭 socket
        self.broker.io.close_socket(self.socket);

        // 清理资源
        self.deinit();
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

    pub fn init(allocator: Allocator) !*MqttBroker {
        const io = try allocator.create(IO);
        io.* = try IO.init(256, 0); // 256 个并发 IO 操作

        const self = try allocator.create(MqttBroker);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clients = AutoHashMap(u64, *ClientConnection).init(allocator),
            .next_client_id = 1,
            .subscriptions = SubscriptionTree.init(allocator),
            .server_socket = IO.INVALID_SOCKET,
        };

        return self;
    }

    pub fn deinit(self: *MqttBroker) void {
        // 清理所有客户端连接
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const conn = entry.value_ptr.*;
            self.io.close_socket(conn.socket);
            conn.deinit();
        }
        self.clients.deinit();

        // 关闭服务器 socket
        if (self.server_socket != IO.INVALID_SOCKET) {
            self.io.close_socket(self.server_socket);
        }

        self.subscriptions.deinit();
        self.io.deinit();
        self.allocator.destroy(self.io);
        self.allocator.destroy(self);
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

        // 进入事件循环
        logger.info("Entering event loop...", .{});
        while (true) {
            self.io.run() catch |err| {
                logger.err("IO error: {any}", .{err});
                break;
            };
        }
    }

    /// 开始异步接受连接
    fn startAccept(self: *MqttBroker) void {
        self.io.accept(
            *MqttBroker,
            self,
            onAcceptComplete,
            &self.accept_completion,
            self.server_socket,
        );
    }

    /// accept 完成回调
    fn onAcceptComplete(
        self: *MqttBroker,
        completion: *IO.Completion,
        result: IO.AcceptError!IO.socket_t,
    ) void {
        _ = completion;

        const client_socket = result catch |err| {
            logger.err("Accept error: {any}", .{err});
            // 继续接受新连接
            self.startAccept();
            return;
        };

        logger.info("Accepted new connection (socket={any})", .{client_socket});

        // 创建客户端连接
        const client_id = self.getNextClientId();
        const conn = ClientConnection.init(self.allocator, client_id, client_socket, self) catch |err| {
            logger.err("Failed to create client connection: {any}", .{err});
            self.io.close_socket(client_socket);
            self.startAccept();
            return;
        };

        // 注册客户端
        self.clients.put(client_id, conn) catch |err| {
            logger.err("Failed to register client: {any}", .{err});
            conn.deinit();
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
