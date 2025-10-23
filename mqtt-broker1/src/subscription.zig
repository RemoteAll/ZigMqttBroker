const std = @import("std");
const Client = @import("client.zig").Client;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const logger = @import("logger.zig");
const SubscriptionPersistence = @import("persistence.zig").SubscriptionPersistence;

/// 主题匹配缓存项
const CacheEntry = struct {
    clients: ArrayList(*Client),
    /// 缓存版本号,用于无锁失效检测
    version: usize,

    fn deinit(self: *CacheEntry, allocator: Allocator) void {
        self.clients.deinit(allocator);
    }
};

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
                // 检查是否已订阅（避免重复增加引用计数）
                for (self.subscribers.items) |existing_client| {
                    if (existing_client.id == client.id) {
                        std.debug.print(">> Client {s} already subscribed, skipping\n", .{client.identifer});
                        return; // 已订阅，不重复添加
                    }
                }

                // 新增订阅：增加引用计数
                _ = client.retain();
                try self.subscribers.append(allocator, client);
                return;
            }

            const current_level = topic_levels[0];
            std.debug.print(">> Node.subscribe() >> current_level: '{s}'\n", .{current_level});

            // 先尝试获取已存在的节点
            if (self.children.getPtr(current_level)) |child| {
                std.debug.print(">> Found existing node for '{s}'\n", .{current_level});
                try child.subscribe(topic_levels[1..], client, allocator);
            } else {
                // 节点不存在,创建新节点并复制键
                const key_copy = try self.children.allocator.dupe(u8, current_level);
                errdefer self.children.allocator.free(key_copy);

                const new_node = Node{
                    .children = std.StringHashMap(Node).init(self.children.allocator),
                    .subscribers = .{},
                };

                try self.children.put(key_copy, new_node);
                std.debug.print(">> Created new node for '{s}'\n", .{key_copy});

                // 递归订阅下一层
                const child_ptr = self.children.getPtr(key_copy).?;
                try child_ptr.subscribe(topic_levels[1..], client, allocator);
            }
        }

        pub fn unsubscribe(self: *Node, topic_levels: [][]const u8, client: *Client, allocator: Allocator) !bool {
            if (topic_levels.len == 0) {
                // 到达目标层级,移除该客户端并释放引用
                var found = false;
                var i: usize = 0;
                while (i < self.subscribers.items.len) {
                    if (self.subscribers.items[i].id == client.id) {
                        const removed_client = self.subscribers.swapRemove(i);

                        // 释放引用计数
                        const should_cleanup = removed_client.release();
                        if (should_cleanup) {
                            std.debug.print(">> Client {s} can be safely cleaned up (ref_count=0)\n", .{removed_client.identifer});
                            // 注意：这里不实际释放 Client 对象，因为它由 ClientConnection 的 Arena 管理
                            // 只是标记可以安全清理
                        }

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

        /// 从整个订阅树中移除指定客户端的所有订阅（递归）
        pub fn unsubscribeClientFromAll(self: *Node, client: *Client, allocator: Allocator) void {
            // 从当前节点移除该客户端并释放引用
            var i: usize = 0;
            while (i < self.subscribers.items.len) {
                if (self.subscribers.items[i].id == client.id) {
                    const removed_client = self.subscribers.swapRemove(i);

                    // 释放引用计数
                    _ = removed_client.release();

                    continue;
                }
                i += 1;
            }

            // 递归处理所有子节点
            var it = self.children.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.unsubscribeClientFromAll(client, allocator);
            }
        }

        pub fn match(self: *Node, topic_levels: [][]const u8, matched_clients: *ArrayList(*Client), allocator: Allocator) !void {
            std.debug.print(">> Node.match() >> topic_levels.len={d}, subscribers.len={d}\n", .{ topic_levels.len, self.subscribers.items.len });

            // 如果没有更多层级，收集当前节点的订阅者
            if (topic_levels.len == 0) {
                std.debug.print(">> Reached end of topic, adding {d} subscribers\n", .{self.subscribers.items.len});
                for (self.subscribers.items) |client| {
                    try matched_clients.append(allocator, client);
                }
                return;
            }

            const current_level = topic_levels[0];
            std.debug.print(">> Matching level: '{s}'\n", .{current_level});

            // 1. 处理多级通配符 '#' (匹配所有剩余层级)
            if (self.children.getPtr("#")) |wildcard_child| {
                std.debug.print(">> Found '#' wildcard, adding {d} subscribers\n", .{wildcard_child.subscribers.items.len});
                // '#' 匹配当前层级和所有子层级，直接收集订阅者
                for (wildcard_child.subscribers.items) |client| {
                    try matched_clients.append(allocator, client);
                }
            }

            // 2. 处理单级通配符 '+' (只匹配当前层级)
            if (self.children.getPtr("+")) |plus_child| {
                std.debug.print(">> Found '+' wildcard\n", .{});
                try plus_child.match(topic_levels[1..], matched_clients, allocator);
            }

            // 3. 精确匹配当前层级
            if (self.children.getPtr(current_level)) |child| {
                std.debug.print(">> Found exact match for '{s}'\n", .{current_level});
                try child.match(topic_levels[1..], matched_clients, allocator);
            } else {
                std.debug.print(">> No match found for '{s}'\n", .{current_level});
            }
        }

        /// 递归检查主题树中是否存在指定客户端的订阅
        /// 用于重连优化：避免重复从文件恢复已在树中的订阅
        fn hasClientSubscriptionsRecursive(self: *const Node, client_id: []const u8) bool {
            // 检查当前节点的订阅者列表
            for (self.subscribers.items) |client| {
                if (std.mem.eql(u8, client.identifer, client_id)) {
                    return true;
                }
            }

            // 递归检查所有子节点
            var it = self.children.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.hasClientSubscriptionsRecursive(client_id)) {
                    return true;
                }
            }

            return false;
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
    /// 主题匹配缓存: topic -> 匹配的客户端列表
    match_cache: std.StringHashMap(CacheEntry),
    /// 缓存版本号,每次订阅变更时递增(原子操作,无锁)
    cache_version: std.atomic.Value(usize),
    /// 缓存读写锁(读多写少场景优化)
    cache_rwlock: std.Thread.RwLock,
    /// 缓存统计(原子操作,无锁)
    cache_hits: std.atomic.Value(usize),
    cache_misses: std.atomic.Value(usize),
    /// 订阅持久化管理器
    persistence: ?*SubscriptionPersistence,

    pub fn init(allocator: Allocator) SubscriptionTree {
        return SubscriptionTree{
            .root = Node.init(allocator),
            .match_cache = std.StringHashMap(CacheEntry).init(allocator),
            .cache_version = std.atomic.Value(usize).init(0),
            .cache_rwlock = .{},
            .cache_hits = std.atomic.Value(usize).init(0),
            .cache_misses = std.atomic.Value(usize).init(0),
            .persistence = null,
        };
    }

    /// 设置持久化管理器
    pub fn setPersistence(self: *SubscriptionTree, persistence: *SubscriptionPersistence) void {
        self.persistence = persistence;
    }

    pub fn deinit(self: *SubscriptionTree) void {
        self.root.deinit_deep(self.root.children.allocator);

        // 清理缓存
        var it = self.match_cache.iterator();
        while (it.next()) |entry| {
            var cache_entry = entry.value_ptr;
            cache_entry.deinit(self.match_cache.allocator);
        }
        self.match_cache.deinit();
    }

    /// 增加缓存版本号(订阅变更时调用)
    fn bumpCacheVersion(self: *SubscriptionTree) void {
        _ = self.cache_version.fetchAdd(1, .monotonic);
        std.debug.print(">> Cache version bumped to {d}\n", .{self.cache_version.load(.monotonic)});
    }

    /// 清除过期缓存项(按需清理,避免全量清理)
    fn cleanStaleCache(self: *SubscriptionTree) void {
        self.cache_rwlock.lock();
        defer self.cache_rwlock.unlock();

        const current_version = self.cache_version.load(.monotonic);
        var to_remove = ArrayList([]const u8).init(self.match_cache.allocator);
        defer to_remove.deinit();

        var it = self.match_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.version < current_version) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.match_cache.fetchRemove(key)) |removed| {
                var cache_entry = removed.value;
                cache_entry.deinit(self.match_cache.allocator);
            }
        }

        if (to_remove.items.len > 0) {
            std.debug.print(">> Cleaned {d} stale cache entries\n", .{to_remove.items.len});
        }
    }

    pub fn subscribe(self: *SubscriptionTree, topic: []const u8, client: *Client) !void {
        // 验证主题过滤器格式
        try validateTopicFilter(topic);

        const allocator = self.root.children.allocator;

        // 解析主题层级(不需要 dupe,因为 getOrPut 会复制键)
        var topic_levels: ArrayList([]const u8) = .{};
        defer topic_levels.deinit(allocator);

        var iterator = std.mem.splitScalar(u8, topic, '/');
        while (iterator.next()) |level| {
            try topic_levels.append(allocator, level);
        }

        std.debug.print(">> subscribe() >> topic: '{s}', topic_levels: {any}\n", .{ topic, topic_levels.items });
        try self.root.subscribe(topic_levels.items, client, allocator);

        // 订阅关系改变,增加版本号(缓存延迟失效)
        self.bumpCacheVersion();

        // 持久化订阅(异步,不阻塞主流程)
        if (self.persistence) |persistence| {
            const subscription = Client.Subscription{
                .topic_filter = topic,
                .qos = .AtMostOnce, // 默认 QoS 0,后续可从参数传入
                .no_local = false,
                .retain_as_published = false,
                .retain_handling = .SendRetained,
                .subscription_identifier = null,
            };
            persistence.addSubscription(client.identifer, subscription) catch |err| {
                logger.err("Failed to persist subscription for client '{s}': {any}", .{ client.identifer, err });
            };
        }
    }

    pub fn unsubscribe(self: *SubscriptionTree, topic: []const u8, client: *Client) !bool {
        // 验证主题过滤器格式
        try validateTopicFilter(topic);

        const allocator = self.root.children.allocator;
        const topic_levels = try parseTopicLevels(topic, allocator);
        defer allocator.free(topic_levels); // 释放 parseTopicLevels 分配的内存

        std.debug.print(">> unsubscribe() >> topic_levels: {any}\n", .{topic_levels});
        const result = try self.root.unsubscribe(topic_levels, client, allocator);

        // 取消订阅成功,增加版本号(缓存延迟失效)
        if (result) {
            self.bumpCacheVersion();

            // 持久化取消订阅
            if (self.persistence) |persistence| {
                persistence.removeSubscription(client.identifer, topic) catch |err| {
                    logger.err("Failed to persist unsubscription for client '{s}': {any}", .{ client.identifer, err });
                };
            }
        }

        return result;
    }

    /// 取消客户端的所有订阅（用于 Clean Session = 1 时清理会话）
    pub fn unsubscribeAll(self: *SubscriptionTree, client: *Client) void {
        const allocator = self.root.children.allocator;
        self.root.unsubscribeClientFromAll(client, allocator);

        // 订阅关系改变,增加版本号(缓存延迟失效)
        self.bumpCacheVersion();

        // 持久化清理
        if (self.persistence) |persistence| {
            persistence.removeAllSubscriptions(client.identifer) catch |err| {
                logger.err("Failed to persist unsubscribe all for client '{s}': {any}", .{ client.identifer, err });
            };
        }

        logger.info("Unsubscribed all topics for client {s}", .{client.identifer});
    }

    /// 恢复客户端的订阅(用于重连时从持久化存储恢复)
    /// 检查主题树中是否存在指定客户端的订阅
    /// 用于重连时判断是否需要从文件恢复订阅
    /// 注意：此方法不加锁,调用者需要确保线程安全
    pub fn hasClientSubscriptions(self: *SubscriptionTree, client_id: []const u8) bool {
        return self.root.hasClientSubscriptionsRecursive(client_id);
    }

    pub fn restoreClientSubscriptions(self: *SubscriptionTree, client: *Client) !void {
        if (self.persistence) |persistence| {
            const allocator = self.root.children.allocator;

            // 优化：先检查主题树中是否已有订阅
            // 如果主题树中已有该客户端的订阅(例如旧连接未正确断开),则无需从文件恢复
            if (self.hasClientSubscriptions(client.identifer)) {
                logger.info("Client '{s}' already has subscriptions in topic tree, skipping restore from file", .{client.identifer});
                return;
            }

            // 从持久化存储获取订阅
            var subscriptions_opt = try persistence.getClientSubscriptions(client.identifer, allocator);
            if (subscriptions_opt) |*subscriptions| {
                defer {
                    for (subscriptions.items) |sub| {
                        allocator.free(sub.topic_filter);
                    }
                    subscriptions.deinit(allocator);
                }

                // 恢复每个订阅到主题树
                for (subscriptions.items) |sub| {
                    try self.subscribe(sub.topic_filter, client);

                    // 同时恢复到客户端的订阅列表
                    try client.addSubscription(sub);

                    logger.info("Restored subscription for client '{s}' to topic '{s}'", .{ client.identifer, sub.topic_filter });
                }

                logger.info("Restored {d} subscription(s) for client '{s}'", .{ subscriptions.items.len, client.identifer });
            } else {
                logger.debug("No persisted subscriptions found for client '{s}'", .{client.identifer});
            }
        }
    }

    /// 匹配订阅的客户端,支持去重、no_local 过滤和高性能缓存
    /// publisher_client_id: 发布消息的客户端 ID (MQTT 客户端标识符)
    pub fn match(self: *SubscriptionTree, topic: []const u8, publisher_client_id: ?[]const u8, allocator: *Allocator) !ArrayList(*Client) {
        const current_version = self.cache_version.load(.monotonic);

        // 总是尝试从缓存获取(no_local 后处理)
        self.cache_rwlock.lockShared();
        const cached_opt = self.match_cache.get(topic);

        if (cached_opt) |cached| {
            // 检查缓存版本是否有效
            if (cached.version == current_version) {
                _ = self.cache_hits.fetchAdd(1, .monotonic);
                self.cache_rwlock.unlockShared();

                const hits = self.cache_hits.load(.monotonic);
                const misses = self.cache_misses.load(.monotonic);
                logger.info(">> 📌 Cache HIT for topic: '{s}' (hits: {d}, misses: {d})", .{ topic, hits, misses });

                // 返回缓存的副本,过滤已断开的客户端和 no_local
                var result: ArrayList(*Client) = .{};
                for (cached.clients.items) |client| {
                    if (!client.is_connected) continue;

                    // no_local 过滤
                    if (publisher_client_id) |pub_id| {
                        if (std.mem.eql(u8, client.identifer, pub_id) and client.hasNoLocal(topic)) {
                            continue;
                        }
                    }

                    try result.append(allocator.*, client);
                }
                return result;
            }
        }
        self.cache_rwlock.unlockShared();

        _ = self.cache_misses.fetchAdd(1, .monotonic);
        const hits = self.cache_hits.load(.monotonic);
        const misses = self.cache_misses.load(.monotonic);
        logger.info(">> ❌ Cache MISS for topic: '{s}' (hits: {d}, misses: {d})", .{ topic, hits, misses });

        var matched_clients: ArrayList(*Client) = .{};

        // 解析主题层级(临时使用,不需要 dupe)
        var topic_levels: ArrayList([]const u8) = .{};
        defer topic_levels.deinit(self.root.children.allocator);

        var iterator = std.mem.splitScalar(u8, topic, '/');
        while (iterator.next()) |level| {
            try topic_levels.append(self.root.children.allocator, level);
        }

        std.debug.print(">> match() >> topic: '{s}', topic_levels: {any}\n", .{ topic, topic_levels.items });

        try self.root.match(topic_levels.items, &matched_clients, allocator.*);

        std.debug.print(">> match() >> found {} potential clients before deduplication\n", .{matched_clients.items.len});

        // 去重:使用 StringHashMap 追踪已添加的客户端 (按 MQTT 客户端 ID)
        var seen = std.StringHashMap(void).init(allocator.*);
        defer seen.deinit();

        var deduplicated: ArrayList(*Client) = .{};
        for (matched_clients.items) |client| {
            // 跳过已断开连接的客户端
            if (!client.is_connected) continue;

            // 跳过自己发布的消息 (no_local 支持)
            if (publisher_client_id) |pub_id| {
                if (std.mem.eql(u8, client.identifer, pub_id) and client.hasNoLocal(topic)) {
                    std.debug.print(">> Skipping publisher '{s}' due to no_local\n", .{client.identifer});
                    continue;
                }
            }

            // 去重检查
            const result = try seen.getOrPut(client.identifer);
            if (!result.found_existing) {
                try deduplicated.append(allocator.*, client);
                std.debug.print(">> Added subscriber: '{s}'\n", .{client.identifer});
            } else {
                std.debug.print(">> Skipped duplicate: '{s}'\n", .{client.identifer});
            }
        }

        matched_clients.deinit(allocator.*);

        // 总是将结果放入缓存(提高命中率,no_local 后处理)
        if (deduplicated.items.len > 0) {
            self.cache_rwlock.lock();
            defer self.cache_rwlock.unlock();

            // 复制结果到缓存
            var cached_clients: ArrayList(*Client) = .{};
            for (deduplicated.items) |client| {
                try cached_clients.append(self.match_cache.allocator, client);
            }

            const topic_copy = try self.match_cache.allocator.dupe(u8, topic);
            errdefer self.match_cache.allocator.free(topic_copy);

            const cache_entry = CacheEntry{
                .clients = cached_clients,
                .version = current_version,
            };

            try self.match_cache.put(topic_copy, cache_entry);
            std.debug.print(">> Cached result for topic: '{s}' ({d} clients, version: {d})\n", .{ topic, deduplicated.items.len, current_version });
        }

        return deduplicated;
    }

    /// 获取缓存统计信息
    pub fn getCacheStats(self: *SubscriptionTree) struct { hits: usize, misses: usize, size: usize, version: usize } {
        self.cache_rwlock.lockShared();
        defer self.cache_rwlock.unlockShared();

        return .{
            .hits = self.cache_hits.load(.monotonic),
            .misses = self.cache_misses.load(.monotonic),
            .size = self.match_cache.count(),
            .version = self.cache_version.load(.monotonic),
        };
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
