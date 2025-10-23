const std = @import("std");
const Client = @import("client.zig").Client;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Subscription Tree maintains a list of MQTT subscribers and allows for efficient matching of topics to clients
pub const SubscriptionTree = struct {
    const Node = struct {
        children: std.StringHashMap(Node),
        subscribers: ArrayList(*Client),

        pub fn init(allocator: Allocator) Node {
            return Node{
                .children = std.StringHashMap(Node).init(allocator),
                .subscribers = .{},
            };
        }

        pub fn subscribe(self: *Node, topic_levels: [][]const u8, client: *Client, allocator: Allocator) !void {
            if (topic_levels.len == 0) {
                try self.subscribers.append(allocator, client);
                return;
            }

            const child = try self.children.getOrPut(topic_levels[0]);
            if (!child.found_existing) {
                child.value_ptr.* = Node{
                    .children = std.StringHashMap(Node).init(self.children.allocator),
                    .subscribers = .{},
                };
            }
            try child.value_ptr.subscribe(topic_levels[1..], client, allocator);
        }

        pub fn unsubscribe(self: *Node, topic_levels: [][]const u8, client: *Client, allocator: Allocator) !bool {
            if (topic_levels.len == 0) {
                // 到达目标层级,移除该客户端
                var found = false;
                var i: usize = 0;
                while (i < self.subscribers.items.len) {
                    if (self.subscribers.items[i].id == client.id) {
                        _ = self.subscribers.swapRemove(i);
                        found = true;
                        // 不增加 i,因为 swapRemove 会把最后一个元素移到当前位置
                        // 需要继续检查当前位置(如果有重复订阅的话)
                        continue;
                    }
                    i += 1;
                }
                return found;
            }

            // 继续向下查找
            if (self.children.getPtr(topic_levels[0])) |child| {
                const found = try child.unsubscribe(topic_levels[1..], client, allocator);

                // 清理空节点:如果子节点没有订阅者且没有子节点,则删除该子节点
                if (found and child.subscribers.items.len == 0 and child.children.count() == 0) {
                    // 需要递归释放子节点资源
                    const removed_node = self.children.fetchRemove(topic_levels[0]);
                    if (removed_node) |entry| {
                        var node = entry.value;
                        node.deinit_deep(allocator);
                    }
                }

                return found;
            }

            // 主题路径不存在
            return false;
        }

        pub fn match(self: *Node, topic_levels: [][]const u8, matched_clients: *ArrayList(*Client), allocator: Allocator) !void {
            // 如果没有更多层级，收集当前节点的订阅者
            if (topic_levels.len == 0) {
                for (self.subscribers.items) |client| {
                    try matched_clients.append(allocator, client);
                }
                return;
            }

            // 1. 处理多级通配符 '#' (匹配所有剩余层级)
            if (self.children.get("#")) |wildcard_child| {
                // '#' 匹配当前层级和所有子层级，直接收集订阅者
                for (wildcard_child.subscribers.items) |client| {
                    try matched_clients.append(allocator, client);
                }
            }

            // 2. 处理单级通配符 '+' (只匹配当前层级)
            if (self.children.get("+")) |plus_child| {
                try plus_child.match(topic_levels[1..], matched_clients, allocator);
            }

            // 3. 精确匹配当前层级
            if (self.children.get(topic_levels[0])) |child| {
                try child.match(topic_levels[1..], matched_clients, allocator);
            }
        }
        fn deinit_deep(self: *Node, allocator: Allocator) void {
            var it = self.children.iterator();
            while (it.next()) |child| {
                child.value_ptr.deinit_deep(allocator);
            }
            self.children.deinit();
            self.subscribers.deinit(allocator);
        }
    };

    root: Node,

    pub fn init(allocator: Allocator) SubscriptionTree {
        return SubscriptionTree{
            .root = Node.init(allocator),
        };
    }

    pub fn deinit(self: *SubscriptionTree) void {
        self.root.deinit_deep(self.root.children.allocator);
    }

    pub fn subscribe(self: *SubscriptionTree, topic: []const u8, client: *Client) !void {
        // 验证主题过滤器格式
        try validateTopicFilter(topic);

        const allocator = self.root.children.allocator;
        const topic_levels = try parseTopicLevels(topic, allocator);
        defer allocator.free(topic_levels); // 释放 parseTopicLevels 分配的内存

        std.debug.print(">> subscribe() >> topic_levels: {any}\n", .{topic_levels});
        try self.root.subscribe(topic_levels, client, allocator);
    }

    pub fn unsubscribe(self: *SubscriptionTree, topic: []const u8, client: *Client) !bool {
        // 验证主题过滤器格式
        try validateTopicFilter(topic);

        const allocator = self.root.children.allocator;
        const topic_levels = try parseTopicLevels(topic, allocator);
        defer allocator.free(topic_levels); // 释放 parseTopicLevels 分配的内存

        std.debug.print(">> unsubscribe() >> topic_levels: {any}\n", .{topic_levels});
        return try self.root.unsubscribe(topic_levels, client, allocator);
    }

    pub fn match(self: *SubscriptionTree, topic: []const u8, allocator: *Allocator) !ArrayList(*Client) {
        var matched_clients: ArrayList(*Client) = .{};
        const topic_levels = try parseTopicLevels(topic, self.root.children.allocator);
        try self.root.match(topic_levels, &matched_clients, allocator.*);
        return matched_clients;
    }

    fn parseTopicLevels(topic: []const u8, allocator: Allocator) ![][]const u8 {
        // 防止空字符串导致段错误
        if (topic.len == 0) {
            std.debug.print("WARNING: parseTopicLevels received empty topic\n", .{});
            return &[_][]const u8{};
        }

        var topic_levels: ArrayList([]const u8) = .{};

        // MQTT 规范说明：
        // - 使用 splitScalar 而不是 tokenizeScalar，以保留空层级
        // - 根据 MQTT 规范，"/test" 和 "test" 是不同的主题：
        //   - "/test" 解析为 ["", "test"] (有一个空的根层级)
        //   - "test" 解析为 ["test"]
        // - 这确保主题层级的语义完全符合 MQTT 协议
        //
        // 兼容性：
        // ✅ "/test" -> ["", "test"]  (符合 MQTT 规范)
        // ✅ "test"  -> ["test"]      (符合 MQTT 规范)
        // ✅ "a/b/c" -> ["a", "b", "c"]
        // ✅ "/a/b"  -> ["", "a", "b"]
        // ✅ "a/b/"  -> ["a", "b", ""] (尾部空层级也保留)
        // ✅ "sport/#" -> ["sport", "#"] (多级通配符)
        // ✅ "sport/+/player1" -> ["sport", "+", "player1"] (单级通配符)

        var iterator = std.mem.splitScalar(u8, topic, '/');
        while (iterator.next()) |level| {
            try topic_levels.append(allocator, level);
        }

        return topic_levels.toOwnedSlice(allocator);
    }

    /// 验证主题过滤器是否符合 MQTT 规范
    /// [MQTT-4.7.1-1] 通配符字符可以用在主题过滤器中，但不能用在主题名称中
    /// [MQTT-4.7.1-2] 多级通配符必须单独使用或跟在主题层级分隔符后面，且必须是最后一个字符
    /// [MQTT-4.7.1-3] 单级通配符必须占据整个层级
    fn validateTopicFilter(topic: []const u8) !void {
        if (topic.len == 0) {
            return error.InvalidTopicFilter;
        }

        var i: usize = 0;
        while (i < topic.len) : (i += 1) {
            const c = topic[i];

            // 检查多级通配符 '#'
            if (c == '#') {
                // [MQTT-4.7.1-2] '#' 必须是最后一个字符
                if (i != topic.len - 1) {
                    std.debug.print("ERROR: Multi-level wildcard '#' must be the last character\n", .{});
                    return error.InvalidTopicFilter;
                }
                // '#' 必须是单独的层级或在 '/' 之后
                if (i > 0 and topic[i - 1] != '/') {
                    std.debug.print("ERROR: Multi-level wildcard '#' must occupy an entire level\n", .{});
                    return error.InvalidTopicFilter;
                }
            }

            // 检查单级通配符 '+'
            if (c == '+') {
                // [MQTT-4.7.1-3] '+' 必须占据整个层级
                // 检查前面的字符
                if (i > 0 and topic[i - 1] != '/') {
                    std.debug.print("ERROR: Single-level wildcard '+' must occupy an entire level\n", .{});
                    return error.InvalidTopicFilter;
                }
                // 检查后面的字符
                if (i + 1 < topic.len and topic[i + 1] != '/') {
                    std.debug.print("ERROR: Single-level wildcard '+' must occupy an entire level\n", .{});
                    return error.InvalidTopicFilter;
                }
            }
        }
    }
};
