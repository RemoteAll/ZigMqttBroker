const std = @import("std");
const config = @import("config.zig");
const packet = @import("packet.zig");
const mqtt = @import("mqtt.zig");
const connect = @import("handle_connect.zig");
const ConnectError = @import("handle_connect.zig").ConnectError;
const SubscriptionTree = @import("subscription.zig").SubscriptionTree;
const subscribe = @import("handle_subscribe.zig");
const net = std.net;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const windows = std.os.windows;

const Client = @import("client.zig").Client;
const IocpManager = @import("iocp.zig").IocpManager;
const IoContext = @import("iocp.zig").IoContext;

/// MQTT Broker with IOCP
const MqttBroker = struct {
    allocator: Allocator,
    clients: AutoHashMap(u64, *Client),
    clients_mutex: std.Thread.Mutex,
    next_client_id: u64,
    subscriptions: SubscriptionTree,
    subscriptions_mutex: std.Thread.Mutex,
    iocp: IocpManager,

    pub fn init(allocator: Allocator) !MqttBroker {
        // 创建 IOCP,使用 CPU 核心数作为工作线程数
        const cpu_count = try std.Thread.getCpuCount();
        const iocp = try IocpManager.init(allocator, @intCast(cpu_count));

        return MqttBroker{
            .allocator = allocator,
            .clients = AutoHashMap(u64, *Client).init(allocator),
            .clients_mutex = .{},
            .next_client_id = 1,
            .subscriptions = SubscriptionTree.init(allocator),
            .subscriptions_mutex = .{},
            .iocp = iocp,
        };
    }

    pub fn deinit(self: *MqttBroker) void {
        self.iocp.deinit();

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr.*;
            client.deinit();
        }
        self.clients.deinit();
        self.subscriptions.deinit();
    }

    pub fn start(self: *MqttBroker, port: u16) !void {
        if (config.ENABLE_VERBOSE_LOGGING) {
            std.log.info("==================================================", .{});
            std.log.info("🚀 MQTT Broker Starting (IOCP Mode)", .{});
            std.log.info("==================================================", .{});
        }

        const self_addr = try net.Address.resolveIp("0.0.0.0", port);
        var listener = try self_addr.listen(.{ .reuse_address = true });

        if (config.ENABLE_VERBOSE_LOGGING) {
            std.log.info("📡 Listening on port {}", .{port});
            std.log.info("==================================================\n", .{});
        }

        // 启动 IOCP 工作线程
        try self.iocp.start(handleClientData);

        // 主线程接受连接
        while (listener.accept()) |conn| {
            const client_id = self.getNextClientId();

            if (config.ENABLE_VERBOSE_LOGGING) {
                std.log.info("New client {} connected from {any}", .{ client_id, conn.address });
            }

            // 设置 TCP_NODELAY
            const enable: c_int = 1;
            _ = windows.ws2_32.setsockopt(conn.stream.handle, windows.ws2_32.IPPROTO.TCP, windows.ws2_32.TCP.NODELAY, @ptrCast(&enable), @sizeOf(c_int));

            const client = try Client.init(self.allocator, client_id, mqtt.ProtocolVersion.Invalid, conn.stream, conn.address);

            // 关联到 IOCP
            try self.iocp.associateSocket(@ptrCast(conn.stream.handle), client);

            // 投递第一个接收操作
            const ctx = try IoContext.init(self.allocator, .Receive, config.READ_BUFFER_SIZE);
            ctx.client = client;
            try self.iocp.postReceive(client, ctx);

            // 添加到客户端列表
            self.clients_mutex.lock();
            defer self.clients_mutex.unlock();
            try self.clients.put(client_id, client);
        } else |err| {
            std.log.err("Error accepting client connection: {any}", .{err});
        }
    }

    fn getNextClientId(self: *MqttBroker) u64 {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        const id = self.next_client_id;
        self.next_client_id += 1;
        return id;
    }

    /// 处理客户端数据 (由 IOCP 工作线程调用)
    fn handleClientData(client: *Client, data: []u8) !void {
        _ = client;
        _ = data;
        // TODO: 实现 MQTT 协议处理
        std.log.info("Received {} bytes from client {}", .{ data.len, client.id });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var broker = try MqttBroker.init(allocator);
    defer broker.deinit();

    try broker.start(config.PORT);
}
