# MQTT Broker 实施路线图

**项目**: mqtt-broker1  
**创建日期**: 2025年10月23日  
**版本**: 1.0

本文档规划了 MQTT Broker 从当前状态 (65% 符合度) 到生产就绪的完整路线图。

---

## 🎯 短期目标 (1-2 周)

### 优先级: 🔴 CRITICAL

这些是影响协议符合性和稳定性的关键问题,必须立即修复。

#### 1. 修复消息转发 QoS 降级问题
**预计工作量**: 4-6 小时  
**文件**: `subscription.zig`, `main.zig`, `handle_publish.zig`

**当前问题**:
```zig
// main.zig - 强制使用 QoS 0
try publish.writePublish(
    writer,
    publish_packet.topic,
    publish_packet.payload,
    .AtMostOnce,  // ⚠️ 违反 MQTT 规范
    ...
);
```

**实施步骤**:

1. **修改订阅树存储 QoS** (30 分钟)
   ```zig
   // subscription.zig
   const Node = struct {
       children: std.StringHashMap(Node),
       subscribers: ArrayList(struct {
           client: *Client,
           qos: mqtt.QoS,  // 新增
       }),
   };
   ```

2. **更新 subscribe 方法** (20 分钟)
   ```zig
   pub fn subscribe(
       self: *SubscriptionTree, 
       topic: []const u8, 
       client: *Client,
       qos: mqtt.QoS,  // 新增参数
   ) !void {
       // ...
       try node.subscribers.append(allocator, .{
           .client = client,
           .qos = qos,
       });
   }
   ```

3. **修改 match 返回类型** (30 分钟)
   ```zig
   pub const MatchedSubscriber = struct {
       client: *Client,
       qos: mqtt.QoS,
   };
   
   pub fn match(...) !ArrayList(MatchedSubscriber) {
       // ...
   }
   ```

4. **更新消息转发逻辑** (1 小时)
   ```zig
   // main.zig - PUBLISH case
   for (matched_clients.items) |subscriber| {
       // 计算实际转发 QoS
       const forward_qos = @min(
           @intFromEnum(publish_packet.qos),
           @intFromEnum(subscriber.qos)
       );
       const qos: mqtt.QoS = @enumFromInt(forward_qos);
       
       // 生成 Packet ID (如果需要)
       const packet_id = if (qos != .AtMostOnce) 
           try subscriber.client.nextPacketId() 
       else 
           null;
       
       try publish.writePublish(
           writer,
           publish_packet.topic,
           publish_packet.payload,
           qos,  // ✅ 使用协商后的 QoS
           publish_packet.retain,
           false,
           packet_id,
       );
       
       try writer.writeToStream(&subscriber.client.stream);
   }
   ```

5. **测试验证** (1 小时)
   - 订阅 QoS 0,发布 QoS 2 → 应收到 QoS 0
   - 订阅 QoS 2,发布 QoS 1 → 应收到 QoS 1
   - 订阅 QoS 2,发布 QoS 2 → 应收到 QoS 2

**验收标准**:
- ✅ 转发 QoS = min(发布 QoS, 订阅 QoS)
- ✅ QoS 1/2 消息包含 Packet ID
- ✅ 所有测试用例通过

---

#### 2. 添加主题名称验证 (PUBLISH)
**预计工作量**: 2-3 小时  
**文件**: `subscription.zig`, `handle_publish.zig`

**实施步骤**:

1. **实现验证函数** (1 小时)
   ```zig
   // subscription.zig
   pub fn validateTopicName(topic: []const u8) !void {
       // 1. 空主题检查
       if (topic.len == 0) {
           std.debug.print("ERROR: Topic name cannot be empty\n", .{});
           return error.InvalidTopicName;
       }
       
       // 2. 禁止通配符 '+' 和 '#'
       for (topic, 0..) |char, i| {
           if (char == '+' or char == '#') {
               std.debug.print(
                   "ERROR: Topic name cannot contain wildcard '{c}' at position {d}\n",
                   .{char, i}
               );
               return error.TopicContainsWildcard;
           }
       }
       
       // 3. 禁止空字符 U+0000
       if (std.mem.indexOf(u8, topic, &[_]u8{0}) != null) {
           std.debug.print("ERROR: Topic name contains null character\n", .{});
           return error.TopicContainsNullChar;
       }
       
       // 4. UTF-8 验证
       if (!std.unicode.utf8ValidateSlice(topic)) {
           std.debug.print("ERROR: Topic name is not valid UTF-8\n", .{});
           return error.InvalidUTF8;
       }
   }
   ```

2. **集成到 PUBLISH 处理** (30 分钟)
   ```zig
   // handle_publish.zig
   pub fn read(reader: *packet.Reader) !PublishPacket {
       // ... 读取主题
       const topic = try reader.readUTF8String(false) orelse {
           return error.MissingTopic;
       };
       
       // 验证主题名称 (新增)
       validateTopicName(topic) catch |err| {
           logger.err("Invalid topic name '{s}': {any}", .{topic, err});
           return error.InvalidTopicName;
       };
       
       // ... 继续处理
   }
   ```

3. **添加单元测试** (1 小时)
   ```zig
   // test.zig
   test "validateTopicName - valid topics" {
       try validateTopicName("home/temperature");
       try validateTopicName("/test");
       try validateTopicName("a/b/c/d");
       try validateTopicName("sensor-1/data");
   }
   
   test "validateTopicName - invalid topics" {
       try std.testing.expectError(
           error.InvalidTopicName, 
           validateTopicName("")
       );
       try std.testing.expectError(
           error.TopicContainsWildcard, 
           validateTopicName("home/+/temp")
       );
       try std.testing.expectError(
           error.TopicContainsWildcard, 
           validateTopicName("home/#")
       );
   }
   ```

**验收标准**:
- ✅ 拒绝空主题
- ✅ 拒绝包含 `+` 或 `#` 的主题
- ✅ 拒绝包含空字符的主题
- ✅ 拒绝无效 UTF-8
- ✅ 单元测试覆盖率 > 90%

---

#### 3. 实现 Keep Alive 超时检测
**预计工作量**: 3-4 小时  
**文件**: `main.zig`, `client.zig`

**实施步骤**:

1. **添加监控线程** (1.5 小时)
   ```zig
   // main.zig - MqttBroker
   pub fn start(self: *MqttBroker, port: u16) !void {
       // ... 现有启动逻辑
       
       // 启动 Keep Alive 监控线程
       const monitor_thread = try std.Thread.spawn(
           .{}, 
           keepAliveMonitor, 
           .{self}
       );
       monitor_thread.detach();
       
       // ...
   }
   
   fn keepAliveMonitor(broker: *MqttBroker) void {
       while (true) {
           std.Thread.sleep(5 * std.time.ns_per_s);  // 每 5 秒检查
           
           const now = time.milliTimestamp();
           var it = broker.clients.iterator();
           
           while (it.next()) |entry| {
               const client = entry.value_ptr.*;
               
               // Keep Alive = 0 表示不检查
               if (client.keep_alive == 0) continue;
               
               // 计算超时阈值 (1.5 倍 Keep Alive)
               const timeout_ms: i64 = @intCast(client.keep_alive * 1000 * 3 / 2);
               const idle_time = now - client.last_activity;
               
               if (idle_time > timeout_ms) {
                   logger.warn(
                       "Client {s} keep-alive timeout (idle: {d}ms, limit: {d}ms)",
                       .{client.identifer, idle_time, timeout_ms}
                   );
                   
                   // 标记为超时断开 (触发 Will 消息)
                   client.graceful_disconnect = false;
                   
                   // 关闭连接
                   client.stream.close();
               }
           }
       }
   }
   ```

2. **添加优雅断开标志** (30 分钟)
   ```zig
   // client.zig
   pub const Client = struct {
       // ... 现有字段
       graceful_disconnect: bool = false,  // 新增
   };
   
   // main.zig - DISCONNECT 处理
   .DISCONNECT => {
       logger.info("{s} disconnected gracefully", .{client_name});
       client.graceful_disconnect = true;  // 标记为正常断开
       return;
   }
   ```

3. **测试验证** (1 小时)
   - 设置 Keep Alive = 5 秒
   - 不发送 PINGREQ
   - 7.5 秒后应自动断开

**验收标准**:
- ✅ 超时客户端自动断开
- ✅ 正常 DISCONNECT 不触发 Will
- ✅ 超时断开触发 Will 消息
- ✅ Keep Alive = 0 时不检查

---

#### 4. 添加订阅树并发锁
**预计工作量**: 2-3 小时  
**文件**: `subscription.zig`

**实施步骤**:

1. **添加互斥锁** (30 分钟)
   ```zig
   // subscription.zig
   pub const SubscriptionTree = struct {
       root: Node,
       mutex: std.Thread.Mutex,  // 新增
       
       pub fn init(allocator: Allocator) SubscriptionTree {
           return SubscriptionTree{
               .root = Node.init(allocator),
               .mutex = .{},  // 初始化
           };
       }
   };
   ```

2. **保护写操作** (1 小时)
   ```zig
   pub fn subscribe(
       self: *SubscriptionTree, 
       topic: []const u8, 
       client: *Client,
   ) !void {
       self.mutex.lock();
       defer self.mutex.unlock();
       
       // ... 原有逻辑 (修改树结构)
   }
   
   pub fn unsubscribe(
       self: *SubscriptionTree, 
       topic: []const u8, 
       client: *Client,
   ) !bool {
       self.mutex.lock();
       defer self.mutex.unlock();
       
       // ... 原有逻辑 (修改树结构)
   }
   ```

3. **保护读操作** (30 分钟)
   ```zig
   pub fn match(
       self: *SubscriptionTree, 
       topic: []const u8, 
       publisher_client_id: ?[]const u8, 
       allocator: *Allocator
   ) !ArrayList(*Client) {
       self.mutex.lock();
       defer self.mutex.unlock();
       
       // ... 原有逻辑 (遍历树结构)
   }
   ```

4. **并发测试** (1 小时)
   ```zig
   test "SubscriptionTree - concurrent access" {
       const allocator = std.testing.allocator;
       var tree = SubscriptionTree.init(allocator);
       defer tree.deinit();
       
       // 启动 10 个线程同时订阅
       var threads: [10]std.Thread = undefined;
       for (&threads, 0..) |*thread, i| {
           thread.* = try std.Thread.spawn(.{}, concurrentSubscribe, 
               .{&tree, i});
       }
       
       // 等待完成
       for (threads) |thread| {
           thread.join();
       }
       
       // 验证数据一致性
       // ...
   }
   ```

**性能优化** (可选):
- 考虑使用读写锁 `std.Thread.RwLock`
- match 操作用读锁,subscribe/unsubscribe 用写锁
- 提高并发性能

**验收标准**:
- ✅ 无数据竞争
- ✅ 并发测试通过
- ✅ 性能下降 < 10%

---

## 🎯 中期目标 (3-4 周)

### 优先级: 🟡 HIGH

这些功能是 MQTT 协议的核心特性,需要尽快实现以提高符合度。

#### 5. 实现 Retained 消息存储
**预计工作量**: 6-8 小时  
**文件**: `main.zig`, 新增 `retained_messages.zig`

**架构设计**:
```zig
// retained_messages.zig
pub const RetainedMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: mqtt.QoS,
    timestamp: i64,
};

pub const RetainedMessageStore = struct {
    messages: std.StringHashMap(RetainedMessage),
    allocator: Allocator,
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: Allocator) RetainedMessageStore {
        return .{
            .messages = std.StringHashMap(RetainedMessage).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }
    
    pub fn store(self: *RetainedMessageStore, topic: []const u8, 
                 payload: []const u8, qos: mqtt.QoS) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (payload.len == 0) {
            // [MQTT-3.3.1-10] Payload 为空时删除
            if (self.messages.fetchRemove(topic)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value.payload);
            }
            return;
        }
        
        const key = try self.allocator.dupe(u8, topic);
        const msg = RetainedMessage{
            .topic = key,
            .payload = try self.allocator.dupe(u8, payload),
            .qos = qos,
            .timestamp = std.time.milliTimestamp(),
        };
        
        try self.messages.put(key, msg);
    }
    
    pub fn findMatching(self: *RetainedMessageStore, 
                        topic_filter: []const u8) !ArrayList(RetainedMessage) {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var results: ArrayList(RetainedMessage) = .{};
        
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            if (topicMatchesFilter(entry.key_ptr.*, topic_filter)) {
                try results.append(self.allocator, entry.value_ptr.*);
            }
        }
        
        return results;
    }
};
```

**集成步骤**:

1. **添加到 MqttBroker** (1 小时)
   ```zig
   pub const MqttBroker = struct {
       // ...
       retained_messages: RetainedMessageStore,
       
       pub fn init(allocator: Allocator) MqttBroker {
           return .{
               // ...
               .retained_messages = RetainedMessageStore.init(allocator),
           };
       }
   };
   ```

2. **PUBLISH 时存储** (1 小时)
   ```zig
   // main.zig - PUBLISH case
   if (publish_packet.retain) {
       try broker.retained_messages.store(
           publish_packet.topic,
           publish_packet.payload,
           publish_packet.qos
       );
       logger.debug("Stored retained message for topic '{s}'", 
           .{publish_packet.topic});
   }
   ```

3. **SUBSCRIBE 时发送** (2 小时)
   ```zig
   // main.zig - SUBSCRIBE case
   for (subscribe_packet.topics.items) |topic| {
       try self.subscriptions.subscribe(topic.filter, client);
       
       // 发送匹配的保留消息
       const retained = try broker.retained_messages.findMatching(topic.filter);
       defer retained.deinit(broker.allocator);
       
       for (retained.items) |msg| {
           writer.reset();
           try publish.writePublish(
               writer,
               msg.topic,
               msg.payload,
               msg.qos,
               true,  // retain=true
               false,
               null,
           );
           try writer.writeToStream(&client.stream);
           logger.debug("Sent retained message '{s}' to {s}", 
               .{msg.topic, client.identifer});
       }
   }
   ```

4. **测试** (2 小时)
   - 发布保留消息
   - 新订阅者立即收到
   - Payload 为空时删除
   - 通配符订阅匹配多个保留消息

**验收标准**:
- ✅ [MQTT-3.3.1-5] Retain=1 时存储
- ✅ [MQTT-3.3.1-6] 新订阅者立即收到
- ✅ [MQTT-3.3.1-10] Payload 为空时删除
- ✅ 支持通配符匹配

---

#### 6. 完善 QoS 2 消息持久化
**预计工作量**: 8-10 小时  
**文件**: `client.zig`, `main.zig`, 新增 `qos2_manager.zig`

**状态机设计**:
```zig
// qos2_manager.zig
pub const Qos2State = enum {
    // 发送方状态
    Published,       // 已发送 PUBLISH
    PubrecReceived,  // 收到 PUBREC
    PubcompReceived, // 收到 PUBCOMP (完成)
    
    // 接收方状态
    PubrecSent,      // 已发送 PUBREC
    PubrelReceived,  // 收到 PUBREL
};

pub const Qos2Message = struct {
    packet_id: u16,
    state: Qos2State,
    message: ?Message,  // 发送方保留,接收方为 null
    timestamp: i64,
    retry_count: u8,
};

pub const Qos2Manager = struct {
    messages: std.AutoHashMap(u16, Qos2Message),
    allocator: Allocator,
    
    pub fn trackPublish(self: *Qos2Manager, packet_id: u16, 
                        message: Message) !void {
        try self.messages.put(packet_id, .{
            .packet_id = packet_id,
            .state = .Published,
            .message = message,
            .timestamp = std.time.milliTimestamp(),
            .retry_count = 0,
        });
    }
    
    pub fn handlePubrec(self: *Qos2Manager, packet_id: u16) !void {
        if (self.messages.getPtr(packet_id)) |msg| {
            if (msg.state != .Published) {
                return error.InvalidState;
            }
            msg.state = .PubrecReceived;
            msg.timestamp = std.time.milliTimestamp();
        }
    }
    
    pub fn handlePubcomp(self: *Qos2Manager, packet_id: u16) !void {
        _ = self.messages.remove(packet_id);  // 完成,删除追踪
    }
    
    // 接收方逻辑
    pub fn trackPubrec(self: *Qos2Manager, packet_id: u16) !void {
        try self.messages.put(packet_id, .{
            .packet_id = packet_id,
            .state = .PubrecSent,
            .message = null,
            .timestamp = std.time.milliTimestamp(),
            .retry_count = 0,
        });
    }
    
    pub fn handlePubrel(self: *Qos2Manager, packet_id: u16) !void {
        _ = self.messages.remove(packet_id);  // 完成
    }
};
```

**集成步骤**: (详细步骤省略,包括修改 Client、main.zig 等)

**验收标准**:
- ✅ QoS 2 消息不重复投递
- ✅ 状态正确追踪
- ✅ 超时重传机制
- ✅ Packet ID 冲突检测

---

#### 7. 实现 Will 消息触发
**预计工作量**: 4-6 小时  
**文件**: `client.zig`, `main.zig`

**实施步骤**:

1. **添加触发逻辑** (2 小时)
   ```zig
   // client.zig
   pub fn deinit(self: *Client, broker: *MqttBroker) void {
       // 检查是否需要发布 Will 消息
       if (!self.graceful_disconnect and self.will_topic) |topic| {
           logger.info("Publishing will message for {s}", .{self.identifer});
           
           // 构建 Will PUBLISH 消息
           const will_packet = publish.PublishPacket{
               .topic = topic,
               .payload = self.will_payload orelse "",
               .qos = self.will_qos,
               .retain = self.will_retain,
               .dup = false,
               .packet_id = null,
           };
           
           // 转发给订阅者
           broker.publishWillMessage(will_packet, self.identifer) catch |err| {
               logger.err("Failed to publish will message: {any}", .{err});
           };
       }
       
       // ... 原有清理逻辑
   }
   ```

2. **添加 Will 发布函数** (1 小时)
   ```zig
   // main.zig - MqttBroker
   pub fn publishWillMessage(
       self: *MqttBroker, 
       will: publish.PublishPacket,
       publisher_id: []const u8
   ) !void {
       // 查找订阅者
       var matched = try self.subscriptions.match(
           will.topic, 
           publisher_id, 
           &self.allocator
       );
       defer matched.deinit(self.allocator);
       
       // 转发
       for (matched.items) |subscriber| {
           // ... 发送逻辑
       }
   }
   ```

3. **测试** (2 小时)
   - 异常断开触发 Will
   - 正常 DISCONNECT 不触发
   - Keep Alive 超时触发 Will

**验收标准**:
- ✅ [MQTT-3.1.2-8] 异常断开发布 Will
- ✅ [MQTT-3.14.4-1] 正常断开不发布
- ✅ Will QoS/Retain 正确

---

#### 8. Session 持久化 (基础版)
**预计工作量**: 12-16 小时  
**文件**: 新增 `session_store.zig`, 修改 `main.zig`, `client.zig`

**存储方案**: 文件系统 (生产环境建议使用 SQLite)

**架构设计**:
```zig
// session_store.zig
pub const SessionData = struct {
    client_id: []const u8,
    subscriptions: []Subscription,
    inflight_qos1: []Message,
    inflight_qos2: []Qos2Message,
    expiry_time: i64,  // 会话过期时间
};

pub const SessionStore = struct {
    base_dir: []const u8,
    allocator: Allocator,
    
    pub fn saveSession(self: *SessionStore, data: SessionData) !void {
        const filepath = try std.fmt.allocPrint(
            self.allocator, 
            "{s}/{s}.session", 
            .{self.base_dir, data.client_id}
        );
        defer self.allocator.free(filepath);
        
        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        
        // 序列化为 JSON
        try std.json.stringify(data, .{}, file.writer());
    }
    
    pub fn loadSession(self: *SessionStore, client_id: []const u8) !?SessionData {
        const filepath = try std.fmt.allocPrint(
            self.allocator, 
            "{s}/{s}.session", 
            .{self.base_dir, client_id}
        );
        defer self.allocator.free(filepath);
        
        const file = std.fs.cwd().openFile(filepath, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();
        
        // 反序列化
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);
        
        return try std.json.parseFromSlice(SessionData, self.allocator, content, .{});
    }
    
    pub fn deleteSession(self: *SessionStore, client_id: []const u8) !void {
        const filepath = try std.fmt.allocPrint(
            self.allocator, 
            "{s}/{s}.session", 
            .{self.base_dir, client_id}
        );
        defer self.allocator.free(filepath);
        
        std.fs.cwd().deleteFile(filepath) catch {};
    }
};
```

**集成步骤**: (详细步骤较长,包括 CONNECT 时恢复、DISCONNECT 时保存等)

**验收标准**:
- ✅ Clean Session=0 时保存会话
- ✅ 重连时恢复订阅
- ✅ QoS 1/2 消息持久化
- ✅ Session Expiry 正确处理

---

## 🎯 长期目标 (2-3 个月)

### 优先级: 🟢 MEDIUM

这些是 MQTT 5.0 高级特性和性能优化,适合在核心功能稳定后实现。

#### 9. MQTT 5.0 Properties 支持
**预计工作量**: 20-30 小时

**需要支持的 Properties**:
- Session Expiry Interval
- Receive Maximum
- Maximum Packet Size
- Topic Alias Maximum
- Request Response Information
- User Property
- ...

#### 10. Shared Subscriptions (共享订阅)
**预计工作量**: 8-12 小时

#### 11. Topic Aliases (主题别名)
**预计工作量**: 6-8 小时

#### 12. Request/Response Pattern
**预计工作量**: 4-6 小时

#### 13. Enhanced Authentication
**预计工作量**: 16-20 小时

#### 14. 性能优化
**预计工作量**: 持续进行

- io_uring 集成 (Linux)
- 批量消息处理
- 零拷贝优化
- 内存池管理

#### 15. 集群支持
**预计工作量**: 40-60 小时

- 节点间通信
- 订阅同步
- 消息路由
- 一致性保证

---

## 📊 里程碑追踪

| 里程碑 | 目标符合度 | 预计完成时间 | 关键交付物 |
|--------|-----------|-------------|-----------|
| **M1: 短期目标完成** | 75% | Week 2 | QoS 修复、并发安全、超时检测 |
| **M2: 中期目标完成** | 85% | Week 6 | Retained、QoS 2、Will、Session |
| **M3: MQTT 5.0 基础** | 90% | Month 3 | Properties、Shared Sub |
| **M4: 生产就绪** | 95%+ | Month 6 | 性能优化、集群、监控 |

---

## ✅ 每日/每周检查清单

### 每日检查
- [ ] 编译无警告
- [ ] 单元测试全部通过
- [ ] Valgrind 无内存泄漏
- [ ] 代码审查通过

### 每周检查
- [ ] 更新实施进度
- [ ] 性能基准测试
- [ ] 协议符合度测试
- [ ] 文档更新

---

最后更新: 2025年10月23日
