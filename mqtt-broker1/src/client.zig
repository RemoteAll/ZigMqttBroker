const std = @import("std");
const net = std.net;
const time = std.time;
const Allocator = std.mem.Allocator;

const QoS = @import("mqtt.zig").QoS;
const ProtocolVersion = @import("mqtt.zig").ProtocolVersion;

pub const ClientError = error{
    ClientReadError,
    ClientNotFound,
};

// Client represents a MQTT client connected to the broker
pub const Client = struct {
    allocator: Allocator,

    // Basic client information
    id: u64,
    identifer: []u8,
    protocol_version: ?ProtocolVersion = null,
    stream: net.Stream,
    address: net.Address,

    // Connection state
    is_connected: bool,
    connect_time: i64,
    last_activity: i64,
    disconnect_time: i64, // Clean Session = 0 断开时记录，用于会话过期判断

    // 引用计数：用于管理 Client 对象的生命周期
    // 当订阅树、消息队列等持有 *Client 指针时会增加引用计数
    // 只有引用计数为 0 时才能真正释放 Client 对象
    ref_count: std.atomic.Value(u32),

    // MQTT session properties
    clean_start: bool,
    session_expiry_interval: u32,

    // Keep alive
    keep_alive: u16,

    // Authentication
    username: ?[]const u8,
    password: ?[]const u8,

    // Will message
    will_topic: ?[]const u8,
    will_payload: ?[]const u8,
    will_qos: QoS,
    will_retain: bool,
    will_delay_interval: u32,

    // Subscriptions
    subscriptions: std.ArrayList(Subscription),

    // 反向索引：记录该客户端订阅了订阅树中的哪些节点
    // 用于快速替换指针，避免遍历整棵订阅树
    // 性能优化：断开时替换指针从 O(N×M) → O(M)，M=订阅数
    subscribed_nodes: std.ArrayList(*anyopaque), // 存储 *SubscriptionTree.Node，但这里用 anyopaque 避免循环依赖

    // Message queues
    incoming_queue: std.ArrayList(Message),
    outgoing_queue: std.ArrayList(Message),

    // Flow control
    receive_maximum: u16,
    maximum_packet_size: u32,
    topic_alias_maximum: u16,

    // Other MQTT 5.0 properties
    user_properties: std.StringHashMap([]const u8),

    // Packet tracking
    packet_id_counter: u16,
    inflight_messages: std.AutoHashMap(u16, Message),

    pub const Subscription = struct {
        topic_filter: []const u8,
        qos: QoS,
        no_local: bool,
        retain_as_published: bool,
        retain_handling: RetainHandling,
        subscription_identifier: ?u32,

        pub const RetainHandling = enum(u2) {
            SendRetained = 0,
            SendRetainedForNewSubscription = 1,
            DoNotSendRetained = 2,
        };
    };

    /// 检查客户端对某个主题是否设置了 no_local 标志
    /// 如果设置了 no_local,该客户端发布的消息不会被转发回来
    pub fn hasNoLocal(self: *const Client, topic: []const u8) bool {
        for (self.subscriptions.items) |sub| {
            // 简单匹配:检查主题是否与订阅过滤器匹配
            if (topicMatchesFilter(topic, sub.topic_filter) and sub.no_local) {
                return true;
            }
        }
        return false;
    }

    /// 简单的主题匹配函数
    /// 支持 MQTT 通配符:
    /// - '+' 匹配单级
    /// - '#' 匹配多级(必须在末尾)
    fn topicMatchesFilter(topic: []const u8, filter: []const u8) bool {
        // 精确匹配
        if (std.mem.eql(u8, topic, filter)) {
            return true;
        }

        // 多级通配符 '#'
        if (std.mem.endsWith(u8, filter, "/#")) {
            const prefix = filter[0 .. filter.len - 2];
            if (prefix.len == 0) return true; // "#" 匹配所有
            if (std.mem.startsWith(u8, topic, prefix)) {
                if (topic.len == prefix.len) return true; // 精确匹配前缀
                if (topic.len > prefix.len and topic[prefix.len] == '/') return true;
            }
            return false;
        }

        // 单级通配符 '+'
        if (std.mem.indexOf(u8, filter, "+") != null) {
            var topic_it = std.mem.splitSequence(u8, topic, "/");
            var filter_it = std.mem.splitSequence(u8, filter, "/");

            while (true) {
                const t_level = topic_it.next();
                const f_level = filter_it.next();

                if (t_level == null and f_level == null) return true; // 都结束
                if (t_level == null or f_level == null) return false; // 长度不匹配

                if (!std.mem.eql(u8, f_level.?, "+")) {
                    if (!std.mem.eql(u8, t_level.?, f_level.?)) return false;
                }
            }
        }

        return false;
    }

    pub const Message = struct {
        topic: []const u8,
        payload: []const u8,
        qos: QoS,
        retain: bool,
        packet_id: ?u16,
        dup: bool,
        expiry_interval: ?u32,
        topic_alias: ?u16,
        response_topic: ?[]const u8,
        correlation_data: ?[]const u8,
        user_properties: std.StringHashMap([]const u8),
        subscription_identifiers: ?std.ArrayList(u32),
        content_type: ?[]const u8,
    };

    pub fn init(allocator: Allocator, id: u64, protocol_version: ProtocolVersion, stream: net.Stream, address: net.Address) !*Client {
        const client = try allocator.create(Client);
        client.* = .{
            .allocator = allocator,
            .id = id,
            .identifer = &[_]u8{}, // 初始化为空切片而不是 undefined
            .protocol_version = protocol_version,
            .stream = stream,
            .address = address,
            .is_connected = false,
            .connect_time = 0,
            .last_activity = 0,
            .disconnect_time = 0, // 初始化为 0，表示未断开
            .ref_count = std.atomic.Value(u32).init(1), // 初始引用计数为 1
            .clean_start = true,
            .session_expiry_interval = 0,
            .keep_alive = 0,
            .username = null,
            .password = null,
            .will_topic = null,
            .will_payload = null,
            .will_qos = .AtMostOnce,
            .will_retain = false,
            .will_delay_interval = 0,
            // ✅ Zig 0.15.2: 使用空字面量初始化 ArrayList
            .subscriptions = .{},
            .subscribed_nodes = .{}, // 反向索引初始化为空
            .incoming_queue = .{},
            .outgoing_queue = .{},
            .receive_maximum = 65535,
            .maximum_packet_size = 268435455, // Default to 256 MiB
            .topic_alias_maximum = 0,
            .user_properties = std.StringHashMap([]const u8).init(allocator),
            .packet_id_counter = 0,
            .inflight_messages = std.AutoHashMap(u16, Message).init(allocator),
        };
        return client;
    }

    /// 增加引用计数（订阅树添加引用时调用）
    /// 返回增加后的引用计数值
    pub fn retain(self: *Client) u32 {
        const old_count = self.ref_count.fetchAdd(1, .monotonic);
        std.log.debug("Client {s} ref_count: {} -> {}", .{ self.identifer, old_count, old_count + 1 });
        return old_count + 1;
    }

    /// 减少引用计数（订阅树移除引用时调用）
    /// 返回 true 表示引用计数归零，可以安全释放
    pub fn release(self: *Client) bool {
        const old_count = self.ref_count.fetchSub(1, .monotonic);
        std.log.debug("Client {s} ref_count: {} -> {}", .{ self.identifer, old_count, old_count - 1 });

        if (old_count == 1) {
            // 引用计数归零，可以安全释放
            std.log.info("Client {s} ref_count reached 0, ready for cleanup", .{self.identifer});
            return true;
        }
        return false;
    }

    /// 获取当前引用计数
    pub fn getRefCount(self: *const Client) u32 {
        return self.ref_count.load(.monotonic);
    }

    pub fn deinit(self: *Client) void {
        // 注意：orphan_client 的 stream 可能已经关闭或无效
        // 所以不要调用 stream.close()，应该在 disconnect 时已经关闭
        // self.stream.close();  // ❌ 不安全，stream 可能已经无效

        if (self.username) |username| self.allocator.free(username);
        if (self.password) |password| self.allocator.free(password);
        if (self.will_topic) |topic| self.allocator.free(topic);
        if (self.will_payload) |payload| self.allocator.free(payload);

        // 释放客户端标识符(如果已分配)
        // 注意：Arena 分配的 Client 会由 Arena.deinit() 自动释放
        // 只有全局 allocator 分配的 orphan_client 才需要这里释放
        if (self.identifer.len > 0) self.allocator.free(self.identifer);

        // ✅ Zig 0.15.2: deinit() 需要传入 allocator 参数
        self.subscriptions.deinit(self.allocator);
        self.subscribed_nodes.deinit(self.allocator); // 清理反向索引
        self.incoming_queue.deinit(self.allocator);
        self.outgoing_queue.deinit(self.allocator);
        self.user_properties.deinit();
        self.inflight_messages.deinit();

        // 注意：不要调用 allocator.destroy(self)
        // 因为这个方法可能被 Arena 分配的 Client 调用（虽然不应该）
        // 调用者负责 destroy
    }

    pub fn connect(self: *Client, identifer: []u8, protocol_version: ?ProtocolVersion, clean_start: bool, session_expiry_interval: u32, keep_alive: u16) void {
        self.identifer = identifer;
        self.protocol_version = protocol_version;
        self.clean_start = clean_start;
        self.is_connected = true;
        self.connect_time = time.milliTimestamp();
        self.last_activity = self.connect_time;
        self.session_expiry_interval = session_expiry_interval;
        self.keep_alive = keep_alive;
    }

    pub fn nextPacketId(self: *Client) u16 {
        self.packet_id_counter +%= 1;
        if (self.packet_id_counter == 0) self.packet_id_counter = 1;
        return self.packet_id_counter;
    }

    pub fn addSubscription(self: *Client, subscription: Subscription) !void {
        try self.subscriptions.append(self.allocator, subscription);
        std.log.info("Client {s} subscribed to {s}", .{ self.identifer, subscription.topic_filter });
    }
    pub fn removeSubscription(self: *Client, topic_filter: []const u8) void {
        var i: usize = self.subscriptions.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.subscriptions.items[i].topic_filter, topic_filter)) {
                _ = self.subscriptions.swapRemove(i);
                break;
            }
        }
        std.log.info("Client {s} unsubscribed to {s}", .{ self.identifer, topic_filter });
    }

    pub fn queueMessage(self: *Client, message: Message) !void {
        try self.outgoing_queue.append(message);
    }

    pub fn acknowledgeMessage(self: *Client, packet_id: u16) void {
        _ = self.inflight_messages.remove(packet_id);
    }

    pub fn updateActivity(self: *Client) void {
        self.last_activity = time.milliTimestamp();
    }

    /// 获取客户端的完整标识字符串,用于日志输出
    /// 格式: "Client(mqtt_client_id) #sequence_number" 或 "Client #sequence_number" (如果 MQTT ID 未设置)
    pub fn getDisplayName(self: *Client, buffer: []u8) ![]const u8 {
        if (self.identifer.len > 0) {
            return std.fmt.bufPrint(buffer, "Client({s}) #{d}", .{ self.identifer, self.id });
        } else {
            return std.fmt.bufPrint(buffer, "Client #{d}", .{self.id});
        }
    }

    pub fn debugPrint(self: *Client) void {
        std.debug.print("----- CLIENT {any} -----\n", .{self.id});
        // 只有在 identifer 已设置时才打印(长度不为 0 且不是未定义值)
        if (self.identifer.len > 0) {
            std.debug.print("Client ID (MQTT): {s}\n", .{self.identifer});
        } else {
            std.debug.print("Client ID (MQTT): <not set>\n", .{});
        }
        if (self.protocol_version) |pv| {
            std.debug.print("Protocol Version: {s}\n", .{pv.toString()});
        } else {
            std.debug.print("Protocol Version: <not set>\n", .{});
        }
        std.debug.print("Address: {any}\n", .{self.address});
        std.debug.print("Is Connected: {any}\n", .{self.is_connected});
        std.debug.print("Connect Time: {}\n", .{self.connect_time});
        std.debug.print("Last Activity: {}\n", .{self.last_activity});
        std.debug.print("Clean Start: {}\n", .{self.clean_start});
        std.debug.print("Session Expiry Interval: {}\n", .{self.session_expiry_interval});
        std.debug.print("Keep Alive: {d}\n", .{self.keep_alive});
        std.debug.print("Username: {?s}\n", .{self.username});
        std.debug.print("Password: {?s}\n", .{self.password});
        std.debug.print("Will Topic: {?s}\n", .{self.will_topic});
        std.debug.print("Will Payload: {?s}\n", .{self.will_payload});
        std.debug.print("Will QoS: {}\n", .{self.will_qos});
        std.debug.print("Will Retain: {}\n", .{self.will_retain});
        std.debug.print("Will Delay Interval: {}\n", .{self.will_delay_interval});
        // std.debug.print("Subscriptions: {}\n", .{self.subscriptions});
        // std.debug.print("Incoming Queue: {}\n", .{self.incoming_queue});
        // std.debug.print("Outgoing Queue: {}\n", .{self.outgoing_queue});
        std.debug.print("Receive Maximum: {}\n", .{self.receive_maximum});
        std.debug.print("Maximum Packet Size: {}\n", .{self.maximum_packet_size});
        std.debug.print("Topic Alias Maximum: {}\n", .{self.topic_alias_maximum});
        // std.debug.print("User Properties: {}\n", .{self.user_properties});
        std.debug.print("Packet ID Counter: {}\n", .{self.packet_id_counter});
        // std.debug.print("Inflight Messages: {}\n", .{self.inflight_messages});
        std.debug.print("----------\n", .{});
    }
};

// [MQTT-3.1.3-5] length and chars
// 注意：此函数用于检查是否符合 MQTT 3.1.1 严格规范（1-23 字节，仅字母数字）
// 实际使用中，我们允许更宽松的 ClientId（见 handle_connect.zig 中的处理）
pub fn isValidClientId(client_id: []const u8) bool {
    // Check if the length is between 1 and 23 bytes
    if (client_id.len < 1 or client_id.len > 23) {
        return false;
    }

    // Check if all characters are valid (strict MQTT 3.1.1)
    for (client_id) |char| {
        switch (char) {
            '0'...'9', 'a'...'z', 'A'...'Z' => continue,
            else => return false,
        }
    }

    // Check if the client_id is valid UTF-8
    return std.unicode.utf8ValidateSlice(client_id);
}

/// 宽松的 ClientId 验证，允许更多字符和更长的 ID
/// 用于兼容各种云平台（阿里云 IoT、AWS IoT 等）的 ClientId 格式
/// 允许字符：字母、数字、以及常见的特殊字符（-_:|.@）
pub fn isValidClientIdRelaxed(client_id: []const u8) bool {
    // 空 ID 无效
    if (client_id.len == 0) {
        return false;
    }

    // 检查是否是有效的 UTF-8
    if (!std.unicode.utf8ValidateSlice(client_id)) {
        return false;
    }

    // 允许字母、数字和常见的特殊字符
    for (client_id) |char| {
        switch (char) {
            '0'...'9',
            'a'...'z',
            'A'...'Z',
            '-',
            '_',
            ':',
            '|',
            '.',
            '@',
            => continue,
            else => return false,
        }
    }

    return true;
}

test "isValidClientId" {
    const expect = std.testing.expect;

    try expect(isValidClientId("validClientId123"));
    try expect(isValidClientId("a"));
    try expect(isValidClientId("ABCDEFGHIJKLMNOPQRSTUVW"));
    try expect(!isValidClientId(""));
    try expect(!isValidClientId("tooLongClientIdAAAAAAAAA"));
    try expect(!isValidClientId("invalid-client-id"));
    try expect(!isValidClientId("emoji😊"));
}

test "isValidClientIdRelaxed" {
    const expect = std.testing.expect;

    // 基本的字母数字
    try expect(isValidClientIdRelaxed("validClientId123"));
    try expect(isValidClientIdRelaxed("a"));

    // 允许的特殊字符
    try expect(isValidClientIdRelaxed("GateWay|0HND9I2NIAT2A")); // 阿里云 IoT 格式
    try expect(isValidClientIdRelaxed("client-id-with-dash"));
    try expect(isValidClientIdRelaxed("client_id_with_underscore"));
    try expect(isValidClientIdRelaxed("client:id:with:colon"));
    try expect(isValidClientIdRelaxed("client.id.with.dot"));
    try expect(isValidClientIdRelaxed("user@domain.com"));

    // 长 ID（超过 23 字节）
    try expect(isValidClientIdRelaxed("veryLongClientIdThatExceeds23Characters"));

    // 无效的情况
    try expect(!isValidClientIdRelaxed("")); // 空 ID
    try expect(!isValidClientIdRelaxed("invalid client id")); // 空格不允许
    try expect(!isValidClientIdRelaxed("emoji😊")); // emoji 不允许
    try expect(!isValidClientIdRelaxed("id#with#hash")); // # 不允许
    try expect(!isValidClientIdRelaxed("id$with$dollar")); // $ 不允许
}
