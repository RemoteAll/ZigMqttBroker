const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const Client = @import("client.zig").Client;

/// 发送任务
pub const SendTask = struct {
    client: *Client,
    data: []const u8,

    pub fn execute(self: *SendTask) void {
        // 使用线程安全的写入
        self.client.safeWriteToStream(self.data) catch |err| {
            // ClientNotFound 表示客户端已断开，这是正常情况，不需要记录错误
            if (err != error.ClientNotFound) {
                std.log.err("❌ Failed to send to client {} ('{s}'): {any}", .{ self.client.id, self.client.identifer, err });
            } else {
                std.log.warn("⚠️  Client {} ('{s}') already disconnected, skipping send", .{ self.client.id, self.client.identifer });
            }
        };
    }
};

/// 发送工作线程池
pub const SendWorkerPool = struct {
    allocator: Allocator,
    workers: []std.Thread,
    task_queue: std.ArrayList(SendTask),
    queue_mutex: std.Thread.Mutex,
    queue_cond: std.Thread.Condition,
    is_running: bool,
    shutdown: bool,

    pub fn init(allocator: Allocator, worker_count: u32) !SendWorkerPool {
        const workers = try allocator.alloc(std.Thread, worker_count);

        return SendWorkerPool{
            .allocator = allocator,
            .workers = workers,
            .task_queue = .{},
            .queue_mutex = .{},
            .queue_cond = .{},
            .is_running = false,
            .shutdown = false,
        };
    }

    pub fn deinit(self: *SendWorkerPool) void {
        self.stop();
        self.allocator.free(self.workers);
        self.task_queue.deinit(self.allocator);
    }

    /// 启动工作线程
    pub fn start(self: *SendWorkerPool) !void {
        self.is_running = true;
        self.shutdown = false;

        for (self.workers, 0..) |*worker, i| {
            worker.* = try std.Thread.spawn(.{}, workerThread, .{ self, i });
        }
    }

    /// 停止工作线程
    pub fn stop(self: *SendWorkerPool) void {
        if (!self.is_running) return;

        self.shutdown = true;
        self.is_running = false;

        // 唤醒所有等待的线程
        self.queue_cond.broadcast();

        // 等待所有工作线程结束
        for (self.workers) |worker| {
            worker.join();
        }
    }

    /// 提交发送任务
    pub fn submit(self: *SendWorkerPool, client: *Client, data: []const u8) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.task_queue.append(self.allocator, SendTask{
            .client = client,
            .data = data,
        });

        // 唤醒一个等待的工作线程
        self.queue_cond.signal();
    }

    /// 批量提交发送任务
    pub fn submitBatch(self: *SendWorkerPool, clients: []const *Client, data: []const u8) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        for (clients) |client| {
            try self.task_queue.append(self.allocator, SendTask{
                .client = client,
                .data = data,
            });
        }

        // 唤醒所有工作线程处理批量任务
        self.queue_cond.broadcast();
    }

    /// 等待所有任务完成
    pub fn waitAll(self: *SendWorkerPool) void {
        while (true) {
            self.queue_mutex.lock();
            const queue_empty = self.task_queue.items.len == 0;
            self.queue_mutex.unlock();

            if (queue_empty) break;

            std.Thread.sleep(1_000_000); // 1ms
        }
    }

    /// 工作线程函数
    fn workerThread(self: *SendWorkerPool, worker_id: usize) void {
        _ = worker_id;

        while (self.is_running) {
            self.queue_mutex.lock();

            // 等待任务
            while (self.task_queue.items.len == 0 and !self.shutdown) {
                self.queue_cond.wait(&self.queue_mutex);
            }

            if (self.shutdown) {
                self.queue_mutex.unlock();
                break;
            }

            // 获取任务
            if (self.task_queue.items.len > 0) {
                const task = self.task_queue.items[0];
                _ = self.task_queue.orderedRemove(0);
                self.queue_mutex.unlock();

                // 执行任务
                var mutable_task = task;
                mutable_task.execute();
            } else {
                self.queue_mutex.unlock();
            }
        }
    }

    /// 获取队列大小
    pub fn queueSize(self: *SendWorkerPool) usize {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.task_queue.items.len;
    }
};
