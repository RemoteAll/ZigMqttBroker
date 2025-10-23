const std = @import("std");
const IO = @import("iobeetle/io.zig").IO;
const Messages = @import("messages.zig");
const MessageSerde = @import("message_serde.zig");
const Serde = @import("message_serde.zig");
const MQTT = @import("mqtt.zig").Core;
const MQTTClient = @import("mqtt.zig").MQTTClient;
const config = @import("config.zig");
const MemoryPool = std.heap.MemoryPoolExtra;
const TopicName = @import("mqtt.zig").TopicName;

const log = std.log.scoped(.Server);

const posix = std.posix;
const net = std.net;
const Thread = std.Thread;

const Queue = std.fifo.LinearFifo(std.posix.socket_t, .{ .Static = config.queue_size});

const ClientPool = MemoryPool(Client, .{.growable = false});
const MQTTClientPool = MemoryPool(MQTTClient, .{.growable = false});
const MessageAllocatorPool = MemoryPool([config.maximum_message_size]u8, .{.growable = false});
const TopicNamePool = MemoryPool(TopicName, .{.growable = false});

const Acceptor = struct {
    accepting: bool,
    mutex: *std.Thread.Mutex,
    queue: *Queue,
};

pub const Client = struct {
    arena: *std.heap.ArenaAllocator,
    pub_completion: IO.Completion,
    send_completion: IO.Completion,
    recv_completion: IO.Completion,
    io: *IO,
    client_buffer: [config.maximum_message_size]u8,
    socket: std.posix.socket_t,
    thread_id: std.Thread.Id,
    server: *Server,
    core_client: ?*MQTTClient = null,
    message_pool: *MessageAllocatorPool,

    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

var running = std.atomic.Value(bool).init(true);

const SYSTEM_TOPICS = [_][]const u8{
    "$SYS/",
    "$SYS/broker/",
    "$SYS/broker/clients/",
    "$SYS/broker/bytes/",
    "$SYS/broker/messages/",
    "$SYS/broker/uptime/",
    "$SYS/broker/uptime/sol",
    "$SYS/broker/clients/connected/",
    "$SYS/broker/clients/disconnected/",
    "$SYS/broker/bytes/sent/",
    "$SYS/broker/bytes/received/",
    "$SYS/broker/messages/sent/",
    "$SYS/broker/messages/received/",
    "$SYS/broker/memory/used"
};

pub const Server = struct {
    io: *IO,
    address: net.Address,
    socket: posix.socket_t,
    stats_completion: IO.Completion,
    info: Info,
    allocator: std.mem.Allocator,
    mqtt: *MQTT,

    client_pool: ClientPool,
    mqtt_client_pool: MQTTClientPool,
    message_pool: MessageAllocatorPool,
    topic_name_pool: TopicNamePool,

    const Info = struct {
        n_clients: usize, // Connected clients
        n_connections: usize, // Total number of clients connected since start
        start_time: i64, // Server start time
        bytes_recv: usize, // Total bytes received
        bytes_sent: usize, // Total bytes sent
        messages_sent: usize, // Total messages sent
        messages_recv: usize, // Total messages received
    };

    const SYS_TOPICS: usize = 14;

    pub fn new(allocator: std.mem.Allocator, address: []const u8, port: u16, core: *MQTT) !Server {
        var io = try allocator.create(IO);
        errdefer allocator.destroy(io);

        io.* = try IO.init(config.io_entries, 0);
        errdefer io.deinit();

        const addr = try net.Address.parseIp4(address, port);
        const listener = try io.open_socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        errdefer posix.close(listener);

        var client_pool = try ClientPool.initPreheated(allocator, config.max_clients);
        errdefer client_pool.deinit();

        var message_pool = try MessageAllocatorPool.initPreheated(allocator, config.max_messages);
        errdefer message_pool.deinit();

        var mqtt_client_pool = try MQTTClientPool.initPreheated(allocator, config.max_clients);
        errdefer mqtt_client_pool.deinit();

        var topic_name_pool = try TopicNamePool.initPreheated(allocator, config.topic_name_pool_size);
        errdefer topic_name_pool.deinit();

        return Server{
            .io = io,
            .address = addr,
            .socket = listener,
            .stats_completion = undefined,
            .info = .{
                .bytes_recv = 0,
                .bytes_sent = 0,
                .messages_recv = 0,
                .messages_sent = 0,
                .n_clients = 0,
                .n_connections = 0,
                .start_time = std.time.milliTimestamp(),
            },
            .client_pool = client_pool,
            .mqtt_client_pool = mqtt_client_pool,
            .topic_name_pool = topic_name_pool,
            .message_pool = message_pool,
            .allocator = allocator,
            .mqtt = core,
        };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.socket);
        self.io.deinit();
        self.allocator.destroy(self.io);
        self.client_pool.deinit();
    }

    pub fn start(self: *Server, comptime num_handles: usize) !void {
        self.startStatisticsRoutine();

        try std.posix.setsockopt(self.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.bind(self.socket, &self.address.any, self.address.getOsSockLen());
        try std.posix.listen(self.socket, config.kernel_backlog);

        std.log.info("server listening on IP {}. CTRL+C to shutdown.", .{self.address});

        var queue_mutex = Thread.Mutex{};
        var queue = Queue.init();

        var handles: [num_handles]Thread = undefined;
        defer for (handles) |h| h.join();
        for (&handles) |*h| h.* = try Thread.spawn(.{}, logError, .{&queue_mutex, &queue, self});

        var acceptor = Acceptor{
            .accepting = true,
            .mutex = &queue_mutex,
            .queue = &queue,
        };

        while (running.load(.monotonic)) {
            var acceptor_completion: IO.Completion = undefined;
            self.io.accept(*Acceptor, &acceptor, acceptCallback, &acceptor_completion, self.socket);

            while (acceptor.accepting and running.load(.monotonic)) {
                try self.io.run_for_ns(1 * std.time.ns_per_ms);
            }

            acceptor.accepting = true;
        }
    }

    pub fn startStatisticsRoutine(self: *Server) void {
        self.io.timeout(*Server, self, statsRoutuneCallback, &self.stats_completion, 5 * std.time.ns_per_s);
    }
};

fn statsRoutuneCallback(server_ptr: *Server, completion: *IO.Completion, result: IO.TimeoutError!void) void {
    _ = result catch |err| {
        log.err("statsRoutine error: {}", .{err});
        return;
    };

    // TODO: Publish stats to $SYS topics
    //log.info("Publishing stats to $SYS topics", .{});

    server_ptr.io.timeout(*Server, server_ptr, statsRoutuneCallback, completion, 5 * std.time.ns_per_s);
}

fn handleClient(queue_mutex: *std.Thread.Mutex, queue: *Queue, server: *Server) !void {
    const thread_id = std.Thread.getCurrentId();

    var io = try IO.init(128, 0);
    defer io.deinit();

    while (running.load(.monotonic)) {
        const maybe_socket: ?std.posix.socket_t = blk: {
            queue_mutex.lock();
            defer queue_mutex.unlock();
            break :blk queue.readItem();
        };

        if (maybe_socket) |socket| {
            const arena = try server.allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(server.allocator);

            var client_ptr = try server.client_pool.create();
            client_ptr.* = Client{
                .arena = arena,
                .io = &io,
                .send_completion = undefined,
                .recv_completion = undefined,
                .pub_completion = undefined,
                .client_buffer = undefined,
                .socket = socket,
                .thread_id = thread_id,
                .server = server,
                .core_client = null,
                .message_pool = &server.message_pool,
            };

            io.recv(*Client, client_ptr, recvHeaderAndLenCallback, &client_ptr.recv_completion, socket, client_ptr.client_buffer[0..5]);
        }

        try io.run_for_ns(2 * std.time.ns_per_ms);
    }
}

fn recvHeaderAndLenCallback(client_ptr: *Client, completion: *IO.Completion, result: IO.RecvError!usize) void {
    const received = result catch |err| blk: {
        log.err("recvCallback error: {}", .{err});
        break :blk 0;
    };

    log.debug("{}: Received {} bytes from {}", .{client_ptr.thread_id, received, client_ptr.socket});

    if (received <= 0) {
        log.err("Received empty. Closing client: {}", .{client_ptr.socket});
        client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
        return;
    }

    var stream = std.io.fixedBufferStream(client_ptr.client_buffer[1..]);
    const message_len = Serde.decodeLengthSize(stream.reader().any()) catch |err| {
        log.err("Error decoding message length: {}", .{err});
        client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
        return;
    };

    const payload_len = message_len.@"0";
    const len_bytes_size = message_len.@"1";

    log.debug("Message length: {} - Read bytes: {}", .{payload_len, len_bytes_size});

    if (payload_len == 0) {
        // TODO: Nothing more to read, handle command/message directly
    }

    client_ptr.io.recv(*Client, client_ptr, recvPayloadCallback, &client_ptr.recv_completion, client_ptr.socket, client_ptr.client_buffer[received..payload_len + len_bytes_size + 1]);
}

fn recvPayloadCallback(client_ptr: *Client, completion: *IO.Completion, result: IO.RecvError!usize) void {
    const received = result catch |err| blk: {
        log.err("recvCallback error: {}", .{err});
        break :blk 0;
    };

    log.debug("{}: Received payload {} bytes from {}", .{client_ptr.thread_id, received, client_ptr.socket});

    if (received <= 0) {
        log.err("Received empty. Closing client: {}", .{client_ptr.socket});
        client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
        return;
    }

    const message_allocator_buffer = client_ptr.message_pool.create() catch |err| {
        log.err("Error creating message allocator: {}", .{err});
        client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
        return;
    };
    var message_allocator = std.heap.FixedBufferAllocator.init(message_allocator_buffer);

    if (received >= message_allocator_buffer.len) {
        log.err("Received message too big. Closing client: {}", .{client_ptr.socket});
        client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
        return;
    }

    var stream = std.io.fixedBufferStream(client_ptr.client_buffer[0..]);
    const received_msg = Serde.readMQTTPacket(message_allocator.allocator(), stream.reader().any()) catch |err| {
        log.err("Error decoding message: {}", .{err});
        client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
        return;
    };

    log.info("Received message {}", .{received_msg});

    const send_buffer = handleMessage(client_ptr, received_msg) catch |err| {
        log.err("Error handling message: {s}", .{@errorName(err)});
        return client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
    };

    if (send_buffer) |sb| {
        if (sb.len > 0) {
            return client_ptr.io.send(*Client, client_ptr, sendCallback, &client_ptr.send_completion, client_ptr.socket, sb);
        }

        return client_ptr.io.recv(*Client, client_ptr, recvHeaderAndLenCallback, &client_ptr.recv_completion, client_ptr.socket, client_ptr.client_buffer[0..5]);
    }

    return client_ptr.io.close(*Client, client_ptr, closeCallback, completion, client_ptr.socket);
}

fn handleMessage(client_ptr: *Client, received_msg: Messages.MQTTMessage) HandlerError!?[]u8 {
    return switch (received_msg) {
        .Connect => |message| client_ptr.client_buffer[0..try connectHandler(client_ptr, &message)],
        .Disconnect => |message| {
            _ = try disconnectHandler(client_ptr, &message);
            return null;
        },
        .Subscribe => |message| client_ptr.client_buffer[0..try subscribeHandler(client_ptr, &message)],
        .Unsubscribe => |message| client_ptr.client_buffer[0..try unsubscribeHandler(client_ptr, &message)],
        .Ping => |message| client_ptr.client_buffer[0..try pingHandler(client_ptr, &message)],
        .Publish => |message| client_ptr.client_buffer[0..try publishHandler(client_ptr, @constCast(&message))],
        else => error.InvalidMessage,
    };
}

fn sendCallback(client_ptr: *Client, completion: *IO.Completion, result: IO.SendError!usize) void {
    _ = completion;
    const sent = result catch @panic("sendCallback");
    std.log.debug("{}: Sent {} to {}", .{client_ptr.thread_id, sent, client_ptr.socket});

    // Cleanup recv buffer and recv new message
    @memset(client_ptr.client_buffer[0..], 0);
    client_ptr.io.recv(*Client, client_ptr, recvHeaderAndLenCallback, &client_ptr.recv_completion, client_ptr.socket, client_ptr.client_buffer[0..5]);
}

fn sendPublishCallback(client_ptr: *Client, completion: *IO.Completion, result: IO.SendError!usize) void {
    _ = completion;
    const sent = result catch @panic("sendCallback");
    std.log.debug("{}: Sent {} to {}", .{client_ptr.thread_id, sent, client_ptr.socket});
}

fn closeCallback(client_ptr: *Client, completion: *IO.Completion, result: IO.CloseError!void) void {
    _ = completion;
    _ = result catch @panic("closeCallback");
    std.log.debug("{}: Closed {}", .{ client_ptr.thread_id, client_ptr.socket });
    client_ptr.deinit(client_ptr.server.allocator);
    client_ptr.server.client_pool.destroy(client_ptr);
}

fn logError(queue_mutex: *std.Thread.Mutex, queue: *Queue, server: *Server) void {
    handleClient(queue_mutex, queue, server) catch |err| {
        std.log.err("error handling client request: {}", .{err});
    };
}

fn acceptCallback(acceptor_ptr: *Acceptor, completion: *IO.Completion, result: IO.AcceptError!std.posix.socket_t) void {
    _ = completion;

    const accepted_socket = result catch @panic("accept error");
    std.log.debug("Accepted socket fd: {}", .{accepted_socket});

    {
        acceptor_ptr.mutex.lock();
        defer acceptor_ptr.mutex.unlock();

        acceptor_ptr.queue.writeItem(accepted_socket) catch @panic("queue.writeItem");
    }

    acceptor_ptr.accepting = false;
}

pub fn subscribeHandler(client: *Client, message: *const Messages.MQTTSubscribe) HandlerError!usize {
    if (client.core_client) |core_client| {
        var wildcard = false;

        var rcs = std.ArrayList(u8).init(client.arena.allocator());
        defer rcs.deinit();

        for (message.tuples.items) |subscribe| {
            std.log.info("Received SUBSCRIBE from {s}", .{core_client.client_id});

            var topic = subscribe.topic;
            std.log.info("(QOS: {d})", .{subscribe.qos});

            var topic_name_buffer = try client.server.topic_name_pool.create();
            defer client.server.topic_name_pool.destroy(topic_name_buffer);

            if (std.mem.endsWith(u8, topic, "/#")) {
                @memcpy(topic_name_buffer.name[0..topic.len - 1], topic[0..topic.len - 1]);
                topic_name_buffer.length = topic.len - 1;
                wildcard = true;
            } else if (topic[topic.len - 1] != '/') {
                @memset(topic_name_buffer.name[0..], 0);
                @memcpy(topic_name_buffer.name[0..topic.len], topic);
                topic_name_buffer.name[topic.len] = '/';

                topic_name_buffer.length = topic.len + 1;
            }

            const t = brk: {
                if (client.server.mqtt.getTopic(topic_name_buffer.toSlice()) catch null) |t| {
                    break :brk t;
                }

                break :brk try client.server.mqtt.createTopic(topic_name_buffer.toSlice());
            };

            try t.addSubscriber(core_client, subscribe.qos, true);

            try rcs.append(subscribe.qos);
        }

        const response = Messages.MQTTMessage{
            .Suback = Messages.newMQTTMessageSuback(@bitCast(Messages.SUBACK_BYTE), message.pkt_id, rcs.items),
        };

        var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

        std.debug.print("RESPONSE: \n {}\n", .{response});

        return MessageSerde.writeMQTTMessage(writeStream.writer().any(), response, @intFromEnum(Messages.PacketType.SUBACK));
    }

    return error.ClientNotConnected;
}

pub fn unsubscribeHandler(client: *Client, message: *const Messages.MQTTUnsubscribe) HandlerError!usize {
    if (client.core_client) |core_client| {
        log.info("Received UNSUBSCRIBE from {s}", .{core_client.client_id});

        const response = Messages.MQTTMessage{
            .Ack = Messages.newMQTTMessageAck(@bitCast(Messages.UNSUBACK_BYTE), message.pkt_id),
        };

        var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

        std.debug.print("RESPONSE: \n {}\n", .{response});

        return MessageSerde.writeMQTTMessage(writeStream.writer().any(), response, @intFromEnum(Messages.PacketType.UNSUBACK));
    }

    return error.ClientNotConnected;
}

pub fn publishHandler(client: *Client, message: *Messages.MQTTPublish) HandlerError!usize {
    if (client.core_client) |core_client| {
        log.info("Received PUBLISH from {s}", .{core_client.client_id});

        var server = client.server;

        server.info.messages_recv += 1;

        const topic = message.topic;
        const qos = message.header.qos;

        var topic_name_buffer = try server.topic_name_pool.create();
        defer server.topic_name_pool.destroy(topic_name_buffer);

        if (std.mem.endsWith(u8, topic, "/#")) {
            @memcpy(topic_name_buffer.name[0..topic.len - 1], topic[0..topic.len - 1]);
            topic_name_buffer.length = topic.len - 1;
        } else if (topic[topic.len - 1] != '/') {
            @memset(topic_name_buffer.name[0..], 0);
            @memcpy(topic_name_buffer.name[0..topic.len], topic);
            topic_name_buffer.name[topic.len] = '/';

            topic_name_buffer.length = topic.len + 1;
        }

        const t = brk: {
            if (client.server.mqtt.getTopic(topic_name_buffer.toSlice()) catch null) |t| {
                break :brk t;
            }

            break :brk try client.server.mqtt.createTopic(topic_name_buffer.toSlice());
        };

        for (0..t.subscribers_count) |idx| {
            var publen = Messages.MQTT_HEADER_LEN + 2 + message.topic_len + message.payload_len;
            const sub = t.subscribers[idx];

            message.header.qos = @intCast(sub.qos);
            if (message.header.qos > @intFromEnum( Messages.QosLevel.AT_MOST_ONCE)) {
                publen += 2;
            }

            var remaining_offset: usize = 0;
            if ((publen - 1) > 0x200000) {
                remaining_offset = 3;
            } else if ((publen - 1) > 0x4000) {
                remaining_offset = 2;
            } else if ((publen - 1) > 0x80) {
                remaining_offset = 1;
            }

            publen += remaining_offset;

            const pub_message = Messages.MQTTMessage{
                .Publish = message.*,
            };

            var server_client = sub.client.server_client;

            var writeStream = std.io.fixedBufferStream(server_client.client_buffer[0..]);

            std.debug.print("RESPONSE: \n {}\n", .{pub_message});

            const written =try MessageSerde.writeMQTTMessage(writeStream.writer().any(), pub_message, @intFromEnum(Messages.PacketType.PUBLISH));
            std.debug.assert(written == publen);

            server_client.io.send(*Client, server_client, sendPublishCallback, &server_client.pub_completion, server_client.socket, server_client.client_buffer[0..publen]);

            server.info.messages_sent += 1;
            server.info.bytes_sent += publen;
        }
        
        std.log.info("QOS LEVEL: {s}", .{@tagName(@as(Messages.QosLevel, @enumFromInt(qos)))});

        switch (qos) {
            @intFromEnum(Messages.QosLevel.AT_LEAST_ONCE) => {
                const puback = Messages.newMQTTMessageAck(@bitCast(Messages.PUBACK_BYTE), message.pkt_id);
                const puback_message = Messages.MQTTMessage{
                    .PubAck = puback,
                };

                var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

                return MessageSerde.writeMQTTMessage(writeStream.writer().any(), puback_message, @intFromEnum(Messages.PacketType.PUBACK));
            },
            @intFromEnum(Messages.QosLevel.EXACTLY_ONCE) => {
                const pubrec = Messages.newMQTTMessageAck(@bitCast(Messages.PUBACK_BYTE), message.pkt_id);
                const pubrec_message = Messages.MQTTMessage{
                    .PubRec = pubrec,
                };

                var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

                return MessageSerde.writeMQTTMessage(writeStream.writer().any(), pubrec_message, @intFromEnum(Messages.PacketType.PUBREC));
            },
            else => return 0,
        }
    }

    return error.ClientNotConnected;
}

pub fn pingHandler(client: *Client, _: *const Messages.MQTTPingreq) HandlerError!usize {
    if (client.core_client) |core_client| {
        log.info("Received PINGREQ from {s}", .{core_client.client_id});

        const response = Messages.MQTTMessage{
            .Header = @bitCast(Messages.PINGRESP_BYTE),
        };

        var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

        std.debug.print("RESPONSE: \n {}\n", .{response});

        return MessageSerde.writeMQTTMessage(writeStream.writer().any(), response, @intFromEnum(Messages.PacketType.PINGRESP));
    }

    return error.ClientNotConnected;
}

pub fn disconnectHandler(client: *Client, _: *const Messages.MQTTAck) HandlerError!void {
    if (client.core_client) |core_client| {
        log.info("Received DISCONNECT from {s}", .{core_client.client_id});

        _ = client.server.mqtt.removeClient(core_client);

        client.server.info.n_clients -= 1;
        client.server.info.n_connections -= 1;

        return;
    }

    return error.ClientNotConnected;
}

pub fn connectHandler(client: *Client, message: *const Messages.MQTTConnect) HandlerError!usize {

    var server = client.server;

    if (server.mqtt.containsClient(message.payload.client_id) and std.mem.eql(u8, message.payload.client_id, &client.core_client.?.client_id)) {

        std.log.info("Received double CONNECT from {s}, disconnecting client", .{message.payload.client_id});

        _ = server.mqtt.removeClient(client.core_client.?);

        server.info.n_clients -= 1;
        server.info.n_connections -= 1;

        return error.ClientAlreadyConnected;
    }

    std.log.info("New client connected as {s} ({b}, {d})", .{
        message.payload.client_id,
        message.flgs.clean_session,
        message.payload.keepalive,
    });

    var coreClient = try server.mqtt_client_pool.create();
    errdefer server.mqtt_client_pool.destroy(coreClient);

    @memset(&coreClient.client_id, 0);
    @memcpy(coreClient.client_id[0..message.payload.client_id.len], message.payload.client_id);

    server.mqtt.addClient(coreClient);
    client.core_client = coreClient;
    coreClient.server_client = client;

    const session_present: u8 = 0;
    const connect_flags: u8 = 0 | (session_present & 0x1) << 0;
    const rc: u8 = 0x00;

    const response = Messages.MQTTMessage{
        .Connack = Messages.newMQTTMessageConnack(@bitCast(Messages.CONNACK_BYTE), connect_flags, rc),
    };

    var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

    std.debug.print("RESPONSE: \n {}\n", .{response});

    return MessageSerde.writeMQTTMessage(writeStream.writer().any(), response, @intFromEnum(Messages.PacketType.CONNACK));
}

pub fn pubAckHandler(_: *Client, _: *const Messages.MQTTConnect) HandlerError!usize {
    // Remove from pending PUBACK clients map
}

pub fn pubRecHandler(client: *Client, message: *const Messages.MQTTPublish) HandlerError!usize {
    log.info("Received PUBREC from {s}", .{client.core_client.?.client_id});

    const pubrel_message = Messages.MQTTMessage{
        .PubRec = Messages.newMQTTMessageAck(@bitCast(Messages.PUBREL_BYTE), message.pkt_id),
    };

    var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

    return MessageSerde.writeMQTTAck(writeStream.writer().any(), pubrel_message);
}

pub fn pubRelHandler(client: *Client, message: *const Messages.MQTTConnect) HandlerError!usize {
    log.info("Received PUBREL from {s}", .{client.core_client.?.client_id});

    const pubcomp_message = Messages.MQTTMessage{
        .PubComp = Messages.newMQTTMessageAck(@bitCast(Messages.PUBCOMP_BYTE), message.pkt_id),
    };

    var writeStream = std.io.fixedBufferStream(client.client_buffer[0..]);

    return MessageSerde.writeMQTTAck(writeStream.writer().any(), pubcomp_message);
}

pub fn pubCompHandler(_: *Client, _: *const Messages.MQTTConnect) HandlerError!usize {

    // Remove from pending PUBACK clients map
}

pub const HandlerError = error{
    ClientAlreadyConnected,
    ClientNotConnected,
    InvalidMessage,
    InvalidPacketType,
    OutOfMemory,
    SubscriptionLimitReached,
    InvalidProtocolName,
    WriteMQTTError,
};