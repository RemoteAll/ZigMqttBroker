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
            if (topic_levels.len == 0) {
                try self.subscribers.append(self.children.allocator, client);
                return;
            }

            const child = try self.children.getOrPut(topic_levels[0]);
            if (!child.found_existing) {
                child.value_ptr.* = Node{
                    .children = std.StringHashMap(Node).init(self.children.allocator),
                    .subscribers = .{},
                };
            }
            try child.value_ptr.subscribe(topic_levels[1..], client);
        }

        pub fn match(self: *Node, topic_levels: [][]const u8, matched_clients: *ArrayList(*Client)) !void {
            if (topic_levels.len == 0) {
                for (self.subscribers.items) |client| {
                    try matched_clients.append(client);
                }
                return;
            }

            if (self.children.get(topic_levels[0])) |child| {
                try child.match(topic_levels[1..], matched_clients);
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
        try self.root.subscribe(topic_levels, client);
    }

    pub fn match(self: *SubscriptionTree, topic: []const u8, allocator: *Allocator) !ArrayList(*Client) {
        var matched_clients: ArrayList(*Client) = .{ .allocator = allocator.* };
        const topic_levels = try parseTopicLevels(topic, self.root.children.allocator);
        try self.root.match(topic_levels, &matched_clients);
        return matched_clients;
    }

    fn parseTopicLevels(topic: []const u8, allocator: Allocator) ![][]const u8 {
        var topic_levels: ArrayList([]const u8) = .{};

        var iterator = std.mem.splitSequence(u8, topic, "/");
        while (iterator.next()) |level| {
            try topic_levels.append(allocator, level);
        }

        // var tokenizer = std.mem.tokenize(u8, topic, "/"){};

        // while (tokenizer.next()) |level| {
        //     try topic_levels.append(level);
        // }
        return topic_levels.toOwnedSlice(allocator);
    }
};
