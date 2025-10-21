const std = @import("std");
const Allocator = std.mem.Allocator;

/// 固定大小缓冲区池,用于复用读写缓冲区
pub const BufferPool = struct {
    pool: std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
    allocator: Allocator,
    buffer_size: usize,
    max_pooled: usize,

    pub fn init(allocator: Allocator, buffer_size: usize, max_pooled: usize) BufferPool {
        return BufferPool{
            .pool = .{},
            .mutex = .{},
            .allocator = allocator,
            .buffer_size = buffer_size,
            .max_pooled = max_pooled,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.pool.items) |buf| {
            self.allocator.free(buf);
        }
        self.pool.deinit(self.allocator);
    }

    /// 从池中获取缓冲区,如果池为空则分配新的
    pub fn acquire(self: *BufferPool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pool.items.len > 0) {
            const buf = self.pool.items[self.pool.items.len - 1];
            self.pool.items.len -= 1;
            return buf;
        }

        return try self.allocator.alloc(u8, self.buffer_size);
    }

    /// 将缓冲区归还到池中
    pub fn release(self: *BufferPool, buf: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 只缓存正确大小的缓冲区
        if (buf.len != self.buffer_size) {
            self.allocator.free(buf);
            return;
        }

        // 限制池大小,避免内存占用过多
        if (self.pool.items.len < self.max_pooled) {
            self.pool.append(self.allocator, buf) catch {
                self.allocator.free(buf);
            };
        } else {
            self.allocator.free(buf);
        }
    }

    /// 获取当前池中缓存的缓冲区数量
    pub fn pooledCount(self: *BufferPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pool.items.len;
    }
};
