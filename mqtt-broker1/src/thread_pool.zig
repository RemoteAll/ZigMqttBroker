const std = @import("std");
const Allocator = std.mem.Allocator;

/// 通用线程池实现，支持任意上下文类型
pub fn ThreadPool(comptime Context: type) type {
    return struct {
        const Self = @This();

        const Task = struct {
            handler: *const fn (Context) void,
            context: Context,
        };

        allocator: Allocator,
        threads: []std.Thread,
        task_queue: std.ArrayList(Task),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        shutdown: std.atomic.Value(bool),
        active_tasks: std.atomic.Value(u32),

        /// 初始化线程池
        /// thread_count: 工作线程数量，建议为 CPU 核心数的 1-2 倍
        pub fn init(allocator: Allocator, thread_count: u32) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = Self{
                .allocator = allocator,
                .threads = try allocator.alloc(std.Thread, thread_count),
                .task_queue = .{}, // Zig 0.15.2+ ArrayList 初始化
                .mutex = .{},
                .condition = .{},
                .shutdown = std.atomic.Value(bool).init(false),
                .active_tasks = std.atomic.Value(u32).init(0),
            };

            // 创建工作线程
            for (self.threads, 0..) |*thread, i| {
                thread.* = try std.Thread.spawn(.{}, workerThread, .{self});
                errdefer {
                    // 如果创建失败，清理已创建的线程
                    self.shutdown.store(true, .release);
                    self.condition.broadcast();
                    for (self.threads[0..i]) |t| {
                        t.join();
                    }
                }
            }

            return self;
        }

        /// 清理线程池
        pub fn deinit(self: *Self) void {
            // 通知所有线程关闭
            self.shutdown.store(true, .release);

            // 唤醒所有等待的线程
            self.mutex.lock();
            self.condition.broadcast();
            self.mutex.unlock();

            // 等待所有线程结束
            for (self.threads) |thread| {
                thread.join();
            }

            self.allocator.free(self.threads);
            self.task_queue.deinit(self.allocator); // Zig 0.15.2+ 需要传入 allocator
            self.allocator.destroy(self);
        }

        /// 提交任务到线程池
        pub fn submit(self: *Self, handler: *const fn (Context) void, context: Context) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.task_queue.append(self.allocator, Task{
                .handler = handler,
                .context = context,
            });

            // 唤醒一个等待的线程
            self.condition.signal();
        }

        /// 批量提交任务（减少锁竞争）
        pub fn submitBatch(self: *Self, handler: *const fn (Context) void, contexts: []const Context) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // 将上下文转换为任务
            for (contexts) |ctx| {
                try self.task_queue.append(self.allocator, Task{
                    .handler = handler,
                    .context = ctx,
                });
            }

            // 唤醒所有线程（有多个任务可用）
            self.condition.broadcast();
        }

        /// 获取当前活跃任务数
        pub fn getActiveTaskCount(self: *Self) u32 {
            return self.active_tasks.load(.acquire);
        }

        /// 获取队列中等待的任务数
        pub fn getPendingTaskCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.task_queue.items.len;
        }

        /// 工作线程函数
        fn workerThread(self: *Self) void {
            while (true) {
                // 获取任务
                self.mutex.lock();

                // 等待任务或关闭信号
                while (self.task_queue.items.len == 0 and !self.shutdown.load(.acquire)) {
                    self.condition.wait(&self.mutex);
                }

                // 检查关闭信号
                if (self.shutdown.load(.acquire)) {
                    self.mutex.unlock();
                    break;
                }

                // 取出任务
                const task = self.task_queue.orderedRemove(0);
                self.mutex.unlock();

                // 执行任务（不持有锁）
                _ = self.active_tasks.fetchAdd(1, .monotonic);
                task.handler(task.context);
                _ = self.active_tasks.fetchSub(1, .monotonic);
            }
        }
    };
}

// 测试
test "ThreadPool basic" {
    const Context = struct {
        value: *std.atomic.Value(i32),
    };

    var counter = std.atomic.Value(i32).init(0);
    var pool = try ThreadPool(Context).init(std.testing.allocator, 4);
    defer pool.deinit();

    const increment = struct {
        fn call(ctx: Context) void {
            _ = ctx.value.fetchAdd(1, .monotonic);
        }
    }.call;

    // 提交 100 个任务
    for (0..100) |_| {
        try pool.submit(increment, Context{ .value = &counter });
    }

    // 等待一段时间让任务完成
    std.time.sleep(100 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(i32, 100), counter.load(.monotonic));
}

test "ThreadPool batch submit" {
    const Context = struct {
        value: *std.atomic.Value(i32),
        amount: i32,
    };

    const Task = ThreadPool(Context).Task;

    var counter = std.atomic.Value(i32).init(0);
    var pool = try ThreadPool(Context).init(std.testing.allocator, 4);
    defer pool.deinit();

    const add = struct {
        fn call(ctx: Context) void {
            _ = ctx.value.fetchAdd(ctx.amount, .monotonic);
        }
    }.call;

    // 批量提交任务
    var tasks: [10]Task = undefined;
    for (&tasks, 0..) |*task, i| {
        task.* = Task{
            .handler = add,
            .context = Context{ .value = &counter, .amount = @intCast(i + 1) },
        };
    }

    try pool.submitBatch(&tasks);

    // 等待任务完成
    std.time.sleep(100 * std.time.ns_per_ms);

    // 1+2+3+...+10 = 55
    try std.testing.expectEqual(@as(i32, 55), counter.load(.monotonic));
}
