# MQTT 订阅持久化完善设计

## 设计原则

遵循 MQTT 3.1.1/5.0 规范,正确处理会话生命周期和订阅管理。

## 会话状态机

```
┌─────────────┐
│   未连接     │
│ (No Session) │
└──────┬───────┘
       │ CONNECT(Clean=0)
       ▼
┌─────────────┐    DISCONNECT/网络断开    ┌──────────────┐
│   已连接     │───────────────────────────▶│   断开连接    │
│ (Connected)  │                            │ (Disconnected)│
└──────┬───────┘                            └───────┬───────┘
       │                                            │
       │ CONNECT(Clean=1)                          │ 重连(Clean=0)
       │                                            │ Session Present=1
       ▼                                            ▼
┌─────────────┐                            ┌──────────────┐
│  清空会话    │                            │   恢复会话    │
│(Clean Session)│                           │(Resume Session)
└─────────────┘                            └──────────────┘
```

## 核心场景处理

### 1. 客户端连接 (CONNECT)

| Clean Session | 行为 | Session Present | 持久化操作 |
|---------------|-----|-----------------|-----------|
| 1 (true)      | 清空旧会话 | 0 | 删除持久化订阅 |
| 0 (false)     | 保留会话 | 有旧会话:1<br>无旧会话:0 | 恢复持久化订阅 |

**实现要点:**
- 连接时检查是否有持久化订阅
- Clean Session = 0 且有订阅时,恢复到主题树
- Clean Session = 1 时,从主题树和持久化存储删除

### 2. 客户端断开 (DISCONNECT / 网络断开)

| Clean Session | 断开类型 | 主题树处理 | 持久化处理 |
|---------------|---------|-----------|-----------|
| 1             | 正常/异常 | 立即清理 | 无需处理 |
| 0             | 正常/异常 | **保留** | **保留** |

**关键改进:**
- ❌ 旧逻辑:断开时从主题树移除订阅
- ✅ 新逻辑:Clean Session = 0 时,断开**不移除**订阅,保留在主题树中
- 原因:客户端可能短时间内重连,保留订阅可以立即接收消息

**实现策略:**
```
断开连接时:
1. 标记客户端为 is_connected = false
2. 主题树中的 Client 指针保留(不删除订阅关系)
3. 持久化文件保留
4. 消息转发时跳过 is_connected = false 的客户端

重连时:
1. 查找主题树中是否有旧的 Client 对象
2. 如果有,更新其 is_connected = true
3. 如果没有,从持久化恢复
```

### 3. 取消订阅 (UNSUBSCRIBE)

```
UNSUBSCRIBE 处理流程:
1. 从主题树移除订阅 ✓ (已实现)
2. 从持久化存储移除 ✓ (已实现)
3. 从客户端订阅列表移除 ✓ (已实现)
4. 清理空的主题树节点 ✓ (已实现)
```

### 4. 会话过期 (Session Expiry)

MQTT 5.0 引入的会话过期间隔:

```
会话过期处理:
1. 记录客户端断开时间
2. 定期检查(每分钟)
3. 超过过期时间的会话:
   - 从主题树删除订阅
   - 从持久化删除
   - 清理相关资源
```

## 内存管理优化

### 问题:客户端对象生命周期

**当前问题:**
- 断开时 `deinit(client)` 立即释放
- 主题树中的 `*Client` 指针变成悬空指针

**解决方案:**

#### 方案 A:引用计数 (推荐)

```zig
pub const Client = struct {
    ref_count: std.atomic.Value(usize),
    
    pub fn retain(self: *Client) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }
    
    pub fn release(self: *Client) void {
        const old = self.ref_count.fetchSub(1, .monotonic);
        if (old == 1) {
            self.deinit();
        }
    }
};
```

- 连接创建:ref_count = 1
- 主题树订阅:ref_count += 1
- 取消订阅:ref_count -= 1
- 断开连接:ref_count -= 1
- ref_count == 0:真正释放内存

#### 方案 B:延迟清理 (简单但有风险)

```zig
断开连接时:
1. client.is_connected = false
2. 不释放 Client 对象
3. 后台线程定期扫描,清理长时间断开的客户端
```

**风险:**内存占用持续增长

#### 方案 C:Client ID 映射 (当前可行)

```zig
// Broker 维护 Client ID 到 Client 对象的映射
clients: StringHashMap(*Client)

断开时:
1. 从 HashMap 移除
2. 主题树保留订阅,但用 Client ID 标识
3. 转发消息时通过 Client ID 查找当前连接
```

## 改进实施优先级

### P0 (立即实施)

1. **修复断开时的主题树清理逻辑**
   - ❌ 移除:`disconnect()` 中从主题树删除订阅
   - ✅ 改为:仅标记 `is_connected = false`

2. **优化消息转发**
   - 转发前检查 `client.is_connected`
   - 跳过已断开的客户端

3. **重连时的主题树处理**
   - 检查主题树是否已有订阅
   - 如果有,更新 Client 指针
   - 如果没有,从持久化恢复

### P1 (短期实施)

4. **会话过期机制**
   - 添加 `last_disconnect_time` 字段
   - 后台定时器定期检查
   - 清理过期会话

5. **内存优化:引用计数**
   - 为 Client 添加引用计数
   - 安全管理 Client 生命周期

### P2 (中长期)

6. **QoS > 0 消息队列持久化**
   - 持久化未确认的消息
   - 重连后重发

7. **Retained 消息持久化**
   - 保留消息持久化
   - Broker 重启后恢复

8. **遗嘱消息持久化**
   - 会话断开时触发遗嘱
   - 持久化遗嘱配置

## 测试场景

### 场景 1:Clean Session = 0,正常重连

```bash
# 1. 订阅
mosquitto_sub -h localhost -t "test/#" -i "client1" -c

# 2. 断开 (Ctrl+C)

# 3. 发布消息 (客户端离线)
mosquitto_pub -h localhost -t "test/msg" -m "Hello"

# 4. 重连
mosquitto_sub -h localhost -t "test/#" -i "client1" -c

# 预期:
# - Session Present = 1
# - 订阅自动恢复
# - 如果实现了 QoS > 0,应收到离线消息
```

### 场景 2:Clean Session = 1,清空会话

```bash
# 1. 订阅 (Clean Session = 0)
mosquitto_sub -h localhost -t "test/#" -i "client1" -c

# 2. 断开

# 3. 重连 (Clean Session = 1)
mosquitto_sub -h localhost -t "test/#" -i "client1"

# 预期:
# - Session Present = 0
# - 旧订阅已清空
# - 持久化文件中无 client1 记录
```

### 场景 3:取消订阅

```bash
# 1. 订阅多个主题
mosquitto_sub -h localhost -t "test/+" -i "client1" -c &
mosquitto_sub -h localhost -t "home/#" -i "client1" -c

# 2. 取消其中一个
# (使用 MQTT 客户端发送 UNSUBSCRIBE "test/+")

# 3. 检查持久化文件
cat data/subscriptions.json

# 预期:
# - 主题树中 "test/+" 已移除
# - "home/#" 仍存在
# - 持久化文件同步更新
```

## 代码改动清单

### 文件:`src/main_async.zig`

```zig
// disconnect() 方法
fn disconnect(self: *ClientConnection) void {
    // ... 现有代码 ...
    
    // ❌ 移除这段代码 - 不要清理订阅
    // if (self.client.clean_start) {
    //     self.broker.subscriptions.unsubscribeAll(self.client);
    // }
    
    // ✅ 改为:仅标记为已断开
    self.client.is_connected = false;
    
    // Clean Session = 1 时才清理订阅
    if (self.client.clean_start) {
        self.broker.subscriptions.unsubscribeAll(self.client);
    }
    
    // ... 其余代码保持不变 ...
}
```

### 文件:`src/subscription.zig`

```zig
// 新增:检查并更新现有订阅
pub fn updateClientIfExists(self: *SubscriptionTree, old_client_id: []const u8, new_client: *Client) bool {
    // 遍历主题树,找到旧的 Client 指针并更新
    // 返回 true 表示找到并更新了
}
```

### 文件:`src/client.zig`

```zig
// 可选:添加引用计数
pub const Client = struct {
    ref_count: std.atomic.Value(usize),
    // ... 其他字段 ...
};
```

## 配置项

建议添加的配置:

```zig
pub const config = struct {
    // 会话过期时间 (秒),0 表示永不过期
    pub const SESSION_EXPIRY_INTERVAL: u32 = 3600; // 1 小时
    
    // 是否在断开时立即清理主题树 (不推荐)
    pub const CLEANUP_ON_DISCONNECT: bool = false;
    
    // 会话清理检查间隔 (秒)
    pub const SESSION_CLEANUP_INTERVAL: u32 = 60; // 1 分钟
};
```

## 总结

核心改进点:
1. **断开时不清理主题树** - 保留订阅关系,等待重连
2. **消息转发时检查连接状态** - 跳过已断开的客户端
3. **重连时智能处理** - 先检查主题树,再检查持久化
4. **会话过期机制** - 定期清理长时间未连接的会话
5. **内存安全** - 引用计数或延迟清理,避免悬空指针
