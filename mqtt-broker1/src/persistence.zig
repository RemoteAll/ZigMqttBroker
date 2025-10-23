const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const logger = @import("logger.zig");
const Client = @import("client.zig").Client;
const QoS = @import("mqtt.zig").QoS;

/// 订阅持久化数据结构
pub const PersistedSubscription = struct {
    client_identifier: []const u8,
    topic_filter: []const u8,
    qos: QoS,
    no_local: bool,
    retain_as_published: bool,
    retain_handling: u2,
    subscription_identifier: ?u32,

    pub fn fromClientSubscription(client_id: []const u8, sub: Client.Subscription, allocator: Allocator) !PersistedSubscription {
        return PersistedSubscription{
            .client_identifier = try allocator.dupe(u8, client_id),
            .topic_filter = try allocator.dupe(u8, sub.topic_filter),
            .qos = sub.qos,
            .no_local = sub.no_local,
            .retain_as_published = sub.retain_as_published,
            .retain_handling = @intFromEnum(sub.retain_handling),
            .subscription_identifier = sub.subscription_identifier,
        };
    }

    pub fn toClientSubscription(self: *const PersistedSubscription, allocator: Allocator) !Client.Subscription {
        return Client.Subscription{
            .topic_filter = try allocator.dupe(u8, self.topic_filter),
            .qos = self.qos,
            .no_local = self.no_local,
            .retain_as_published = self.retain_as_published,
            .retain_handling = @enumFromInt(self.retain_handling),
            .subscription_identifier = self.subscription_identifier,
        };
    }

    pub fn deinit(self: *PersistedSubscription, allocator: Allocator) void {
        allocator.free(self.client_identifier);
        allocator.free(self.topic_filter);
    }
};

/// 订阅持久化管理器
pub const SubscriptionPersistence = struct {
    allocator: Allocator,
    file_path: []const u8,
    subscriptions: std.StringHashMap(ArrayList(PersistedSubscription)),
    /// 读写锁,保护持久化数据的并发访问
    lock: std.Thread.RwLock,

    pub fn init(allocator: Allocator, file_path: []const u8) !SubscriptionPersistence {
        return SubscriptionPersistence{
            .allocator = allocator,
            .file_path = try allocator.dupe(u8, file_path),
            .subscriptions = std.StringHashMap(ArrayList(PersistedSubscription)).init(allocator),
            .lock = .{},
        };
    }

    pub fn deinit(self: *SubscriptionPersistence) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*sub| {
                sub.deinit(self.allocator);
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();
        self.allocator.free(self.file_path);
    }

    /// 保存客户端的订阅到持久化存储
    pub fn saveClientSubscriptions(self: *SubscriptionPersistence, client_id: []const u8, subscriptions: []const Client.Subscription) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // 复制客户端 ID
        const client_id_copy = try self.allocator.dupe(u8, client_id);
        errdefer self.allocator.free(client_id_copy);

        // 如果客户端已有订阅记录,先清理
        if (self.subscriptions.getPtr(client_id_copy)) |existing| {
            for (existing.items) |*sub| {
                sub.deinit(self.allocator);
            }
            existing.clearRetainingCapacity();
        }

        // 构建新的订阅列表
        var persisted_subs: ArrayList(PersistedSubscription) = .{};
        errdefer {
            for (persisted_subs.items) |*sub| {
                sub.deinit(self.allocator);
            }
            persisted_subs.deinit(self.allocator);
        }

        for (subscriptions) |sub| {
            const persisted = try PersistedSubscription.fromClientSubscription(client_id, sub, self.allocator);
            try persisted_subs.append(self.allocator, persisted);
        }

        // 存储订阅
        try self.subscriptions.put(client_id_copy, persisted_subs);

        // 保存到文件
        try self.saveToFile();

        logger.info("Persisted {d} subscription(s) for client '{s}'", .{ subscriptions.len, client_id });
    }

    /// 添加单个订阅到持久化存储
    pub fn addSubscription(self: *SubscriptionPersistence, client_id: []const u8, subscription: Client.Subscription) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // 获取或创建客户端的订阅列表
        const result = try self.subscriptions.getOrPut(client_id);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, client_id);
            result.value_ptr.* = .{};
        }

        // 检查是否已存在相同主题的订阅,如果存在则更新
        for (result.value_ptr.items, 0..) |*existing, i| {
            if (std.mem.eql(u8, existing.topic_filter, subscription.topic_filter)) {
                // 释放旧的订阅数据
                existing.deinit(self.allocator);
                // 更新为新的订阅
                result.value_ptr.items[i] = try PersistedSubscription.fromClientSubscription(client_id, subscription, self.allocator);
                try self.saveToFile();
                logger.info("Updated subscription for client '{s}' to topic '{s}'", .{ client_id, subscription.topic_filter });
                return;
            }
        }

        // 添加新订阅
        const persisted = try PersistedSubscription.fromClientSubscription(client_id, subscription, self.allocator);
        try result.value_ptr.append(self.allocator, persisted);

        // 保存到文件
        try self.saveToFile();

        logger.info("Added subscription for client '{s}' to topic '{s}'", .{ client_id, subscription.topic_filter });
    }

    /// 移除客户端的特定订阅
    pub fn removeSubscription(self: *SubscriptionPersistence, client_id: []const u8, topic_filter: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.subscriptions.getPtr(client_id)) |subs| {
            var i: usize = 0;
            while (i < subs.items.len) {
                if (std.mem.eql(u8, subs.items[i].topic_filter, topic_filter)) {
                    var removed = subs.swapRemove(i);
                    removed.deinit(self.allocator);
                    try self.saveToFile();
                    logger.info("Removed subscription for client '{s}' from topic '{s}'", .{ client_id, topic_filter });
                    return;
                }
                i += 1;
            }
        }
    }

    /// 移除客户端的所有订阅
    pub fn removeAllSubscriptions(self: *SubscriptionPersistence, client_id: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.subscriptions.fetchRemove(client_id)) |entry| {
            for (entry.value.items) |*sub| {
                sub.deinit(self.allocator);
            }
            var value = entry.value;
            value.deinit(self.allocator);
            self.allocator.free(entry.key);
            try self.saveToFile();
            logger.info("Removed all subscriptions for client '{s}'", .{client_id});
        }
    }

    /// 获取客户端的订阅列表
    pub fn getClientSubscriptions(self: *SubscriptionPersistence, client_id: []const u8, allocator: Allocator) !?ArrayList(Client.Subscription) {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        if (self.subscriptions.get(client_id)) |persisted_subs| {
            var result: ArrayList(Client.Subscription) = .{};
            errdefer {
                for (result.items) |sub| {
                    allocator.free(sub.topic_filter);
                }
                result.deinit(allocator);
            }

            for (persisted_subs.items) |*persisted| {
                const sub = try persisted.toClientSubscription(allocator);
                try result.append(allocator, sub);
            }

            return result;
        }

        return null;
    }

    /// 保存所有订阅到文件(内部方法,调用者需持有锁)
    fn saveToFile(self: *SubscriptionPersistence) !void {
        // 创建父目录(如果不存在)
        if (std.fs.path.dirname(self.file_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                if (err != error.PathAlreadyExists) {
                    logger.err("Failed to create directory for persistence file: {any}", .{err});
                    return err;
                }
            };
        }

        // 构建 JSON 字符串
        var json: ArrayList(u8) = .{};
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\n");
        try json.appendSlice(self.allocator, "  \"subscriptions\": {\n");

        var it = self.subscriptions.iterator();
        var first_client = true;
        while (it.next()) |entry| {
            if (!first_client) {
                try json.appendSlice(self.allocator, ",\n");
            }
            first_client = false;

            // 客户端 ID
            try std.fmt.format(json.writer(self.allocator), "    \"{s}\": [\n", .{entry.key_ptr.*});

            // 订阅列表
            for (entry.value_ptr.items, 0..) |sub, i| {
                if (i > 0) {
                    try json.appendSlice(self.allocator, ",\n");
                }
                try json.appendSlice(self.allocator, "      {\n");
                try std.fmt.format(json.writer(self.allocator), "        \"topic_filter\": \"{s}\",\n", .{sub.topic_filter});
                try std.fmt.format(json.writer(self.allocator), "        \"qos\": {d},\n", .{@intFromEnum(sub.qos)});
                try std.fmt.format(json.writer(self.allocator), "        \"no_local\": {s},\n", .{if (sub.no_local) "true" else "false"});
                try std.fmt.format(json.writer(self.allocator), "        \"retain_as_published\": {s},\n", .{if (sub.retain_as_published) "true" else "false"});
                try std.fmt.format(json.writer(self.allocator), "        \"retain_handling\": {d}", .{sub.retain_handling});
                if (sub.subscription_identifier) |id| {
                    try std.fmt.format(json.writer(self.allocator), ",\n        \"subscription_identifier\": {d}\n", .{id});
                } else {
                    try json.appendSlice(self.allocator, "\n");
                }
                try json.appendSlice(self.allocator, "      }");
            }

            try json.appendSlice(self.allocator, "\n    ]");
        }

        try json.appendSlice(self.allocator, "\n  }\n");
        try json.appendSlice(self.allocator, "}\n");

        // 写入文件
        const file = try std.fs.cwd().createFile(self.file_path, .{});
        defer file.close();

        try file.writeAll(json.items);

        logger.debug("Saved subscriptions to '{s}'", .{self.file_path});
    }

    /// 从文件加载所有订阅
    pub fn loadFromFile(self: *SubscriptionPersistence) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // 尝试打开文件
        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                logger.info("No existing subscription persistence file found at '{s}'", .{self.file_path});
                return;
            }
            logger.err("Failed to open persistence file '{s}': {any}", .{ self.file_path, err });
            return err;
        };
        defer file.close();

        // 读取文件内容
        const file_size = try file.getEndPos();
        if (file_size == 0) {
            logger.info("Subscription persistence file is empty", .{});
            return;
        }

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 10); // 最大 10MB
        defer self.allocator.free(content);

        // 解析 JSON
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            content,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;
        const subscriptions_obj = root.get("subscriptions") orelse {
            logger.warn("Invalid persistence file format: missing 'subscriptions' field", .{});
            return;
        };

        if (subscriptions_obj != .object) {
            logger.warn("Invalid persistence file format: 'subscriptions' is not an object", .{});
            return;
        }

        // 清空现有订阅
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*sub| {
                sub.deinit(self.allocator);
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.clearRetainingCapacity();

        // 加载订阅数据
        var client_it = subscriptions_obj.object.iterator();
        while (client_it.next()) |client_entry| {
            const client_id = client_entry.key_ptr.*;
            const subs_array = client_entry.value_ptr.*;

            if (subs_array != .array) continue;

            const client_id_copy = try self.allocator.dupe(u8, client_id);
            errdefer self.allocator.free(client_id_copy);

            var persisted_subs: ArrayList(PersistedSubscription) = .{};
            errdefer {
                for (persisted_subs.items) |*sub| {
                    sub.deinit(self.allocator);
                }
                persisted_subs.deinit(self.allocator);
            }

            for (subs_array.array.items) |sub_value| {
                if (sub_value != .object) continue;

                const sub_obj = sub_value.object;
                const topic_filter = sub_obj.get("topic_filter").?.string;
                const qos_int = @as(u8, @intCast(sub_obj.get("qos").?.integer));
                const no_local = sub_obj.get("no_local").?.bool;
                const retain_as_published = sub_obj.get("retain_as_published").?.bool;
                const retain_handling = @as(u2, @intCast(sub_obj.get("retain_handling").?.integer));
                const subscription_identifier = if (sub_obj.get("subscription_identifier")) |id| @as(u32, @intCast(id.integer)) else null;

                const persisted = PersistedSubscription{
                    .client_identifier = try self.allocator.dupe(u8, client_id),
                    .topic_filter = try self.allocator.dupe(u8, topic_filter),
                    .qos = QoS.fromU8(qos_int) orelse .AtMostOnce,
                    .no_local = no_local,
                    .retain_as_published = retain_as_published,
                    .retain_handling = retain_handling,
                    .subscription_identifier = subscription_identifier,
                };

                try persisted_subs.append(self.allocator, persisted);
            }

            try self.subscriptions.put(client_id_copy, persisted_subs);
            logger.info("Loaded {d} subscription(s) for client '{s}'", .{ persisted_subs.items.len, client_id });
        }

        logger.info("Loaded subscriptions from '{s}'", .{self.file_path});
    }
};
