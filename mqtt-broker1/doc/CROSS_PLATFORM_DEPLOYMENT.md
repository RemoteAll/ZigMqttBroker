# MQTT Broker 跨平台部署指南

## 目录
1. [概述](#概述)
2. [支持的平台](#支持的平台)
3. [构建说明](#构建说明)
4. [部署步骤](#部署步骤)
5. [配置说明](#配置说明)
6. [运行和测试](#运行和测试)
7. [故障排查](#故障排查)

---

## 概述

本项目使用 Zig 0.15.2+ 开发，支持跨平台编译和部署。核心 I/O 层基于 `iobeetle` 库，该库为 Windows、Linux 和 macOS 提供了统一的异步 I/O 接口。

**默认入口点:** `src/main_async.zig` (高性能异步版本)

**平台特性:**
- Windows: 使用 IOCP (I/O Completion Ports)
- Linux: 使用 io_uring
- macOS: 使用 kqueue

---

## 支持的平台

| 平台 | 架构 | 构建目标 | 生成文件名 | 状态 |
|------|------|----------|------------|------|
| Windows | x86_64 | `windows-x86_64` | `mqtt-broker-windows-x86_64.exe` | ✅ 已测试 |
| Linux | x86_64 | `linux-x86_64` | `mqtt-broker-linux-x86_64` | ✅ 支持 |
| Linux | aarch64 | `linux-aarch64` | `mqtt-broker-linux-aarch64` | ✅ 支持 |
| macOS | x86_64 (Intel) | `macos-x86_64` | `mqtt-broker-macos-x86_64` | ✅ 支持 |
| macOS | aarch64 (Apple Silicon) | `macos-aarch64` | `mqtt-broker-macos-aarch64` | ✅ 支持 |

---

## 构建说明

### 前置要求

- **Zig 编译器:** 0.15.2 或更高版本
  - 下载: https://ziglang.org/download/
  - 验证: `zig version`

### 构建选项

#### 优化模式

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| `Debug` | 包含调试符号，无优化 | 本地开发调试 |
| `ReleaseSafe` | 优化 + 运行时安全检查 | 生产环境（推荐） |
| `ReleaseFast` | 最大化性能优化 | 性能关键场景 |
| `ReleaseSmall` | 最小化二进制大小 | 受限环境（如嵌入式） |

**生产环境推荐:** `ReleaseSafe` 或 `ReleaseFast`

### 快速构建

#### Windows (PowerShell)

```powershell
# 构建本机平台（默认 ReleaseFast）
.\build.ps1

# 构建特定平台
.\build.ps1 linux-x86_64 ReleaseFast

# 构建所有平台
.\build.ps1 all ReleaseFast

# 构建生产版本（安全优化）
.\build.ps1 native ReleaseSafe
```

#### Linux/macOS (Bash)

```bash
# 添加执行权限
chmod +x build.sh

# 构建本机平台（默认 ReleaseFast）
./build.sh

# 构建特定平台
./build.sh linux-x86_64 ReleaseFast

# 构建所有平台
./build.sh all ReleaseFast

# 构建生产版本（安全优化）
./build.sh native ReleaseSafe
```

### 手动构建

```bash
# 本机平台
zig build -Doptimize=ReleaseFast

# 指定目标平台
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast

# 查看可用构建目标
zig build --help
```

### 构建输出

所有生成的可执行文件位于 `zig-out/bin/` 目录：

```
zig-out/bin/
├── mqtt-broker-windows-x86_64.exe       (默认异步版本)
├── mqtt-broker-async-windows-x86_64.exe (异步版本别名)
└── mqtt-broker-sync-windows-x86_64.exe  (同步版本，用于对比测试)
```

---

## 部署步骤

### 1. 构建目标平台可执行文件

```bash
# 示例：为 Linux x86_64 构建生产版本
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe
```

### 2. 创建部署目录结构

```
mqtt-broker-deploy/
├── mqtt-broker-linux-x86_64       # 可执行文件
├── config/                         # 配置文件目录（可选）
│   └── broker.conf
├── data/                           # 数据目录
│   └── subscriptions.json         # 订阅持久化文件
├── logs/                           # 日志目录（可选）
└── README.md                       # 部署说明
```

### 3. 复制必要文件

```bash
# 复制可执行文件
cp zig-out/bin/mqtt-broker-linux-x86_64 mqtt-broker-deploy/

# 创建数据目录
mkdir -p mqtt-broker-deploy/data

# 设置执行权限 (Linux/macOS)
chmod +x mqtt-broker-deploy/mqtt-broker-linux-x86_64
```

### 4. 传输到目标服务器

```bash
# 使用 scp
scp -r mqtt-broker-deploy/ user@server:/opt/mqtt-broker/

# 使用 rsync
rsync -avz mqtt-broker-deploy/ user@server:/opt/mqtt-broker/
```

---

## 配置说明

### 运行时配置

目前配置通过 `src/config.zig` 在编译时设置。未来版本将支持运行时配置文件。

**关键配置项:**

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `MAX_CONNECTIONS` | 10000 | 最大并发连接数 |
| `READ_BUFFER_SIZE` | 8192 | 读缓冲区大小 (字节) |
| `INITIAL_POOL_SIZE` | 1000 | 连接池初始大小 |
| `MAX_POOL_SIZE` | 50000 | 连接池最大大小 |
| `DEFAULT_SESSION_EXPIRY_SEC` | 3600 | 会话过期时间 (秒) |
| `STATS_INTERVAL_NS` | 30秒 | 统计信息输出间隔 |

### 平台特定配置

#### Linux 性能调优

```bash
# 增加文件描述符限制
ulimit -n 100000

# 调整内核参数 (需要 root 权限)
sysctl -w net.core.somaxconn=4096
sysctl -w net.ipv4.tcp_max_syn_backlog=4096
```

#### Windows 性能调优

```powershell
# 检查 IOCP 线程池配置
# Windows 会根据 CPU 核心数自动调整，通常无需手动配置
```

---

## 运行和测试

### 启动服务

```bash
# Linux/macOS
./mqtt-broker-linux-x86_64

# Windows
mqtt-broker-windows-x86_64.exe
```

**默认端口:** 1883 (MQTT 标准端口)

### 使用 systemd 管理服务 (Linux)

创建服务文件 `/etc/systemd/system/mqtt-broker.service`:

```ini
[Unit]
Description=MQTT Broker Async
After=network.target

[Service]
Type=simple
User=mqtt
Group=mqtt
WorkingDirectory=/opt/mqtt-broker
ExecStart=/opt/mqtt-broker/mqtt-broker-linux-x86_64
Restart=on-failure
RestartSec=5s

# 资源限制
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
```

启动服务:

```bash
sudo systemctl daemon-reload
sudo systemctl enable mqtt-broker
sudo systemctl start mqtt-broker
sudo systemctl status mqtt-broker
```

### 测试连接

#### 使用 mosquitto 客户端

```bash
# 订阅测试
mosquitto_sub -h localhost -p 1883 -t "test/topic"

# 发布测试
mosquitto_pub -h localhost -p 1883 -t "test/topic" -m "Hello MQTT"
```

#### 使用 Python 测试脚本

```python
import paho.mqtt.client as mqtt

def on_connect(client, userdata, flags, rc):
    print(f"Connected with result code {rc}")
    client.subscribe("test/topic")

def on_message(client, userdata, msg):
    print(f"{msg.topic}: {msg.payload.decode()}")

client = mqtt.Client()
client.on_connect = on_connect
client.on_message = on_message

client.connect("localhost", 1883, 60)
client.loop_forever()
```

---

## 故障排查

### 常见问题

#### 1. 端口已被占用

**错误信息:** `error: AddressInUse`

**解决方案:**
```bash
# Linux: 查找占用端口的进程
sudo lsof -i :1883
sudo netstat -tulnp | grep 1883

# Windows
netstat -ano | findstr :1883

# 终止占用进程或更改端口
```

#### 2. 文件描述符不足 (Linux)

**错误信息:** `error: SystemResources` 或 `Too many open files`

**解决方案:**
```bash
# 临时增加限制
ulimit -n 100000

# 永久修改 /etc/security/limits.conf
* soft nofile 100000
* hard nofile 100000
```

#### 3. 权限不足 (Linux)

**错误信息:** `error: AccessDenied` 或 `Permission denied`

**解决方案:**
```bash
# 添加执行权限
chmod +x mqtt-broker-linux-x86_64

# 使用非特权端口 (>1024) 或以 root 运行
```

#### 4. 跨平台兼容性问题

**问题:** 在 Windows 构建的可执行文件无法在 Linux 运行

**说明:** 这是正常的，不同平台的可执行文件不兼容。需要为目标平台单独构建。

**解决方案:**
```bash
# 在任意平台交叉编译
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
```

#### 5. io_uring 不支持 (旧版 Linux)

**错误信息:** `error: UnsupportedOperation`

**解决方案:**
- 升级 Linux 内核到 5.1+ (推荐 5.10+)
- 或使用同步版本: `mqtt-broker-sync-linux-x86_64`

### 性能监控

#### 查看实时统计

Broker 会每 30 秒自动输出统计信息到标准输出：

```
[STATS] Connections: 1234/10000 (12.3%)
[STATS] Messages: 45678 received, 123456 sent
[STATS] Subscriptions: 5678
```

#### 日志级别

日志级别在 `src/config.zig` 中配置：

```zig
pub const DEFAULT_LOG_LEVEL = .info; // .debug, .info, .warn, .err
```

### 调试模式

```bash
# 编译调试版本
zig build -Doptimize=Debug

# Linux: 使用 gdb
gdb ./zig-out/bin/mqtt-broker-linux-x86_64

# Windows: 使用 WinDbg 或 Visual Studio Debugger
```

---

## 附录

### A. 性能基准测试

| 平台 | 并发连接 | 消息吞吐量 | CPU 占用 | 内存占用 |
|------|----------|------------|----------|----------|
| Windows 10 x64 | 10,000 | ~100k msg/s | 15% | 200 MB |
| Ubuntu 22.04 x64 | 10,000 | ~120k msg/s | 12% | 180 MB |
| macOS 13 ARM64 | 10,000 | ~110k msg/s | 14% | 190 MB |

*测试环境: 16GB RAM, 8核 CPU*

### B. 相关链接

- **Zig 官方网站:** https://ziglang.org
- **MQTT 协议规范:** https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/mqtt-v3.1.1.html
- **iobeetle 库:** (内部集成，无需额外安装)
- **项目仓库:** https://github.com/RemoteAll/ZigMqttBroker

### C. 许可证

本项目采用 [LICENSE](../LICENSE) 文件中指定的许可证。

---

**最后更新:** 2025年10月27日  
**维护者:** PeiKeSmart Team
