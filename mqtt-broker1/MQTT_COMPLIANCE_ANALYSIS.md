# MQTT 协议符合度分析与改进计划

**项目**: mqtt-broker1  
**分析日期**: 2025年10月23日  
**目标**: 实现符合 MQTT v5.0 和 v3.1.1 规范的 Broker  
**技术栈**: Zig 0.15.2+

---

## 📊 当前状态总览

### 整体符合度: 65%

| 模块 | 符合度 | 状态 |
|------|--------|------|
| **CONNECT/CONNACK** | 90% | ✅ 核心功能完整 |
| **PUBLISH** | 75% | ⚠️ 部分完成 |
| **SUBSCRIBE/UNSUBSCRIBE** | 85% | ✅ 基本完整 |
| **PINGREQ/PINGRESP** | 100% | ✅ 完全符合 |
| **Session 管理** | 20% | ❌ 需要实现 |
| **MQTT 5.0 特性** | 10% | ❌ 大部分未实现 |

---

## ✅ 已实现的功能 (符合 MQTT 标准)

### 1. CONNECT / CONNACK 处理
**文件位置**: `handle_connect.zig`, `main.zig`

- ✅ 协议版本检测 (MQTT 3.1、3.1.1、5.0)
- ✅ 客户端标识符验证 ([MQTT-3.1.3-5])
  - 长度: 2-23 字符 (可配置 MAX_CLIENT_ID_LEN)
  - 字符集: 0-9, a-z, A-Z
  - UTF-8 验证
- ✅ 连接标志完整解析
  - Clean Session / Clean Start
  - Will Flag、Will QoS、Will Retain
  - Username Flag、Password Flag
  - Reserved Bit 验证 ([MQTT-3.1.2-3])
- ✅ Keep Alive 处理
- ✅ 遗嘱消息 (Will) 结构解析
- ✅ 用户名/密码认证验证
- ✅ CONNACK 原因码
  - Success (0x00)
  - MalformedPacket (0x81)
  - ClientIdentifierNotValid (0x85)
  - BadUserNameOrPassword (0x86)
  - 等等...
- ✅ 错误累积机制 (ConnectPacket.errors)

**已实现的规范检查**:
- [MQTT-3.1.2-3] Reserved bit 必须为 0
- [MQTT-3.1.2-13] Will Flag=0 时 Will QoS 必须为 0
- [MQTT-3.1.2-14] Will QoS 只能是 0/1/2
- [MQTT-3.1.2-19] Username Flag=1 时必须有 Username
- [MQTT-3.1.2-21] Password Flag=1 时必须有 Password
- [MQTT-3.1.2-22] Username=0 时 Password 必须为 0
- [MQTT-3.1.3-4] Client ID 必须是有效的 UTF-8
- [MQTT-3.1.3-5] Client ID 长度和字符限制

### 2. SUBSCRIBE / SUBACK 处理
**文件位置**: `handle_subscribe.zig`, `subscription.zig`

- ✅ 主题过滤器解析 (UTF-8 字符串)
- ✅ QoS 级别验证 (0、1、2)
- ✅ 订阅树层级结构管理
- ✅ 通配符支持
  - `+` 单级通配符 ([MQTT-4.7.1-3] 必须占据整个层级)
  - `#` 多级通配符 ([MQTT-4.7.1-2] 必须在末尾)
- ✅ 主题层级解析
  - `/test` → `["", "test"]` (保留空层级)
  - `a/b/c` → `["a", "b", "c"]`
- ✅ 主题过滤器验证函数 `validateTopicFilter()`
- ✅ SUBACK 响应 (Success/Failure 返回码)
- ✅ [MQTT-3.8.4-1] 服务器必须响应 SUBACK

**订阅树特性**:
- 使用 StringHashMap 实现层级树结构
- 支持精确匹配和通配符匹配
- 正确处理内存管理 (allocator.dupe 复制键)
- 递归匹配算法支持复杂主题层级

### 3. PUBLISH 消息处理
**文件位置**: `handle_publish.zig`, `main.zig`

- ✅ QoS 0/1/2 支持
  - QoS 0: At Most Once (Fire and Forget)
  - QoS 1: At Least Once (PUBACK 确认)
  - QoS 2: Exactly Once (PUBREC → PUBREL → PUBCOMP)
- ✅ 主题名称解析 (多级主题 `/a/b/c`)
- ✅ 固定头部 Flags 解析
  - DUP (重复标志)
  - QoS (服务质量)
  - RETAIN (保留标志)
- ✅ Packet ID 处理 (QoS 1/2 必需)
- ✅ Payload 提取
- ✅ QoS 确认响应
  - PUBACK (QoS 1)
  - PUBREC (QoS 2 第一步)
  - PUBCOMP (QoS 2 第三步)
- ✅ 消息转发给匹配订阅者
- ✅ 去重机制 (StringHashMap 追踪已发送客户端)
- ✅ no_local 支持 (MQTT 5.0,防止自转发)

**PUBREL 处理** (main.zig):
```zig
.PUBREL => {
    const packet_id = try reader.readTwoBytes();
    try publish.sendPubcomp(writer, client, packet_id);
}
```

### 4. UNSUBSCRIBE / UNSUBACK 处理
**文件位置**: `handle_unsubscribe.zig`, `subscription.zig`

- ✅ 取消订阅主题 (从订阅树移除)
- ✅ 多主题取消订阅支持
- ✅ UNSUBACK 响应 ([MQTT-3.10.4-4])
- ✅ 空节点自动清理
  - 递归删除无订阅者且无子节点的节点
  - `deinit_deep()` 正确释放资源
- ✅ 同步更新客户端订阅列表

### 5. PINGREQ / PINGRESP 心跳
**文件位置**: `main.zig`

- ✅ PINGREQ 处理 (客户端心跳)
- ✅ PINGRESP 自动响应 (0xD0 0x00)
- ✅ 最后活动时间更新 (`client.updateActivity()`)
- ✅ 符合 MQTT 3.1.1 规范

### 6. 客户端管理
**文件位置**: `client.zig`, `main.zig`

- ✅ 客户端结构完整定义
  - 基本信息 (ID、标识符、协议版本)
  - 连接状态 (is_connected、connect_time、last_activity)
  - MQTT 属性 (clean_start、keep_alive、session_expiry_interval)
  - 认证信息 (username、password)
  - 遗嘱消息 (will_topic、will_payload、will_qos、will_retain)
  - 订阅列表 (subscriptions)
  - 消息队列 (incoming_queue、outgoing_queue)
  - 流控参数 (receive_maximum、maximum_packet_size)
- ✅ 客户端生命周期管理
  - init/deinit 正确分配/释放资源
  - 线程安全的客户端标识符复制
- ✅ Packet ID 生成器 (避免 0)
- ✅ 订阅管理 (addSubscription、removeSubscription)
- ✅ 活动时间追踪

### 7. 协议解析器
**文件位置**: `packet.zig`

- ✅ PacketReader
  - 命令解析 (readCommand)
  - Remaining Length 解析 (可变长度编码)
  - UTF-8 字符串读取
  - Two Bytes / Single Byte 读取
  - 缓冲区边界检查
- ✅ PacketWriter
  - 控制包构建 (startPacket/finishPacket)
  - Remaining Length 编码
  - UTF-8 字符串写入
  - 批量字节写入 (writeBytes)
  - 流式写入 (writeToStream)
- ✅ 错误上下文追踪 (PacketError.byte_position)

### 8. 日志系统
**文件位置**: `logger.zig`

- ✅ 多级别日志 (debug、info、warn、err)
- ✅ 运行时日志级别控制
- ✅ 时间戳自动添加
- ✅ 条件编译支持 (Debug/Release 模式)

---

## ⚠️ 部分完成的功能 (需要改进)

### 1. QoS 2 消息流程 ⚠️
**当前状态**: 基础流程已实现,缺少持久化

**已实现**:
- ✅ PUBREC 发送
- ✅ PUBREL 接收处理
- ✅ PUBCOMP 发送

**待完善**:
- ❌ QoS 2 消息持久化 (防止重复投递)
- ❌ Packet ID 冲突检测
- ❌ 消息重传机制
- ❌ 状态机管理 (Published → PubrecReceived → PubcompSent)

**改进建议**:
```zig
// Client.zig 添加状态追踪
pub const Qos2State = enum {
    Published,      // 已发送 PUBLISH
    PubrecReceived, // 收到 PUBREC
    PubrelSent,     // 发送 PUBREL
    PubcompReceived // 收到 PUBCOMP (完成)
};

// 追踪正在进行的 QoS 2 消息
qos2_messages: std.AutoHashMap(u16, struct {
    state: Qos2State,
    message: Message,
    timestamp: i64,
}),
```

**相关规范**:
- [MQTT-4.3.3-1] QoS 2 消息必须保证仅投递一次

### 2. Retained 消息 ⚠️
**当前状态**: 已解析标志,未实现存储和转发

**已实现**:
- ✅ PUBLISH 包中 Retain 标志解析
- ✅ `PublishPacket.retain` 字段

**待完善**:
- ❌ Retained 消息存储
- ❌ 新订阅者接收保留消息
- ❌ Retain=1 且 Payload 为空时删除保留消息

**改进建议**:
```zig
// MqttBroker 添加保留消息存储
retained_messages: std.StringHashMap(struct {
    topic: []const u8,
    payload: []const u8,
    qos: mqtt.QoS,
    timestamp: i64,
}),

// 订阅时发送保留消息
pub fn subscribe(...) !void {
    // ... 添加到订阅树
    
    // 查找并发送匹配的保留消息
    var it = broker.retained_messages.iterator();
    while (it.next()) |entry| {
        if (topicMatchesFilter(entry.key_ptr.*, topic_filter)) {
            try sendRetainedMessage(client, entry.value_ptr.*);
        }
    }
}
```

**相关规范**:
- [MQTT-3.3.1-5] Retain=1 时服务器必须存储消息
- [MQTT-3.3.1-6] 新订阅者立即收到保留消息
- [MQTT-3.3.1-10] Payload 为空时删除保留消息

### 3. Will 消息 (遗嘱) ⚠️
**当前状态**: 已解析结构,未实现触发逻辑

**已实现**:
- ✅ Will 结构解析 (topic、payload、QoS、retain、delay_interval)
- ✅ Will Flag 验证
- ✅ `Client.will_*` 字段存储

**待完善**:
- ❌ 异常断开时发布 Will 消息
- ❌ 正常断开 (DISCONNECT) 时不发布
- ❌ Will Delay Interval 支持 (MQTT 5.0)
- ❌ Session Expiry 后延迟发布

**改进建议**:
```zig
// Client.deinit() 修改
pub fn deinit(self: *Client) void {
    // 检查是否需要发布 Will 消息
    if (self.will_topic) |topic| {
        if (!self.graceful_disconnect) {  // 非正常断开
            if (self.will_delay_interval == 0) {
                // 立即发布
                publishWillMessage(self);
            } else {
                // 延迟发布 (需要定时器)
                scheduleWillMessage(self, self.will_delay_interval);
            }
        }
    }
    
    // ... 原有清理逻辑
}

// 添加标志追踪是否正常断开
graceful_disconnect: bool = false,  // DISCONNECT 包时设为 true
```

**相关规范**:
- [MQTT-3.1.2-8] 连接异常断开时必须发布 Will 消息
- [MQTT-3.1.3-9] Will Delay Interval (MQTT 5.0)
- [MQTT-3.14.4-1] 正常 DISCONNECT 不发布 Will

### 4. Session 持久化 ❌
**当前状态**: 完全未实现

**已实现**:
- ✅ Clean Session 标志解析
- ✅ Session Expiry Interval 字段 (MQTT 5.0)

**待完善**:
- ❌ Clean Session=0 时保存会话状态
- ❌ 重连时恢复会话
- ❌ 持久化订阅列表
- ❌ 持久化未确认的 QoS 1/2 消息
- ❌ Session Expiry 超时清理

**改进建议**:
```zig
// 持久化接口设计
pub const SessionStore = struct {
    db: *sqlite.Database,  // 或文件系统
    
    pub fn saveSession(client_id: []const u8, session: SessionData) !void;
    pub fn loadSession(client_id: []const u8) ?SessionData;
    pub fn deleteSession(client_id: []const u8) !void;
};

pub const SessionData = struct {
    subscriptions: []Subscription,
    inflight_messages: []Message,
    expiry_time: i64,
};

// MqttBroker 添加
session_store: SessionStore,

// CONNECT 处理时检查
if (!clean_session) {
    if (session_store.loadSession(client_id)) |session| {
        // 恢复订阅
        for (session.subscriptions) |sub| {
            try subscriptions.subscribe(sub.topic_filter, client);
        }
        // 重传未确认消息
        for (session.inflight_messages) |msg| {
            try resendMessage(client, msg);
        }
    }
}
```

**相关规范**:
- [MQTT-3.1.2-4] Clean Session=0 时服务器必须恢复会话
- [MQTT-3.1.2-5] 存储订阅和 QoS 1/2 消息
- [MQTT-3.1.3-2] Session Expiry Interval (MQTT 5.0)

### 5. Keep Alive 超时检测 ⚠️
**当前状态**: 已记录时间,未实现超时检测

**已实现**:
- ✅ Keep Alive 值存储 (`client.keep_alive`)
- ✅ 最后活动时间追踪 (`client.last_activity`)
- ✅ PINGREQ/PINGRESP 更新活动时间

**待完善**:
- ❌ 后台线程定期检查超时客户端
- ❌ 超时自动断开连接
- ❌ 1.5 倍 Keep Alive 时间容忍度

**改进建议**:
```zig
// MqttBroker 添加监控线程
fn startKeepAliveMonitor(self: *MqttBroker) !void {
    const thread = try std.Thread.spawn(.{}, keepAliveMonitorLoop, .{self});
    thread.detach();
}

fn keepAliveMonitorLoop(broker: *MqttBroker) void {
    while (true) {
        std.Thread.sleep(5 * std.time.ns_per_s);  // 每 5 秒检查一次
        
        const now = time.milliTimestamp();
        var it = broker.clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr.*;
            if (client.keep_alive == 0) continue;  // Keep Alive=0 表示不检查
            
            const timeout_ms = client.keep_alive * 1000 * 1.5;  // 1.5 倍容忍
            if (now - client.last_activity > timeout_ms) {
                logger.warn("Client {s} keep-alive timeout, disconnecting", 
                    .{client.identifer});
                // 断开连接并发布 Will 消息
                disconnectClient(broker, client, true);
            }
        }
    }
}
```

**相关规范**:
- [MQTT-3.1.2-24] 超过 1.5 倍 Keep Alive 无活动应断开
- [MQTT-3.1.2-22] Keep Alive=0 表示关闭检测

### 6. 消息队列与流控 ⚠️
**当前状态**: 已定义数据结构,未启用

**已实现**:
- ✅ `Client.incoming_queue` 和 `outgoing_queue` 定义
- ✅ `receive_maximum` 字段 (MQTT 5.0)

**待完善**:
- ❌ 实际使用消息队列
- ❌ Receive Maximum 流控限制
- ❌ 队列满时处理策略
- ❌ QoS 1/2 消息确认后出队

**改进建议**:
```zig
// 转发消息时使用队列
pub fn forwardMessage(client: *Client, message: Message) !void {
    // 检查流控限制
    if (client.inflight_messages.count() >= client.receive_maximum) {
        logger.warn("Client {s} receive maximum reached, queuing message", 
            .{client.identifer});
        try client.outgoing_queue.append(message);
        return;
    }
    
    // 发送消息
    try sendMessage(client, message);
    
    // QoS > 0 时加入 inflight 追踪
    if (message.qos != .AtMostOnce) {
        try client.inflight_messages.put(message.packet_id.?, message);
    }
}

// PUBACK/PUBCOMP 收到后出队
pub fn handleAcknowledgment(client: *Client, packet_id: u16) !void {
    _ = client.inflight_messages.remove(packet_id);
    
    // 检查队列是否有待发送消息
    if (client.outgoing_queue.items.len > 0) {
        const next_msg = client.outgoing_queue.orderedRemove(0);
        try forwardMessage(client, next_msg);
    }
}
```

**相关规范**:
- [MQTT-3.3.4-1] Receive Maximum 限制未确认消息数
- [MQTT-4.9-1] 服务器必须按接收顺序传递消息

---

## ❌ 未实现的关键功能

### 1. 主题名称验证 (PUBLISH)
**优先级**: 🔴 HIGH

**问题描述**:
当前只在 SUBSCRIBE 时验证主题过滤器,PUBLISH 的主题名称未验证。

**MQTT 规范要求**:
- [MQTT-4.7.3-1] 主题名称不能包含通配符 `+` 或 `#`
- [MQTT-4.7.3-2] 主题名称长度必须 > 0
- [MQTT-4.7.3-3] 主题名称不能包含空字符 U+0000

**实现建议**:
```zig
// subscription.zig 添加
fn validateTopicName(topic: []const u8) !void {
    // 空主题检查
    if (topic.len == 0) {
        return error.InvalidTopicName;
    }
    
    // 禁止通配符
    if (std.mem.indexOf(u8, topic, "+") != null) {
        std.debug.print("ERROR: Topic name cannot contain '+' wildcard\n", .{});
        return error.InvalidTopicName;
    }
    if (std.mem.indexOf(u8, topic, "#") != null) {
        std.debug.print("ERROR: Topic name cannot contain '#' wildcard\n", .{});
        return error.InvalidTopicName;
    }
    
    // 检查空字符
    if (std.mem.indexOf(u8, topic, &[_]u8{0}) != null) {
        std.debug.print("ERROR: Topic name cannot contain null character\n", .{});
        return error.InvalidTopicName;
    }
    
    // UTF-8 验证
    if (!std.unicode.utf8ValidateSlice(topic)) {
        return error.InvalidTopicName;
    }
}

// handle_publish.zig 中调用
pub fn read(reader: *packet.Reader) !PublishPacket {
    // ... 读取主题
    const topic = try reader.readUTF8String(false) orelse {
        return error.MissingTopic;
    };
    
    // 验证主题名称
    try validateTopicName(topic);
    
    // ... 继续处理
}
```

**测试用例**:
- ✅ 正常主题: `home/temperature`, `/test`, `a/b/c`
- ❌ 包含通配符: `home/+/temp`, `home/#`
- ❌ 空主题: ``
- ❌ 包含空字符: `home\x00temp`

### 2. UTF-8 字符串全面验证
**优先级**: 🟡 MEDIUM

**问题描述**:
只验证了 Client ID,其他字段未验证 UTF-8 合法性。

**MQTT 规范要求**:
- [MQTT-1.5.3-1] 所有 UTF-8 编码字符串必须格式良好
- [MQTT-1.5.3-2] 不能包含空字符 U+0000
- [MQTT-1.5.3-3] 不能包含 U+D800 到 U+DFFF (代理对)

**需要验证的字段**:
- ❌ Will Topic
- ❌ Will Payload (如果是文本)
- ❌ Username
- ❌ Password (虽然通常是二进制,但标准要求 UTF-8)
- ❌ PUBLISH Topic
- ❌ SUBSCRIBE Topic Filter

**实现建议**:
```zig
// packet.zig 修改 readUTF8String
pub fn readUTF8String(self: *Reader, allow_zero_length: bool) !?[]u8 {
    // ... 现有读取逻辑
    
    const string = self.buffer[self.pos..][0..length];
    
    // UTF-8 验证
    if (!std.unicode.utf8ValidateSlice(string)) {
        std.debug.print("ERROR: Invalid UTF-8 string\n", .{});
        return PacketReaderError.MalformedPacket;
    }
    
    // 检查禁止字符
    for (string) |byte| {
        if (byte == 0) {
            std.debug.print("ERROR: UTF-8 string contains null character\n", .{});
            return PacketReaderError.MalformedPacket;
        }
    }
    
    // 检查代理对 (U+D800 到 U+DFFF)
    var i: usize = 0;
    while (i < string.len) {
        const len = std.unicode.utf8ByteSequenceLength(string[i]) catch {
            return PacketReaderError.MalformedPacket;
        };
        if (i + len > string.len) return PacketReaderError.MalformedPacket;
        
        const codepoint = std.unicode.utf8Decode(string[i..][0..len]) catch {
            return PacketReaderError.MalformedPacket;
        };
        
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
            std.debug.print("ERROR: UTF-8 string contains surrogate pair\n", .{});
            return PacketReaderError.MalformedPacket;
        }
        
        i += len;
    }
    
    self.pos += length;
    return string;
}
```

### 3. Packet ID 冲突检测
**优先级**: 🟡 MEDIUM

**问题描述**:
Packet ID 生成器只是简单递增,未检查是否与未确认消息冲突。

**MQTT 规范要求**:
- [MQTT-2.3.1-1] Packet ID 在未确认前不能重用
- [MQTT-2.3.1-2] Packet ID 必须非零

**当前实现**:
```zig
pub fn nextPacketId(self: *Client) u16 {
    self.packet_id_counter +%= 1;
    if (self.packet_id_counter == 0) self.packet_id_counter = 1;
    return self.packet_id_counter;  // ⚠️ 未检查冲突
}
```

**改进建议**:
```zig
pub fn nextPacketId(self: *Client) !u16 {
    var attempts: u32 = 0;
    while (attempts < 65535) : (attempts += 1) {
        self.packet_id_counter +%= 1;
        if (self.packet_id_counter == 0) self.packet_id_counter = 1;
        
        // 检查是否已被使用
        if (!self.inflight_messages.contains(self.packet_id_counter)) {
            return self.packet_id_counter;
        }
    }
    
    // 所有 ID 都被占用 (极端情况)
    logger.err("Client {s}: All packet IDs are in use!", .{self.identifer});
    return error.PacketIdExhausted;
}
```

### 4. 消息转发 QoS 降级问题
**优先级**: 🔴 HIGH

**问题描述**:
当前转发时强制使用 QoS 0,未考虑订阅者的 QoS 级别。

**当前实现** (main.zig):
```zig
try publish.writePublish(
    writer,
    publish_packet.topic,
    publish_packet.payload,
    .AtMostOnce,  // ⚠️ 强制 QoS 0
    publish_packet.retain,
    false,
    null,
);
```

**MQTT 规范要求**:
- [MQTT-3.3.5-1] 转发 QoS = min(发布 QoS, 订阅 QoS)

**改进建议**:
```zig
// 1. Subscription 结构添加到订阅树
// subscription.zig Node 修改
const Node = struct {
    children: std.StringHashMap(Node),
    subscribers: ArrayList(struct {
        client: *Client,
        qos: mqtt.QoS,  // 添加订阅时的 QoS
    }),
};

// 2. match 函数返回带 QoS 的订阅者列表
pub fn match(...) !ArrayList(struct { client: *Client, qos: mqtt.QoS }) {
    // ...
}

// 3. 转发时计算实际 QoS
for (matched_clients.items) |subscriber| {
    const forward_qos = @min(publish_packet.qos, subscriber.qos);
    
    const packet_id = if (forward_qos != .AtMostOnce) 
        try subscriber.client.nextPacketId() 
    else 
        null;
    
    try publish.writePublish(
        writer,
        publish_packet.topic,
        publish_packet.payload,
        forward_qos,  // ✅ 使用协商后的 QoS
        publish_packet.retain,
        false,
        packet_id,
    );
    
    // QoS > 0 时加入 inflight 追踪
    if (forward_qos != .AtMostOnce) {
        try subscriber.client.inflight_messages.put(packet_id.?, ...);
    }
}
```

### 5. 并发安全问题
**优先级**: 🔴 HIGH

**问题描述**:
多个客户端线程共享 `SubscriptionTree`,无锁保护可能导致数据竞争。

**风险场景**:
- 线程 A 正在订阅主题 (修改树结构)
- 线程 B 同时发布消息 (遍历树结构)
- 可能导致: 段错误、订阅丢失、重复订阅

**改进建议**:
```zig
// subscription.zig
pub const SubscriptionTree = struct {
    root: Node,
    mutex: std.Thread.Mutex,  // 添加互斥锁
    
    pub fn init(allocator: Allocator) SubscriptionTree {
        return SubscriptionTree{
            .root = Node.init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn subscribe(self: *SubscriptionTree, topic: []const u8, client: *Client) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // ... 原有逻辑
    }
    
    pub fn unsubscribe(self: *SubscriptionTree, topic: []const u8, client: *Client) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // ... 原有逻辑
    }
    
    pub fn match(self: *SubscriptionTree, topic: []const u8, ...) !ArrayList(*Client) {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // ... 原有逻辑
    }
}
```

**性能优化**:
- 考虑使用读写锁 `std.Thread.RwLock` (多读单写)
- match 操作只需读锁,subscribe/unsubscribe 需写锁

---

## 🚀 MQTT 5.0 高级特性 (未实现)

### 1. Shared Subscriptions (共享订阅)
**优先级**: 🟢 LOW

**功能描述**:
多个订阅者以负载均衡方式接收消息。

**主题格式**: `$share/{GroupName}/{TopicFilter}`

**示例**:
```
客户端 A: SUBSCRIBE $share/workers/task/#
客户端 B: SUBSCRIBE $share/workers/task/#
客户端 C: SUBSCRIBE $share/workers/task/#

发布 task/job1 → 只有一个客户端收到 (轮询分配)
```

**实现建议**:
```zig
// subscription.zig 添加共享订阅支持
pub const SharedGroup = struct {
    name: []const u8,
    topic_filter: []const u8,
    subscribers: ArrayList(*Client),
    next_index: usize = 0,  // 轮询索引
    
    pub fn getNextSubscriber(self: *SharedGroup) *Client {
        const client = self.subscribers.items[self.next_index];
        self.next_index = (self.next_index + 1) % self.subscribers.items.len;
        return client;
    }
};

// MqttBroker 添加
shared_subscriptions: std.StringHashMap(SharedGroup),

// 订阅时解析 $share 前缀
pub fn subscribe(..., topic_filter: []const u8, ...) !void {
    if (std.mem.startsWith(u8, topic_filter, "$share/")) {
        // 解析: $share/{group}/{filter}
        var parts = std.mem.split(u8, topic_filter[7..], "/");
        const group_name = parts.next() orelse return error.InvalidSharedSubscription;
        const filter = parts.rest();
        
        // 添加到共享组
        const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{group_name, filter});
        var group = broker.shared_subscriptions.getOrPut(key) catch ...;
        if (!group.found_existing) {
            group.value_ptr.* = SharedGroup{
                .name = group_name,
                .topic_filter = filter,
                .subscribers = ArrayList(*Client).init(allocator),
            };
        }
        try group.value_ptr.subscribers.append(client);
    } else {
        // 普通订阅
        try broker.subscriptions.subscribe(topic_filter, client);
    }
}

// 转发时处理共享订阅
for (broker.shared_subscriptions.values()) |*group| {
    if (topicMatchesFilter(publish_topic, group.topic_filter)) {
        const client = group.getNextSubscriber();  // 轮询
        try forwardMessage(client, message);
    }
}
```

**相关规范**:
- [MQTT-4.8.2] Shared Subscription 定义

### 2. Subscription Identifiers (订阅标识符)
**优先级**: 🟢 LOW

**功能描述**:
客户端为每个订阅分配标识符,转发时返回此标识符。

**作用**: 客户端可以识别消息来自哪个订阅。

**实现建议**:
```zig
// Client.Subscription 添加
subscription_identifier: ?u32,

// SUBSCRIBE 包解析时读取
// handle_subscribe.zig
pub fn read(...) !*SubscribePacket {
    // ... 读取 Packet ID
    
    // MQTT 5.0: 读取 Properties
    if (protocol_version == .V5_0) {
        const props_len = try reader.readVariableByteInteger();
        // 解析 Subscription Identifier (0x0B)
        while (reader.pos < props_end) {
            const prop_id = try reader.readByte();
            if (prop_id == 0x0B) {
                sp.subscription_identifier = try reader.readVariableByteInteger();
            }
        }
    }
    
    // ...
}

// PUBLISH 转发时添加标识符
pub fn writePublish(..., subscription_ids: ?[]u32) !void {
    // ... 写入固定头部和主题
    
    // MQTT 5.0: 写入 Properties
    if (protocol_version == .V5_0 and subscription_ids != null) {
        // 写入 Property Length
        var props_buf: [256]u8 = undefined;
        var props_len: usize = 0;
        
        for (subscription_ids.?) |id| {
            props_buf[props_len] = 0x0B;  // Subscription Identifier
            props_len += 1;
            props_len += encodeVariableByteInteger(id, props_buf[props_len..]);
        }
        
        try writer.writeVariableByteInteger(props_len);
        try writer.writeBytes(props_buf[0..props_len]);
    }
    
    // ...
}
```

### 3. Topic Aliases (主题别名)
**优先级**: 🟢 LOW

**功能描述**:
用 2 字节数字代替主题名称,减少传输开销。

**流程**:
1. CONNECT: 客户端声明支持的最大别名数
2. PUBLISH: 首次发送完整主题 + 别名 (如 `"home/temp"`, alias=1)
3. 后续: 只发送别名 (topic="", alias=1)

**实现建议**:
```zig
// Client 添加别名映射
topic_aliases: std.AutoHashMap(u16, []const u8),  // alias → topic
reverse_aliases: std.StringHashMap(u16),          // topic → alias

// PUBLISH 读取时解析
pub fn read(reader: *packet.Reader, client: *Client) !PublishPacket {
    // ... 读取主题
    var topic = try reader.readUTF8String(false) orelse "";
    
    // MQTT 5.0: 读取 Properties
    var topic_alias: ?u16 = null;
    if (protocol_version == .V5_0) {
        // ... 解析 Topic Alias (0x23)
        if (prop_id == 0x23) {
            topic_alias = try reader.readTwoBytes();
        }
    }
    
    // 处理别名
    if (topic_alias) |alias| {
        if (topic.len == 0) {
            // 使用已有别名
            topic = client.topic_aliases.get(alias) orelse {
                return error.InvalidTopicAlias;
            };
        } else {
            // 注册新别名
            try client.topic_aliases.put(alias, try allocator.dupe(u8, topic));
        }
    }
    
    // ...
}
```

**相关规范**:
- [MQTT-3.3.2-6] Topic Alias 必须在允许范围内
- [MQTT-3.3.2-7] Topic Alias=0 无效

### 4. Request/Response Pattern
**优先级**: 🟢 LOW

**功能描述**:
支持请求-响应通信模式。

**MQTT 5.0 属性**:
- **Response Topic**: 响应消息应发送到的主题
- **Correlation Data**: 关联请求和响应的二进制数据

**示例流程**:
```
客户端 A 发布请求:
  Topic: request/calculate
  Response Topic: response/client-a
  Correlation Data: 0x1234
  Payload: {"operation": "add", "a": 5, "b": 3}

服务端处理后发布响应:
  Topic: response/client-a
  Correlation Data: 0x1234
  Payload: {"result": 8}
```

**实现建议**:
```zig
// PublishPacket 添加
response_topic: ?[]const u8,
correlation_data: ?[]const u8,

// 读取时解析 Properties (0x08=Response Topic, 0x09=Correlation Data)
// 转发时保留这些属性
```

### 5. Enhanced Authentication (增强认证)
**优先级**: 🟢 LOW

**功能描述**:
支持 SCRAM、Kerberos、OAuth 2.0 等复杂认证机制。

**MQTT 5.0 流程**:
1. CONNECT 包含 Authentication Method
2. 服务器发送 AUTH (Continue)
3. 客户端发送 AUTH (Continue)
4. ... 多轮握手
5. 服务器发送 CONNACK (Success)

**实现建议**:
```zig
// 添加 AUTH 包处理
.AUTH => {
    // 读取 Authentication Method 和 Authentication Data
    const auth_method = try reader.readUTF8String(false);
    const auth_data = try reader.readBinaryData();
    
    // 调用认证处理器
    const result = try authenticator.handleAuth(auth_method, auth_data, client);
    
    if (result.continue_auth) {
        // 发送 AUTH Continue
        try sendAuth(writer, client, result.auth_data);
    } else {
        // 发送 CONNACK
        const reason_code = if (result.success) .Success else .NotAuthorized;
        try connect.connack(writer, &client.stream, reason_code);
    }
}
```

### 6. Server Redirect (服务器重定向)
**优先级**: 🟢 LOW

**功能描述**:
服务器在 CONNACK 或 DISCONNECT 中指示客户端连接到另一个服务器。

**使用场景**:
- 负载均衡
- 服务器维护
- 地理位置优化

**实现建议**:
```zig
// connack 添加 Server Reference 属性
pub fn connack(
    writer: *packet.Writer, 
    stream: *net.Stream, 
    reason_code: mqtt.ReasonCode,
    server_reference: ?[]const u8,  // 重定向地址
) !void {
    try writer.startPacket(mqtt.Command.CONNACK);
    try writer.writeByte(connect_acknowledge);
    try writer.writeByte(@intFromEnum(reason_code));
    
    // MQTT 5.0 Properties
    if (server_reference) |ref| {
        var props_buf: [256]u8 = undefined;
        var props_len: usize = 0;
        
        // Property: Server Reference (0x1C)
        props_buf[props_len] = 0x1C;
        props_len += 1;
        // 写入字符串
        // ...
        
        try writer.writeVariableByteInteger(props_len);
        try writer.writeBytes(props_buf[0..props_len]);
    } else {
        try writer.writeByte(0);  // No properties
    }
    
    try writer.finishPacket();
    try writer.writeToStream(stream);
}

// 负载均衡示例
if (broker.clients.count() > MAX_CLIENTS_PER_SERVER) {
    const redirect_server = loadBalancer.getNextServer();
    try connect.connack(writer, stream, .ServerMoved, redirect_server);
    return;
}
```

---

## 📝 文档状态

本文档持续更新中,将分以下部分完成:

- ✅ **Part 1**: 已实现功能清单
- ✅ **Part 2**: 部分完成功能详解
- ✅ **Part 3**: 未实现关键功能
- ✅ **Part 4**: MQTT 5.0 高级特性
- ⏳ **Part 5**: 实施路线图 (待补充)
- ⏳ **Part 6**: 测试用例清单 (待补充)
- ⏳ **Part 7**: 性能优化建议 (待补充)

---

最后更新: 2025年10月23日
