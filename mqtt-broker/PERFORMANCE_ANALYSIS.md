# MQTT Broker 性能分析与优化方案

## 当前架构问题

### 1. 当前实现 (BIO - 每客户端一线程)
```
Client 1 ──► Thread 1 ──► blocking read()
Client 2 ──► Thread 2 ──► blocking read()
Client 3 ──► Thread 3 ──► blocking read()
...
Client N ──► Thread N ──► blocking read()
```

**性能瓶颈:**
- ✗ 每个客户端独立线程,1000个客户端 = 1000个线程
- ✗ 频繁上下文切换,每次 5-10μs
- ✗ 每次写入都需要 Mutex 锁,串行化写入
- ✗ 内存开销:每线程 1-2MB 栈空间
- ✗ 无法利用批量 IO 优化

**当前性能:**
- 延迟: 5ms/消息
- 吞吐量: ~200 消息/秒 (单客户端)
- 距离目标 100万/秒: **差距 5000 倍**

---

## 优化方案:IO 多路复用

### 2. 推荐架构 (epoll/IOCP)

```
           ┌─────────────────────────────────┐
           │   IO 复用事件循环 (主线程)        │
           │  epoll_wait() / IOCP GetQueued  │
           └────────────┬────────────────────┘
                        │
         ┌──────────────┼──────────────┐
         │              │              │
    ┌────▼────┐    ┌───▼────┐    ┌───▼────┐
    │ Worker 1│    │Worker 2│    │Worker N│
    │ 线程池  │    │ 线程池 │    │ 线程池 │
    └─────────┘    └────────┘    └────────┘
         │              │              │
    处理消息      处理消息       处理消息
```

**性能提升:**
- ✓ 单线程处理所有 IO,无上下文切换
- ✓ 批量读取/写入,减少系统调用
- ✓ 无锁设计,减少竞争
- ✓ 内存高效,固定线程池
- ✓ 更好的 CPU 缓存局部性

---

## 实现方案

### Windows (IOCP - IO Completion Port)

```zig
const IOCP = struct {
    completion_port: windows.HANDLE,
    worker_threads: []std.Thread,
    
    pub fn init(allocator: Allocator, thread_count: u32) !IOCP {
        const port = try windows.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            thread_count
        );
        
        var threads = try allocator.alloc(std.Thread, thread_count);
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{port});
        }
        
        return IOCP{
            .completion_port = port,
            .worker_threads = threads,
        };
    }
    
    fn workerThread(port: windows.HANDLE) void {
        while (true) {
            var bytes: u32 = undefined;
            var key: usize = undefined;
            var overlapped: *windows.OVERLAPPED = undefined;
            
            const ok = windows.kernel32.GetQueuedCompletionStatus(
                port,
                &bytes,
                &key,
                &overlapped,
                windows.INFINITE
            );
            
            if (ok) {
                // 处理完成的 IO 操作
                const client = @as(*Client, @ptrFromInt(key));
                handleClientData(client, bytes);
            }
        }
    }
};
```

### Linux (epoll)

```zig
const Epoll = struct {
    epoll_fd: i32,
    events: []std.os.linux.epoll_event,
    
    pub fn init(allocator: Allocator, max_events: u32) !Epoll {
        const fd = try std.os.epoll_create1(0);
        const events = try allocator.alloc(std.os.linux.epoll_event, max_events);
        
        return Epoll{
            .epoll_fd = fd,
            .events = events,
        };
    }
    
    pub fn add(self: *Epoll, socket: std.posix.socket_t, client: *Client) !void {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLLIN | std.os.linux.EPOLLET, // 边缘触发
            .data = .{ .ptr = @intFromPtr(client) },
        };
        
        try std.os.epoll_ctl(
            self.epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            socket,
            &event
        );
    }
    
    pub fn wait(self: *Epoll, timeout_ms: i32) !u32 {
        const count = try std.os.epoll_wait(
            self.epoll_fd,
            self.events,
            timeout_ms
        );
        return @intCast(count);
    }
};
```

---

## 性能优化技巧

### 1. 批量 IO (Scatter-Gather)

**当前:**
```zig
// 每次写入都是一次系统调用
try stream.write(data1);  // syscall 1
try stream.write(data2);  // syscall 2
try stream.write(data3);  // syscall 3
```

**优化后:**
```zig
// 使用 writev 批量写入
const iovecs = [_]std.os.iovec_const{
    .{ .iov_base = data1.ptr, .iov_len = data1.len },
    .{ .iov_base = data2.ptr, .iov_len = data2.len },
    .{ .iov_base = data3.ptr, .iov_len = data3.len },
};
try std.os.writev(socket, &iovecs);  // 一次系统调用
```

**性能提升:** 减少系统调用 **60-80%**

---

### 2. 零拷贝转发

**当前:**
```zig
// 订阅者转发:每个订阅者都拷贝一次
for (subscribers) |sub| {
    const data = try allocator.dupe(u8, payload);  // 拷贝
    try sub.stream.write(data);                     // 写入
    allocator.free(data);                           // 释放
}
```

**优化后:**
```zig
// 使用共享缓冲区,无拷贝
const shared_buffer = buildPublishPacket(topic, payload);
for (subscribers) |sub| {
    try sub.stream.write(shared_buffer);  // 直接引用,无拷贝
}
```

**性能提升:** 减少内存分配 **100%**,提升 **2-3 倍**

---

### 3. 订阅树优化

**当前:**
```zig
// 每次查询都遍历整棵树
const subscribers = try tree.match(topic);
```

**优化后:**
```zig
// 使用主题缓存
const CachedTree = struct {
    tree: SubscriptionTree,
    cache: std.StringHashMap([]const *Client),
    
    pub fn match(self: *CachedTree, topic: []const u8) []const *Client {
        if (self.cache.get(topic)) |cached| {
            return cached;  // 缓存命中,O(1)
        }
        
        const result = self.tree.match(topic);  // 缓存未命中,O(n)
        try self.cache.put(topic, result);
        return result;
    }
};
```

**性能提升:** 热点主题 **10-100 倍**

---

### 4. 内存池

**当前:**
```zig
// 频繁分配/释放
const buffer = try allocator.alloc(u8, size);
defer allocator.free(buffer);
```

**优化后:**
```zig
const BufferPool = struct {
    pool: std.ArrayList([]u8),
    
    pub fn acquire(self: *BufferPool) []u8 {
        return self.pool.popOrNull() orelse
            allocator.alloc(u8, BUFFER_SIZE) catch unreachable;
    }
    
    pub fn release(self: *BufferPool, buf: []u8) void {
        self.pool.append(buf) catch allocator.free(buf);
    }
};
```

**性能提升:** 减少分配器压力 **50-70%**

---

## 预期性能提升

| 优化项 | 当前 | 优化后 | 提升倍数 |
|--------|------|--------|----------|
| IO 模型 | 5ms/msg | 0.5ms/msg | **10x** |
| 批量 IO | N 次 syscall | 1 次 syscall | **3-5x** |
| 零拷贝 | 每订阅者拷贝 | 共享缓冲 | **2-3x** |
| 订阅查找 | O(n) 遍历 | O(1) 缓存 | **10-100x** |
| 内存分配 | 频繁 alloc/free | 内存池 | **2x** |

**综合提升:** **100-500 倍**

---

## 能否达到 100 万消息/秒?

### 理论计算

假设单机配置:
- CPU: 8 核
- 网络: 10Gbps
- 消息大小: 100 字节

**网络带宽限制:**
```
10Gbps = 1.25GB/s = 1,250,000,000 bytes/s
每条消息 = 100 bytes
理论上限 = 1,250,000,000 / 100 = 12,500,000 消息/秒
```

**CPU 处理限制:**
```
假设每条消息处理耗时 = 1μs (优化后)
8 核并行 = 8,000,000 消息/秒
```

**结论:** 
- 100 万消息/秒 **理论可达**
- 需要充分利用 IO 复用 + 零拷贝 + 批量操作
- 实际场景可能受限于订阅者数量(扇出效应)

---

## 实施步骤

### 阶段 1: IO 复用基础架构 (2-3 天)
1. 实现 Windows IOCP 版本
2. 实现 Linux epoll 版本
3. 统一接口抽象

### 阶段 2: 批量优化 (1-2 天)
1. 实现 writev 批量写入
2. 实现零拷贝转发
3. 共享缓冲区管理

### 阶段 3: 高级优化 (2-3 天)
1. 订阅树缓存
2. 内存池
3. 无锁数据结构

### 阶段 4: 测试与调优 (2-3 天)
1. 压力测试
2. 性能分析
3. 瓶颈识别与优化

---

## 参考资料

- [Zig std.os.epoll](https://ziglang.org/documentation/master/std/#A;std:os.linux.epoll_event)
- [Windows IOCP](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports)
- [The C10K Problem](http://www.kegel.com/c10k.html)
- [MQTT Broker Performance](https://www.emqx.io/blog/mqtt-broker-benchmarking-2023-emqx-vs-mosquitto)

