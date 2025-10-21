# 性能优化实施方案

## 方案选择

考虑到:
1. 完整的 IOCP 重构工作量大(需要重写大部分核心逻辑)
2. Zig 0.15.2 的 Windows API 兼容性问题
3. 需要快速见效

我们采用 **渐进式优化** 策略:

## 第一阶段:优化当前 BIO 架构 (立即实施)

### 1. 内存池优化
**当前问题:** 每次读取都分配新缓冲区
**优化方案:** 使用对象池复用缓冲区

### 2. 批量写入优化 
**当前问题:** 多个订阅者逐个写入
**优化方案:** 使用 writev/WSASend 批量发送

### 3. 无锁优化
**当前问题:** 每次写入都获取 Mutex
**优化方案:** 使用每客户端发送队列+专用发送线程

### 4. 订阅树缓存
**当前问题:** 每次 PUBLISH 都匹配订阅树
**优化方案:** 缓存热点主题的订阅者列表

## 第二阶段:引入 IO 复用 (后续实施)

在第一阶段优化完成并验证后,再考虑完整的 IOCP/epoll 重构。

---

## 立即实施优化

### 优化 1: 缓冲区池

创建 `buffer_pool.zig`:
```zig
pub const BufferPool = struct {
    pool: std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
    allocator: Allocator,
    buffer_size: usize,
    
    pub fn acquire(self: *BufferPool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.pool.popOrNull() orelse
            try self.allocator.alloc(u8, self.buffer_size);
    }
    
    pub fn release(self: *BufferPool, buf: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.pool.items.len < 100) {  // 限制池大小
            self.pool.append(buf) catch {
                self.allocator.free(buf);
            };
        } else {
            self.allocator.free(buf);
        }
    }
};
```

### 优化 2: 发送队列

修改 `client.zig`,添加发送队列:
```zig
pub const Client = struct {
    // ... 现有字段 ...
    send_queue: std.ArrayList([]const u8),
    send_thread: ?std.Thread,
    queue_mutex: std.Thread.Mutex,
    queue_cond: std.Thread.Condition,
    
    fn sendWorker(self: *Client) void {
        while (self.is_connected) {
            self.queue_mutex.lock();
            
            while (self.send_queue.items.len == 0 and self.is_connected) {
                self.queue_cond.wait(&self.queue_mutex);
            }
            
            if (self.send_queue.items.len > 0) {
                // 批量发送所有待发送数据
                for (self.send_queue.items) |data| {
                    self.stream.write(data) catch {};
                }
                self.send_queue.clearRetainingCapacity();
            }
            
            self.queue_mutex.unlock();
        }
    }
    
    pub fn asyncSend(self: *Client, data: []const u8) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        
        try self.send_queue.append(data);
        self.queue_cond.signal();
    }
};
```

### 优化 3: 订阅缓存

修改 `subscription.zig`:
```zig
pub const SubscriptionTree = struct {
    root: Node,
    cache: std.StringHashMap(ArrayList(*Client)),
    cache_mutex: std.Thread.Mutex,
    
    pub fn match(self: *SubscriptionTree, topic: []const u8) !ArrayList(*Client) {
        // 先查缓存
        self.cache_mutex.lock();
        if (self.cache.get(topic)) |cached| {
            self.cache_mutex.unlock();
            return cached;
        }
        self.cache_mutex.unlock();
        
        // 缓存未命中,执行实际匹配
        const result = try self.root.match(...);
        
        // 更新缓存
        self.cache_mutex.lock();
        try self.cache.put(topic, result);
        self.cache_mutex.unlock();
        
        return result;
    }
};
```

## 预期效果

这些优化预计可以带来:
- **延迟降低**: 5ms → 1-2ms (3-5倍提升)
- **吞吐量提升**: 200条/秒 → 1000-2000条/秒 (5-10倍提升)
- **CPU 使用率降低**: 减少锁竞争和内存分配
- **内存使用降低**: 缓冲区复用减少 GC 压力

## 是否继续?

建议先实施这些优化,验证效果后再决定是否进行完整的 IOCP 重构。

你希望我:
A. 继续实施上述渐进式优化
B. 坚持完成 IOCP 完整重构
C. 先测试当前性能瓶颈,再决定优化方向
