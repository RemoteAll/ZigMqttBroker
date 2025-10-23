# MQTT Broker 测试用例清单

**项目**: mqtt-broker1  
**创建日期**: 2025年10月23日  
**版本**: 1.0

本文档列出了完整的测试用例,用于验证 MQTT 协议符合度和功能正确性。

---

## 📋 测试分类

### 1. 单元测试 (Unit Tests)
针对独立函数和模块的测试。

### 2. 集成测试 (Integration Tests)
测试多个模块协同工作。

### 3. 协议符合性测试 (Compliance Tests)
验证是否符合 MQTT 标准规范。

### 4. 性能测试 (Performance Tests)
验证吞吐量、延迟、并发性能。

### 5. 压力测试 (Stress Tests)
极端条件下的稳定性测试。

---

## ✅ CONNECT / CONNACK 测试

### 单元测试

#### TC-CONNECT-001: 解析有效的 CONNECT 包
**优先级**: 🔴 HIGH  
**文件**: `handle_connect_test.zig`

```zig
test "CONNECT - valid packet parsing" {
    const allocator = std.testing.allocator;
    
    // 构造 CONNECT 包
    const connect_bytes = [_]u8{
        // Fixed Header
        0x10,  // CONNECT
        0x1A,  // Remaining Length = 26
        
        // Variable Header
        0x00, 0x04, 'M', 'Q', 'T', 'T',  // Protocol Name
        0x04,  // Protocol Version (3.1.1)
        0xC2,  // Connect Flags (username=1, password=1, clean_session=1)
        0x00, 0x3C,  // Keep Alive = 60
        
        // Payload
        0x00, 0x05, 't', 'e', 's', 't', '1',  // Client ID
        0x00, 0x04, 'u', 's', 'e', 'r',       // Username
        0x00, 0x04, 'p', 'a', 's', 's',       // Password
    };
    
    var reader = packet.Reader.init(&connect_bytes);
    try reader.start(connect_bytes.len);
    
    _ = try reader.readCommand();
    _ = try reader.readRemainingLength();
    
    const cp = try connect.read(&reader, allocator);
    defer cp.deinit();
    
    // 验证
    try std.testing.expectEqualStrings("MQTT", cp.protocol_name);
    try std.testing.expectEqual(@as(u8, 4), cp.protocol_version);
    try std.testing.expectEqual(true, cp.connect_flags.clean_session);
    try std.testing.expectEqual(@as(u16, 60), cp.keep_alive);
    try std.testing.expectEqualStrings("test1", cp.client_identifier);
    try std.testing.expectEqualStrings("user", cp.username.?);
    try std.testing.expectEqualStrings("pass", cp.password.?);
    try std.testing.expectEqual(@as(usize, 0), cp.getErrors().len);
}
```

#### TC-CONNECT-002: 拒绝无效的协议名称
**优先级**: 🔴 HIGH

```zig
test "CONNECT - invalid protocol name" {
    // Protocol Name = "MQXX" (应该是 "MQTT")
    // 预期: errors 包含 ProtocolNameNotMQTT
}
```

#### TC-CONNECT-003: 拒绝不支持的协议版本
**优先级**: 🔴 HIGH

```zig
test "CONNECT - unsupported protocol version" {
    // Protocol Version = 6 (不存在)
    // 预期: errors 包含 UnsupportedVersion
}
```

#### TC-CONNECT-004: Client ID 验证
**优先级**: 🔴 HIGH

```zig
test "CONNECT - client ID validation" {
    // 子测试
    // 1. 空 Client ID + Clean Session=0 → 错误
    // 2. Client ID 长度 > 23 → 警告但允许
    // 3. Client ID 包含特殊字符 → 警告但允许
    // 4. 有效 Client ID → 成功
}
```

#### TC-CONNECT-005: Will 消息验证
**优先级**: 🟡 MEDIUM

```zig
test "CONNECT - will message validation" {
    // 1. Will Flag=1, Will Topic 为空 → 错误
    // 2. Will Flag=1, Will Message 为空 → 错误
    // 3. Will Flag=0, Will QoS != 0 → 错误
    // 4. Will QoS > 2 → 错误
}
```

#### TC-CONNECT-006: Username/Password 验证
**优先级**: 🟡 MEDIUM

```zig
test "CONNECT - username/password validation" {
    // 1. Username Flag=0, Password Flag=1 → 错误
    // 2. Username Flag=1, 无 Username 字段 → 错误
    // 3. Password Flag=1, 无 Password 字段 → 错误
}
```

### 集成测试

#### TC-CONNECT-INT-001: 完整连接流程
**优先级**: 🔴 HIGH

```zig
test "CONNECT - full connection flow" {
    // 1. 启动测试服务器
    // 2. 客户端发送 CONNECT
    // 3. 验证服务器响应 CONNACK (Success)
    // 4. 验证客户端被添加到 clients 列表
    // 5. 断开连接
}
```

#### TC-CONNECT-INT-002: 连接拒绝场景
**优先级**: 🟡 MEDIUM

```zig
test "CONNECT - connection rejection scenarios" {
    // 1. 无效 Client ID → CONNACK (ClientIdentifierNotValid)
    // 2. 认证失败 → CONNACK (BadUserNameOrPassword)
    // 3. 协议版本不支持 → CONNACK (UnsupportedProtocolVersion)
}
```

### 协议符合性测试

#### TC-CONNECT-COMP-001: [MQTT-3.1.2-3] Reserved bit 必须为 0
```zig
test "CONNECT - reserved bit must be 0" {
    // Connect Flags 的 bit 0 设为 1
    // 预期: errors 包含 MalformedPacket
}
```

#### TC-CONNECT-COMP-002: [MQTT-3.1.2-22] Password 依赖 Username
```zig
test "CONNECT - password requires username" {
    // Username Flag=0, Password Flag=1
    // 预期: errors 包含 PasswordMustNotBeSet
}
```

---

## ✅ PUBLISH 测试

### 单元测试

#### TC-PUBLISH-001: 解析 QoS 0 PUBLISH 包
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - parse QoS 0 packet" {
    const allocator = std.testing.allocator;
    
    const publish_bytes = [_]u8{
        0x30,  // PUBLISH, QoS=0, Retain=0, DUP=0
        0x0D,  // Remaining Length = 13
        
        // Variable Header
        0x00, 0x09, '/', 't', 'e', 's', 't', '/', 'm', 's', 'g',  // Topic
        
        // Payload
        'h', 'e', 'l', 'l', 'o',
    };
    
    var reader = packet.Reader.init(&publish_bytes);
    try reader.start(publish_bytes.len);
    
    _ = try reader.readCommand();
    _ = try reader.readRemainingLength();
    
    const pp = try publish.read(&reader);
    
    // 验证
    try std.testing.expectEqualStrings("/test/msg", pp.topic);
    try std.testing.expectEqualStrings("hello", pp.payload);
    try std.testing.expectEqual(mqtt.QoS.AtMostOnce, pp.qos);
    try std.testing.expectEqual(false, pp.retain);
    try std.testing.expectEqual(false, pp.dup);
    try std.testing.expectEqual(@as(?u16, null), pp.packet_id);
}
```

#### TC-PUBLISH-002: 解析 QoS 1 PUBLISH 包 (带 Packet ID)
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - parse QoS 1 packet with packet ID" {
    // QoS=1, 包含 Packet ID = 1234
    // 预期: packet_id = 1234
}
```

#### TC-PUBLISH-003: 解析 QoS 2 PUBLISH 包
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - parse QoS 2 packet" {
    // QoS=2, Packet ID = 5678
    // 预期: qos = ExactlyOnce, packet_id = 5678
}
```

#### TC-PUBLISH-004: 主题名称验证
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - topic name validation" {
    // 子测试
    // 1. 空主题 → 错误
    // 2. 包含 '+' → 错误
    // 3. 包含 '#' → 错误
    // 4. 有效主题 → 成功
}
```

#### TC-PUBLISH-005: 构造 PUBLISH 包
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - construct packet" {
    const allocator = std.testing.allocator;
    var writer = try packet.Writer.init(allocator);
    defer writer.deinit();
    
    try publish.writePublish(
        writer,
        "test/topic",
        "payload data",
        .AtLeastOnce,
        false,  // retain
        false,  // dup
        1234,   // packet_id
    );
    
    // 验证生成的字节流
    const buffer = writer.buffer[0..writer.pos];
    
    // Fixed Header
    try std.testing.expectEqual(@as(u8, 0x32), buffer[0]);  // PUBLISH, QoS=1
    
    // ... 验证其他字段
}
```

### 集成测试

#### TC-PUBLISH-INT-001: 单个订阅者接收消息
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - single subscriber receives message" {
    // 1. 客户端 A 订阅 "test/topic"
    // 2. 客户端 B 发布到 "test/topic"
    // 3. 验证客户端 A 收到消息
}
```

#### TC-PUBLISH-INT-002: 多个订阅者接收消息
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - multiple subscribers receive message" {
    // 1. 客户端 A, B, C 订阅 "test/#"
    // 2. 客户端 D 发布到 "test/msg"
    // 3. 验证 A, B, C 都收到消息
}
```

#### TC-PUBLISH-INT-003: 通配符订阅匹配
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - wildcard subscription matching" {
    // 1. 客户端 A 订阅 "sport/+/player1"
    // 2. 发布到 "sport/tennis/player1" → A 收到
    // 3. 发布到 "sport/soccer/player1" → A 收到
    // 4. 发布到 "sport/tennis/player2" → A 不收到
}
```

#### TC-PUBLISH-INT-004: QoS 转发降级
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - QoS downgrade on forward" {
    // 场景 1: 订阅 QoS 0, 发布 QoS 2 → 转发 QoS 0
    // 场景 2: 订阅 QoS 2, 发布 QoS 1 → 转发 QoS 1
    // 场景 3: 订阅 QoS 2, 发布 QoS 2 → 转发 QoS 2
}
```

#### TC-PUBLISH-INT-005: QoS 1 确认流程
**优先级**: 🔴 HIGH

```zig
test "PUBLISH - QoS 1 acknowledgment flow" {
    // 1. 客户端发送 QoS 1 PUBLISH
    // 2. 验证服务器响应 PUBACK
    // 3. Packet ID 匹配
}
```

#### TC-PUBLISH-INT-006: QoS 2 四步握手
**优先级**: 🟡 MEDIUM

```zig
test "PUBLISH - QoS 2 four-way handshake" {
    // 1. 客户端发送 PUBLISH (QoS 2)
    // 2. 服务器响应 PUBREC
    // 3. 客户端发送 PUBREL
    // 4. 服务器响应 PUBCOMP
}
```

#### TC-PUBLISH-INT-007: no_local 支持
**优先级**: 🟡 MEDIUM

```zig
test "PUBLISH - no_local flag support" {
    // 1. 客户端 A 订阅 "test/#" (no_local=true)
    // 2. 客户端 A 发布到 "test/msg"
    // 3. 验证客户端 A 不收到自己的消息
    // 4. 其他订阅者正常收到
}
```

### 协议符合性测试

#### TC-PUBLISH-COMP-001: [MQTT-3.3.5-1] QoS 降级
```zig
test "PUBLISH - QoS downgrade as per spec" {
    // 转发 QoS = min(发布 QoS, 订阅 QoS)
}
```

#### TC-PUBLISH-COMP-002: [MQTT-4.7.3-1] 主题名称不能包含通配符
```zig
test "PUBLISH - topic name cannot contain wildcards" {
    // 发布到 "test/+/msg" → 错误
    // 发布到 "test/#" → 错误
}
```

---

## ✅ SUBSCRIBE / UNSUBSCRIBE 测试

### 单元测试

#### TC-SUBSCRIBE-001: 解析单主题 SUBSCRIBE
**优先级**: 🔴 HIGH

```zig
test "SUBSCRIBE - parse single topic" {
    // SUBSCRIBE Packet ID=1, Topic="test/topic", QoS=1
    // 预期: 解析成功
}
```

#### TC-SUBSCRIBE-002: 解析多主题 SUBSCRIBE
**优先级**: 🟡 MEDIUM

```zig
test "SUBSCRIBE - parse multiple topics" {
    // SUBSCRIBE 包含 3 个主题
    // 预期: topics.items.len = 3
}
```

#### TC-SUBSCRIBE-003: 主题过滤器验证
**优先级**: 🔴 HIGH

```zig
test "SUBSCRIBE - topic filter validation" {
    // 1. "sport/+/player1" → 有效
    // 2. "sport/#" → 有效
    // 3. "sport/+" → 有效
    // 4. "sport/+tennis" → 错误 (+ 必须占据整层)
    // 5. "sport/#/player" → 错误 (# 必须在末尾)
}
```

### 集成测试

#### TC-SUBSCRIBE-INT-001: 订阅后立即接收保留消息
**优先级**: 🟡 MEDIUM

```zig
test "SUBSCRIBE - receive retained messages immediately" {
    // 1. 发布保留消息到 "test/retained"
    // 2. 客户端订阅 "test/retained"
    // 3. 验证客户端立即收到保留消息
}
```

#### TC-SUBSCRIBE-INT-002: 通配符订阅匹配多个保留消息
**优先级**: 🟡 MEDIUM

```zig
test "SUBSCRIBE - wildcard matches multiple retained" {
    // 1. 发布保留消息到 "test/a", "test/b", "test/c"
    // 2. 客户端订阅 "test/#"
    // 3. 验证客户端收到 3 条保留消息
}
```

#### TC-UNSUBSCRIBE-INT-001: 取消订阅后不再接收消息
**优先级**: 🔴 HIGH

```zig
test "UNSUBSCRIBE - stop receiving after unsubscribe" {
    // 1. 客户端订阅 "test/topic"
    // 2. 验证能收到消息
    // 3. 客户端取消订阅
    // 4. 再次发布
    // 5. 验证客户端不再收到消息
}
```

### 协议符合性测试

#### TC-SUBSCRIBE-COMP-001: [MQTT-3.8.4-1] 必须响应 SUBACK
```zig
test "SUBSCRIBE - server must respond with SUBACK" {
    // 发送 SUBSCRIBE
    // 预期: 收到 SUBACK
}
```

#### TC-UNSUBSCRIBE-COMP-001: [MQTT-3.10.4-4] 必须响应 UNSUBACK
```zig
test "UNSUBSCRIBE - server must respond with UNSUBACK" {
    // 发送 UNSUBSCRIBE
    // 预期: 收到 UNSUBACK (即使未订阅)
}
```

---

## ✅ Retained 消息测试

### 集成测试

#### TC-RETAINED-001: 存储和检索保留消息
**优先级**: 🟡 MEDIUM

```zig
test "RETAINED - store and retrieve" {
    // 1. 发布 Retain=1 消息到 "test/retain"
    // 2. 新客户端订阅 "test/retain"
    // 3. 验证收到保留消息
}
```

#### TC-RETAINED-002: 空 Payload 删除保留消息
**优先级**: 🟡 MEDIUM

```zig
test "RETAINED - empty payload deletes retained" {
    // 1. 发布 Retain=1 消息到 "test/retain"
    // 2. 发布 Retain=1, Payload="" 到 "test/retain"
    // 3. 新订阅者应不收到保留消息
}
```

#### TC-RETAINED-003: 保留消息 QoS 保持
**优先级**: 🟡 MEDIUM

```zig
test "RETAINED - QoS is preserved" {
    // 1. 发布 Retain=1, QoS=2 消息
    // 2. 新订阅者订阅 QoS=2
    // 3. 验证收到 QoS=2 保留消息
}
```

### 协议符合性测试

#### TC-RETAINED-COMP-001: [MQTT-3.3.1-5] Retain=1 时存储
```zig
test "RETAINED - store when retain=1" {
    // 验证服务器存储了保留消息
}
```

#### TC-RETAINED-COMP-002: [MQTT-3.3.1-6] 新订阅者立即收到
```zig
test "RETAINED - new subscriber receives immediately" {
    // 订阅后立即收到,无需等待下一次发布
}
```

---

## ✅ Will 消息测试

### 集成测试

#### TC-WILL-001: 异常断开触发 Will 消息
**优先级**: 🟡 MEDIUM

```zig
test "WILL - triggered on abnormal disconnect" {
    // 1. 客户端 A 连接 (设置 Will 消息)
    // 2. 客户端 B 订阅 Will Topic
    // 3. 客户端 A 异常断开 (关闭 TCP 连接)
    // 4. 验证客户端 B 收到 Will 消息
}
```

#### TC-WILL-002: 正常断开不触发 Will 消息
**优先级**: 🟡 MEDIUM

```zig
test "WILL - not triggered on normal disconnect" {
    // 1. 客户端 A 连接 (设置 Will 消息)
    // 2. 客户端 B 订阅 Will Topic
    // 3. 客户端 A 发送 DISCONNECT
    // 4. 验证客户端 B 不收到 Will 消息
}
```

#### TC-WILL-003: Keep Alive 超时触发 Will
**优先级**: 🟡 MEDIUM

```zig
test "WILL - triggered on keep-alive timeout" {
    // 1. 客户端 A 连接 (Keep Alive=5, Will 消息)
    // 2. 客户端 B 订阅 Will Topic
    // 3. 等待 7.5 秒 (无 PINGREQ)
    // 4. 验证客户端 B 收到 Will 消息
}
```

### 协议符合性测试

#### TC-WILL-COMP-001: [MQTT-3.1.2-8] 异常断开必须发布 Will
```zig
test "WILL - must publish on abnormal disconnect" {
    // 网络错误、超时等异常情况必须触发
}
```

#### TC-WILL-COMP-002: [MQTT-3.14.4-1] 正常断开不发布
```zig
test "WILL - must not publish on DISCONNECT" {
    // 客户端主动发送 DISCONNECT 时不触发
}
```

---

## ✅ Session 持久化测试

### 集成测试

#### TC-SESSION-001: Clean Session=0 保存会话
**优先级**: 🟡 MEDIUM

```zig
test "SESSION - persist when clean_session=0" {
    // 1. 客户端 A 连接 (Clean Session=0)
    // 2. 订阅 "test/#"
    // 3. 断开连接
    // 4. 验证会话已保存
}
```

#### TC-SESSION-002: 重连恢复订阅
**优先级**: 🟡 MEDIUM

```zig
test "SESSION - restore subscriptions on reconnect" {
    // 1. 客户端 A 连接 (Clean Session=0), 订阅 "test/#"
    // 2. 断开
    // 3. 重连 (Clean Session=0)
    // 4. 发布到 "test/msg"
    // 5. 验证客户端 A 收到消息 (订阅已恢复)
}
```

#### TC-SESSION-003: 离线消息队列
**优先级**: 🟡 MEDIUM

```zig
test "SESSION - queue messages while offline" {
    // 1. 客户端 A 连接 (Clean Session=0, QoS=1 订阅)
    // 2. 断开
    // 3. 发布 3 条 QoS 1 消息
    // 4. 重连
    // 5. 验证客户端 A 收到 3 条消息
}
```

#### TC-SESSION-004: Clean Session=1 清除会话
**优先级**: 🟡 MEDIUM

```zig
test "SESSION - clear when clean_session=1" {
    // 1. 客户端 A 连接 (Clean Session=0), 订阅
    // 2. 断开
    // 3. 重连 (Clean Session=1)
    // 4. 验证旧会话已清除
}
```

### 协议符合性测试

#### TC-SESSION-COMP-001: [MQTT-3.1.2-4] Clean Session=0 恢复会话
```zig
test "SESSION - restore session when clean_session=0" {
    // 服务器必须恢复上次会话状态
}
```

---

## ✅ Keep Alive 测试

### 集成测试

#### TC-KEEPALIVE-001: PINGREQ/PINGRESP 交互
**优先级**: 🔴 HIGH

```zig
test "KEEPALIVE - PINGREQ/PINGRESP exchange" {
    // 1. 客户端连接
    // 2. 客户端发送 PINGREQ
    // 3. 验证服务器响应 PINGRESP
}
```

#### TC-KEEPALIVE-002: 超时断开连接
**优先级**: 🔴 HIGH

```zig
test "KEEPALIVE - disconnect on timeout" {
    // 1. 客户端连接 (Keep Alive=5)
    // 2. 不发送 PINGREQ
    // 3. 等待 7.5 秒
    // 4. 验证服务器关闭连接
}
```

#### TC-KEEPALIVE-003: Keep Alive=0 不检查
**优先级**: 🟡 MEDIUM

```zig
test "KEEPALIVE - no timeout when keep_alive=0" {
    // 1. 客户端连接 (Keep Alive=0)
    // 2. 长时间不发送任何包
    // 3. 验证连接保持
}
```

### 协议符合性测试

#### TC-KEEPALIVE-COMP-001: [MQTT-3.1.2-24] 1.5 倍超时
```zig
test "KEEPALIVE - 1.5x timeout tolerance" {
    // Keep Alive=10 秒
    // 14 秒时不应断开
    // 16 秒时应断开
}
```

---

## ✅ 并发与压力测试

### 并发测试

#### TC-CONCURRENT-001: 多客户端同时连接
**优先级**: 🔴 HIGH

```zig
test "CONCURRENT - multiple clients connect simultaneously" {
    // 同时连接 100 个客户端
    // 验证全部成功
}
```

#### TC-CONCURRENT-002: 并发订阅/取消订阅
**优先级**: 🔴 HIGH

```zig
test "CONCURRENT - subscribe/unsubscribe race" {
    // 10 个线程同时操作订阅树
    // 验证数据一致性
}
```

#### TC-CONCURRENT-003: 并发发布/转发
**优先级**: 🔴 HIGH

```zig
test "CONCURRENT - publish/forward race" {
    // 多客户端同时发布到相同主题
    // 验证所有订阅者都收到消息
}
```

### 压力测试

#### TC-STRESS-001: 高频消息发布
**优先级**: 🟡 MEDIUM

```zig
test "STRESS - high frequency publishing" {
    // 1000 消息/秒 x 60 秒
    // 验证无丢失、无崩溃
}
```

#### TC-STRESS-002: 大量订阅者
**优先级**: 🟡 MEDIUM

```zig
test "STRESS - many subscribers" {
    // 1000 个客户端订阅相同主题
    // 发布 1 条消息
    // 验证 1000 个客户端都收到
}
```

#### TC-STRESS-003: 深层主题层级
**优先级**: 🟢 LOW

```zig
test "STRESS - deep topic hierarchy" {
    // 主题: "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p"
    // 订阅: "a/#"
    // 验证匹配正确
}
```

---

## ✅ 性能基准测试

### 吞吐量测试

#### TC-PERF-001: QoS 0 吞吐量
**目标**: > 10,000 msg/s

```zig
test "PERF - QoS 0 throughput" {
    // 测量每秒处理的 QoS 0 消息数
}
```

#### TC-PERF-002: QoS 1 吞吐量
**目标**: > 5,000 msg/s

```zig
test "PERF - QoS 1 throughput" {
    // 包含 PUBACK 确认
}
```

#### TC-PERF-003: QoS 2 吞吐量
**目标**: > 2,000 msg/s

```zig
test "PERF - QoS 2 throughput" {
    // 完整四步握手
}
```

### 延迟测试

#### TC-PERF-004: 端到端延迟
**目标**: < 10ms (局域网)

```zig
test "PERF - end-to-end latency" {
    // 发布时间戳 → 订阅者收到时间戳
    // 测量延迟分布 (P50, P95, P99)
}
```

### 资源使用测试

#### TC-PERF-005: 内存使用
**目标**: < 100MB (1000 客户端)

```zig
test "PERF - memory usage" {
    // 1000 个客户端连接
    // 测量内存占用
}
```

#### TC-PERF-006: CPU 使用率
**目标**: < 50% (单核, 1000 msg/s)

```zig
test "PERF - CPU utilization" {
    // 持续发布消息
    // 监控 CPU 使用率
}
```

---

## 📊 测试覆盖率目标

| 模块 | 行覆盖率 | 分支覆盖率 | 优先级 |
|------|---------|----------|--------|
| **handle_connect** | > 90% | > 85% | 🔴 HIGH |
| **handle_publish** | > 90% | > 85% | 🔴 HIGH |
| **handle_subscribe** | > 85% | > 80% | 🔴 HIGH |
| **subscription** | > 90% | > 85% | 🔴 HIGH |
| **packet** | > 85% | > 80% | 🟡 MEDIUM |
| **client** | > 80% | > 75% | 🟡 MEDIUM |
| **main** | > 70% | > 65% | 🟡 MEDIUM |

---

## 🛠️ 测试工具推荐

### 协议测试工具
- **MQTT CLI** (HiveMQ): 命令行测试
- **MQTT Explorer**: 图形化测试
- **Paho MQTT**: Python 客户端库
- **MQTT.fx**: 功能测试工具

### 性能测试工具
- **JMeter MQTT Plugin**: 负载测试
- **MQTT-Benchmark**: 专用基准测试
- **Custom Zig Benchmark**: 精确控制

### 内存/性能分析
- **Valgrind**: 内存泄漏检测
- **perf**: Linux 性能分析
- **Tracy Profiler**: 可视化性能分析

---

## ✅ 测试执行计划

### 每日执行 (CI/CD)
- 所有单元测试
- 基础集成测试
- 内存泄漏检测

### 每周执行
- 完整集成测试套件
- 协议符合性测试
- 并发测试

### 每月执行
- 压力测试
- 性能基准测试
- 长时间稳定性测试 (24小时+)

---

最后更新: 2025年10月23日
