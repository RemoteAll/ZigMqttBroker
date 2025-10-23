const std = @import("std");
const Server = @import("server.zig");
const Trie = @import("ds/trie.zig");
const Messages = @import("messages.zig");
const config = @import("config.zig");
const MemoryPool = std.heap.MemoryPoolExtra;

const TopicPool = MemoryPool(Topic, .{.growable = false});

pub const TopicName = struct {
    name: [config.maximum_topic_name_length]u8,
    length: usize,

    pub fn toSlice(self: *const TopicName) []const u8 {
        return self.name[0..self.length];
    }
};

pub const Topic = struct {
    name: TopicName,
    subscribers: [config.maximum_topic_subscribers]Subscriber = undefined,
    subscribers_count: usize = 0,

    pub fn init(self: *Topic, name: []const u8) !void {
        @memcpy(self.name.name[0..name.len], name);
        self.name.length = name.len;
        self.subscribers_count = 0;
    }

    pub fn addSubscriber(self: *Topic, client: *MQTTClient, qos: u16, clean: bool) !void {
        if (self.subscribers_count + 1 >= self.subscribers.len) return error.SubscriptionLimitReached;
        self.subscribers[self.subscribers_count] = .{
            .client = client,
            .qos = qos,
        };
        self.subscribers_count += 1;

        if (!clean) {
            try client.addTopic(self);
        }
    }

    pub fn removeSubscriber(self: *Topic, client: *MQTTClient, clean: bool) !void {
        _ = clean;

        for (self.subscribers, 0..) |sub, idx| {
            if (CompareCid(&sub, &.{.client = client})) {
                self.subscribers[idx] = self.subscribers[self.subscribers_count - 1];
                self.subscribers_count -= 1;
                return;
            }
        }
    }
};

pub const Core = struct {
    clients: std.StringHashMap(*MQTTClient),
    topics: *Trie,
    allocator: std.mem.Allocator,
    topic_pool: TopicPool,

    pub fn init(allocator: std.mem.Allocator) !Core {
        var clients = std.StringHashMap(*MQTTClient).init(allocator);
        errdefer clients.deinit();

        try clients.ensureTotalCapacity(config.max_clients);

        var topic_pool = try TopicPool.initPreheated(allocator, config.maximum_topic_number);
        errdefer topic_pool.deinit();

        return Core{
            .clients = clients,
            .topics = try Trie.init(allocator),
            .allocator = allocator,
            .topic_pool = topic_pool,
        };
    }

    pub fn addClient(self: *Core, client: *MQTTClient) void {
        self.clients.putAssumeCapacity(&client.client_id, client);
    }

    pub fn removeClient(self: *Core, client: *MQTTClient) bool {
        return self.clients.remove(&client.client_id);
    }

    pub fn containsClient(self: *Core, client_id: []const u8) bool {
        return self.clients.contains(client_id);
    }

    pub fn createTopic(self: *Core, name: []const u8) !*Topic {
        const topic = try self.topic_pool.create();
        try topic.init(name);

        try self.addTopic(topic);
        return topic;
    }

    pub fn addTopic(self: *Core, topic: *Topic) !void {
        try self.topics.insert(topic.name.toSlice(), topic);
    }

    pub fn removeTopic(self: *Core, name: []const u8) void {
        _ = self.topics.delete(name);
    }

    pub fn getTopic(self: *Core, name: []const u8) !?*Topic {
        if (Trie.find(self.topics.root, name)) |topic_node| {
            return topic_node.data;
        } else {
            return error.TopicNotFound;
        }
    }
};

const Session = struct {
    subscriptions: [100]*Topic = undefined,
    subscriptions_count: usize = 0,
};

pub const MQTTClient = struct {
    client_id: [24]u8 = undefined,
    session: Session= .{},
    server_client: *Server.Client = undefined,

    pub fn addTopic(self: *MQTTClient, topic: *Topic) !void {
        if (self.session.subscriptions_count + 1 >= self.session.subscriptions.len) {
            return error.SubscriptionLimitReached;
        }

        self.session.subscriptions[self.session.subscriptions_count] = topic;
        self.session.subscriptions_count += 1;
    }

    pub fn removeTopic(self: *MQTTClient, index: usize) !void {
        std.debug.assert(self.session.subscriptions_count > 0);
        std.debug.assert(index < self.session.subscriptions_count);

        self.session.subscriptions[index] = self.session.subscriptions[self.session.subscriptions_count - 1];
        self.session.subscriptions_count -= 1;
    }
};

pub const Subscriber = struct {
    qos: u16,
    client: *MQTTClient,
};

pub fn CompareCid(a: *const Subscriber, b: *const Subscriber) bool {
    return std.mem.eql(u8, a.client.client_id, b.client.client_id);
}