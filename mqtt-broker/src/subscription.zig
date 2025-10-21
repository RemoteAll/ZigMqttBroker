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

        pub fn subscribe(self: *Node, topic_levels: [][]const u8, client: *Client) !void {
            std.debug.print(">> Node.subscribe() >> topic_levels.len={}\n", .{topic_levels.len});

            if (topic_levels.len == 0) {
                std.debug.print(">> Adding client {} as subscriber (total: {})\n", .{ client.id, self.subscribers.items.len + 1 });
                try self.subscribers.append(self.children.allocator, client);
                return;
            }

            const current_level = topic_levels[0];
            std.debug.print(">> Creating/getting child node for level: '{s}'\n", .{current_level});

            const child = try self.children.getOrPut(current_level);
            if (!child.found_existing) {
                std.debug.print(">> Created new child node for '{s}'\n", .{current_level});
                child.value_ptr.* = Node{
                    .children = std.StringHashMap(Node).init(self.children.allocator),
                    .subscribers = .{},
                };
            } else {
                std.debug.print(">> Found existing child node for '{s}'\n", .{current_level});
            }
            try child.value_ptr.subscribe(topic_levels[1..], client);
        }

        pub fn match(self: *Node, topic_levels: [][]const u8, matched_clients: *ArrayList(*Client), allocator: Allocator) !void {
            std.debug.print(">> Node.match() >> topic_levels.len={}, subscribers.len={}\n", .{ topic_levels.len, self.subscribers.items.len });

            if (topic_levels.len == 0) {
                std.debug.print(">> Reached end of topic, adding {} subscribers\n", .{self.subscribers.items.len});
                for (self.subscribers.items) |client| {
                    try matched_clients.append(allocator, client);
                }
                return;
            }

            const current_level = topic_levels[0];
            std.debug.print(">> Trying to match level: '{s}'\n", .{current_level});

            // 匹配单级通配符 "+"
            if (self.children.getPtr("+")) |child| {
                std.debug.print(">> Found '+' wildcard\n", .{});
                try child.match(topic_levels[1..], matched_clients, allocator);
            }

            // 匹配多级通配符 "#"
            if (self.children.getPtr("#")) |child| {
                std.debug.print(">> Found '#' wildcard, adding {} subscribers\n", .{child.subscribers.items.len});
                for (child.subscribers.items) |client| {
                    try matched_clients.append(allocator, client);
                }
            }

            // 精确匹配
            if (self.children.getPtr(current_level)) |child| {
                std.debug.print(">> Found exact match for '{s}'\n", .{current_level});
                try child.match(topic_levels[1..], matched_clients, allocator);
            } else {
                std.debug.print(">> No match found for '{s}'\n", .{current_level});
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
            std.debug.print("{s}['{s}'] subscribers: {}\n", .{ prefix, level_name, self.subscribers.items.len });

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

    pub fn init(allocator: Allocator) SubscriptionTree {
        return SubscriptionTree{
            .root = Node.init(allocator),
        };
    }

    pub fn deinit(self: *SubscriptionTree) void {
        self.root.deinit_deep(self.root.children.allocator);
    }

    pub fn subscribe(self: *SubscriptionTree, topic: []const u8, client: *Client) !void {
        const topic_levels = try parseTopicLevels(topic, self.root.children.allocator);
        std.debug.print(">> subscribe() >> topic_levels: {any}\n", .{topic_levels});
        try self.root.subscribe(topic_levels, client);

        // 打印订阅树结构
        std.debug.print("\n=== Subscription Tree After Subscribe ===\n", .{});
        self.root.printTree("", "ROOT");
        std.debug.print("==========================================\n\n", .{});
    }

    pub fn printTree(self: *const SubscriptionTree) void {
        std.debug.print("\n=== Current Subscription Tree ===\n", .{});
        self.root.printTree("", "ROOT");
        std.debug.print("=================================\n\n", .{});
    }

    pub fn match(self: *SubscriptionTree, topic: []const u8, allocator: *Allocator) !ArrayList(*Client) {
        var matched_clients: ArrayList(*Client) = .{};
        const topic_levels = try parseTopicLevels(topic, self.root.children.allocator);
        std.debug.print(">> match() >> topic_levels for '{s}': {any}\n", .{ topic, topic_levels });

        // 打印当前订阅树结构
        std.debug.print("\n=== Subscription Tree Before Match ===\n", .{});
        self.root.printTree("", "ROOT");
        std.debug.print("======================================\n\n", .{});

        try self.root.match(topic_levels, &matched_clients, allocator.*);
        std.debug.print(">> match() >> matched {} clients\n", .{matched_clients.items.len});
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
