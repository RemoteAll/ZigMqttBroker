const std = @import("std");
const Client = @import("client.zig").Client;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const config = @import("config.zig");

const debugPrint = if (config.ENABLE_VERBOSE_LOGGING) std.debug.print else struct {
    fn print(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
}.print;

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

        pub fn subscribe(self: *Node, topic_levels: [][]const u8, client: *Client) !void {
            debugPrint(">> Node.subscribe() >> topic_levels.len={}\n", .{topic_levels.len});

            if (topic_levels.len == 0) {
                // 检查是否已订阅（去重）- 使用 MQTT 客户端 ID 而不是连接 ID
                // 反向遍历，新订阅通常在末尾
                var i: usize = self.subscribers.items.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, self.subscribers.items[i].identifer, client.identifer)) {
                        debugPrint(">> Client '{s}' (conn_id: {}) already subscribed, skipping\n", .{ client.identifer, client.id });
                        return;
                    }
                }
                debugPrint(">> Adding client '{s}' (conn_id: {}) as subscriber (total: {})\n", .{ client.identifer, client.id, self.subscribers.items.len + 1 });
                try self.subscribers.append(self.children.allocator, client);
                return;
            }

            const current_level = topic_levels[0];
            debugPrint(">> Creating/getting child node for level: '{s}'\n", .{current_level});

            const child = try self.children.getOrPut(current_level);
            if (!child.found_existing) {
                debugPrint(">> Created new child node for '{s}'\n", .{current_level});
                child.value_ptr.* = Node{
                    .children = std.StringHashMap(Node).init(self.children.allocator),
                    .subscribers = .{},
                };
            } else {
                debugPrint(">> Found existing child node for '{s}'\n", .{current_level});
            }
            try child.value_ptr.subscribe(topic_levels[1..], client);
        }

        pub fn unsubscribe(self: *Node, topic_levels: [][]const u8, client: *Client) bool {
            debugPrint(">> Node.unsubscribe() >> topic_levels.len={}\n", .{topic_levels.len});

            if (topic_levels.len == 0) {
                // 查找并移除客户端（使用 MQTT 客户端 ID）
                var i: usize = 0;
                while (i < self.subscribers.items.len) {
                    if (std.mem.eql(u8, self.subscribers.items[i].identifer, client.identifer)) {
                        _ = self.subscribers.swapRemove(i);
                        debugPrint(">> Removed client '{s}' (conn_id: {}) from subscribers (remaining: {})\n", .{ client.identifer, client.id, self.subscribers.items.len });
                        return true;
                    }
                    i += 1;
                }
                debugPrint(">> Client '{s}' (conn_id: {}) not found in subscribers\n", .{ client.identifer, client.id });
                return false;
            }

            const current_level = topic_levels[0];
            debugPrint(">> Looking for child node: '{s}'\n", .{current_level});

            if (self.children.getPtr(current_level)) |child| {
                debugPrint(">> Found child node for '{s}'\n", .{current_level});
                return child.unsubscribe(topic_levels[1..], client);
            } else {
                debugPrint(">> No child node found for '{s}'\n", .{current_level});
                return false;
            }
        }

        pub fn removeClient(self: *Node, client_identifer: []const u8) void {
            // 从当前节点移除客户端（使用 MQTT 客户端 ID）
            // 注意：使用 swapRemove 后不要增加索引，因为末尾元素会移动到当前位置
            var i: usize = 0;
            while (i < self.subscribers.items.len) {
                if (std.mem.eql(u8, self.subscribers.items[i].identifer, client_identifer)) {
                    const conn_id = self.subscribers.items[i].id;
                    _ = self.subscribers.swapRemove(i);
                    debugPrint(">> Removed disconnected client '{s}' (conn_id: {}) from node\n", .{ client_identifer, conn_id });
                    // 不增加 i，因为需要检查刚刚移动过来的元素
                } else {
                    i += 1;
                }
            }

            // 递归处理所有子节点
            var it = self.children.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.removeClient(client_identifer);
            }
        }

        pub fn match(self: *Node, topic_levels: [][]const u8, matched_clients: *ArrayList(*Client), allocator: Allocator) !void {
            debugPrint(">> Node.match() >> topic_levels.len={}, subscribers.len={}\n", .{ topic_levels.len, self.subscribers.items.len });

            if (topic_levels.len == 0) {
                debugPrint(">> Reached end of topic, adding {} subscribers\n", .{self.subscribers.items.len});
                for (self.subscribers.items) |client| {
                    // 只添加仍然连接的客户端
                    if (client.is_connected) {
                        try matched_clients.append(allocator, client);
                    }
                }
                return;
            }

            const current_level = topic_levels[0];
            debugPrint(">> Trying to match level: '{s}'\n", .{current_level});

            // 匹配单级通配符 "+"
            if (self.children.getPtr("+")) |child| {
                debugPrint(">> Found '+' wildcard\n", .{});
                try child.match(topic_levels[1..], matched_clients, allocator);
            }

            // 匹配多级通配符 "#"
            if (self.children.getPtr("#")) |child| {
                debugPrint(">> Found '#' wildcard, adding {} subscribers\n", .{child.subscribers.items.len});
                for (child.subscribers.items) |client| {
                    // 只添加仍然连接的客户端
                    if (client.is_connected) {
                        try matched_clients.append(allocator, client);
                    }
                }
            }

            // 精确匹配
            if (self.children.getPtr(current_level)) |child| {
                debugPrint(">> Found exact match for '{s}'\n", .{current_level});
                try child.match(topic_levels[1..], matched_clients, allocator);
            } else {
                debugPrint(">> No match found for '{s}'\n", .{current_level});
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

        fn printTree(self: *const Node, prefix: []const u8, level_name: []const u8) void {
            debugPrint("{s}['{s}'] subscribers: {}\n", .{ prefix, level_name, self.subscribers.items.len });

            var it = self.children.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const child = entry.value_ptr;

                // 创建新的前缀
                var new_prefix_buf: [256]u8 = undefined;
                const new_prefix = std.fmt.bufPrint(&new_prefix_buf, "{s}  ", .{prefix}) catch prefix;

                child.printTree(new_prefix, key);
            }
        }
    };

    root: Node,
    // 订阅缓存: 主题 -> 订阅者列表
    cache: std.StringHashMap(ArrayList(*Client)),
    cache_mutex: std.Thread.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SubscriptionTree {
        return SubscriptionTree{
            .root = Node.init(allocator),
            .cache = std.StringHashMap(ArrayList(*Client)).init(allocator),
            .cache_mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SubscriptionTree) void {
        // 清理缓存
        var cache_it = self.cache.iterator();
        while (cache_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.cache.deinit();

        self.root.deinit_deep(self.allocator);
    }
    pub fn subscribe(self: *SubscriptionTree, topic_filter: []const u8, client: *Client) !void {
        const topic_levels = try parseTopicLevels(topic_filter, self.root.children.allocator);
        debugPrint(">> subscribe() >> topic_levels: {any}\n", .{topic_levels});
        try self.root.subscribe(topic_levels, client);

        // 使订阅缓存失效
        self.invalidateCache(topic_filter);

        // 打印订阅树结构
        debugPrint("\n=== Subscription Tree After Subscribe ===\n", .{});
        self.root.printTree("", "ROOT");
        debugPrint("==========================================\n\n", .{});
    }

    pub fn unsubscribe(self: *SubscriptionTree, topic_filter: []const u8, client: *Client) !bool {
        const topic_levels = try parseTopicLevels(topic_filter, self.root.children.allocator);
        debugPrint(">> unsubscribe() >> topic_filter: '{s}', topic_levels: {any}\n", .{ topic_filter, topic_levels });

        const result = self.root.unsubscribe(topic_levels, client);

        if (result) {
            // 使订阅缓存失效
            self.invalidateCache(topic_filter);

            // 打印订阅树结构
            debugPrint("\n=== Subscription Tree After Unsubscribe ===\n", .{});
            self.root.printTree("", "ROOT");
            debugPrint("============================================\n\n", .{});
        }

        return result;
    }

    /// 移除客户端的所有订阅（客户端断开连接时调用，使用 MQTT 客户端 ID）
    pub fn removeClientAllSubscriptions(self: *SubscriptionTree, client_identifer: []const u8) void {
        debugPrint(">> removeClientAllSubscriptions() >> client_identifer: '{s}'\n", .{client_identifer});

        self.root.removeClient(client_identifer);

        // 清空整个缓存，因为订阅关系改变了
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        var cache_it = self.cache.iterator();
        while (cache_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.clearRetainingCapacity();

        debugPrint(">> All subscriptions and cache cleared for client '{s}'\n", .{client_identifer});
    }

    /// 使缓存失效
    fn invalidateCache(self: *SubscriptionTree, topic: []const u8) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        // 策略1: 尝试精确清除指定主题的缓存
        if (self.cache.fetchRemove(topic)) |entry| {
            debugPrint(">> Invalidating cache for exact topic: '{s}'\n", .{topic});
            var list = entry.value;
            list.deinit(self.allocator);
            self.allocator.free(entry.key);
        }

        // 策略2: 如果主题包含通配符，清空整个缓存（因为可能影响多个缓存条目）
        if (std.mem.indexOf(u8, topic, "+") != null or std.mem.indexOf(u8, topic, "#") != null) {
            debugPrint(">> Topic contains wildcards, clearing entire cache\n", .{});
            var cache_it = self.cache.iterator();
            while (cache_it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            self.cache.clearRetainingCapacity();
        }
    }

    pub fn printTree(self: *const SubscriptionTree) void {
        debugPrint("\n=== Current Subscription Tree ===\n", .{});
        self.root.printTree("", "ROOT");
        debugPrint("=================================\n\n", .{});
    }

    pub fn match(self: *SubscriptionTree, topic: []const u8, allocator: *Allocator) !ArrayList(*Client) {
        // 尝试从缓存获取
        self.cache_mutex.lock();
        if (self.cache.get(topic)) |cached| {
            // 缓存命中 - 复制列表返回
            var result: ArrayList(*Client) = .{};
            for (cached.items) |client| {
                try result.append(allocator.*, client);
            }
            self.cache_mutex.unlock();

            if (config.ENABLE_VERBOSE_LOGGING) {
                debugPrint(">> match() >> Cache HIT for '{s}': {} clients\n", .{ topic, result.items.len });
            }
            return result;
        }
        self.cache_mutex.unlock();

        // 缓存未命中 - 执行实际匹配
        if (config.ENABLE_VERBOSE_LOGGING) {
            debugPrint(">> match() >> Cache MISS for '{s}'\n", .{topic});
        }

        var matched_clients: ArrayList(*Client) = .{};
        const topic_levels = try parseTopicLevels(topic, self.root.children.allocator);
        debugPrint(">> match() >> topic_levels for '{s}': {any}\n", .{ topic, topic_levels });

        // 打印当前订阅树结构
        debugPrint("\n=== Subscription Tree Before Match ===\n", .{});
        self.root.printTree("", "ROOT");
        debugPrint("======================================\n\n", .{});

        try self.root.match(topic_levels, &matched_clients, allocator.*);
        debugPrint(">> match() >> matched {} clients\n", .{matched_clients.items.len});

        // 将结果加入缓存
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        var cached_list: ArrayList(*Client) = .{};
        for (matched_clients.items) |client| {
            try cached_list.append(self.allocator, client);
        }

        // 复制主题字符串
        const topic_copy = try self.allocator.dupe(u8, topic);
        try self.cache.put(topic_copy, cached_list);

        return matched_clients;
    }

    fn parseTopicLevels(topic: []const u8, allocator: Allocator) ![][]const u8 {
        var topic_levels: ArrayList([]const u8) = .{};

        var iterator = std.mem.splitSequence(u8, topic, "/");
        while (iterator.next()) |level| {
            // 复制每个层级的字符串,避免引用临时内存
            const level_copy = try allocator.dupe(u8, level);
            try topic_levels.append(allocator, level_copy);
        }

        return topic_levels.toOwnedSlice(allocator);
    }
};
