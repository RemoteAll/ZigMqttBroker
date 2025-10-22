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

        pub fn match(self: *Node, topic_levels: [][]const u8, matched_clients: *ArrayList(*Client), allocator: Allocator) !void {
            if (topic_levels.len == 0) {
                for (self.subscribers.items) |client| {
                    try matched_clients.append(allocator, client);
                }
                return;
            }

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
        const topic_levels = try parseTopicLevels(topic, self.root.children.allocator);
        std.debug.print(">> subscribe() >> topic_levels: {any}\n", .{topic_levels});
        try self.root.subscribe(topic_levels, client, self.root.children.allocator);
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

        var iterator = std.mem.splitScalar(u8, topic, '/');
        while (iterator.next()) |level| {
            try topic_levels.append(allocator, level);
        }

        return topic_levels.toOwnedSlice(allocator);
    }
};
