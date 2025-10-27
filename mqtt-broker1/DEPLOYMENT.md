# MQTT Broker 跨平台部署指南

## 快速开始

本项目默认使用 **`src/main_async.zig`** 作为入口点,支持 Windows、Linux 和 macOS 平台。

## 构建命令

### Windows 本地构建

```powershell
# 默认构建（Debug 模式）
zig build

# 生产环境构建（推荐）
zig build -Doptimize=ReleaseFast

# 安全优化构建（包含运行时检查）
zig build -Doptimize=ReleaseSafe
```

### Linux 本地构建

```bash
# 默认构建（Debug 模式）
zig build

# 生产环境构建（推荐）
zig build -Doptimize=ReleaseFast

# 安全优化构建（包含运行时检查）
zig build -Doptimize=ReleaseSafe
```

### 交叉编译

在任意平台上为其他平台构建:

```bash
# 为 Linux x86_64 构建
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# 为 Windows x86_64 构建
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

# 为 macOS x86_64 (Intel) 构建
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast

# 为 macOS ARM64 (Apple Silicon) 构建
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast

# 为 Linux ARM64 构建
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast
```

## 构建输出

所有可执行文件位于 `zig-out/bin/` 目录:

- **`mqtt-broker`** - 默认异步版本 (推荐使用)
- **`mqtt-broker-async`** - 异步版本别名
- **`mqtt-broker-sync`** - 同步版本 (用于对比测试)

### 平台特定文件名

- Windows: `mqtt-broker.exe`, `mqtt-broker-async.exe`, `mqtt-broker-sync.exe`
- Linux/macOS: `mqtt-broker`, `mqtt-broker-async`, `mqtt-broker-sync`

## 运行服务

### Windows

```powershell
.\zig-out\bin\mqtt-broker.exe
```

### Linux/macOS

```bash
chmod +x zig-out/bin/mqtt-broker
./zig-out/bin/mqtt-broker
```

默认监听端口: **1883** (MQTT 标准端口)

## 优化模式说明

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| `Debug` | 无优化 + 调试符号 | 本地开发调试 |
| `ReleaseSafe` | 优化 + 运行时安全检查 | **生产环境推荐** |
| `ReleaseFast` | 最大性能优化 | 性能关键场景 |
| `ReleaseSmall` | 最小二进制大小 | 受限环境 |

## 部署步骤

### 1. 为目标平台构建

```bash
# 示例: 为 Linux 服务器构建生产版本
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe
```

### 2. 传输到服务器

```bash
# 使用 scp
scp zig-out/bin/mqtt-broker user@server:/opt/mqtt-broker/

# 使用 rsync
rsync -avz zig-out/bin/mqtt-broker user@server:/opt/mqtt-broker/
```

### 3. 在服务器上运行

```bash
# 添加执行权限
chmod +x /opt/mqtt-broker/mqtt-broker

# 创建数据目录
mkdir -p /opt/mqtt-broker/data

# 运行服务
cd /opt/mqtt-broker
./mqtt-broker
```

## 使用 systemd 管理服务 (Linux)

创建服务文件 `/etc/systemd/system/mqtt-broker.service`:

```ini
[Unit]
Description=MQTT Broker (Async IO)
After=network.target

[Service]
Type=simple
User=mqtt
Group=mqtt
WorkingDirectory=/opt/mqtt-broker
ExecStart=/opt/mqtt-broker/mqtt-broker
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

## 性能调优

### Linux

```bash
# 增加文件描述符限制
ulimit -n 100000

# 调整内核参数（需要 root 权限）
sysctl -w net.core.somaxconn=4096
sysctl -w net.ipv4.tcp_max_syn_backlog=4096
```

### Windows

Windows 会根据 CPU 核心数自动调整 IOCP 线程池,通常无需手动配置。

## 测试连接

使用 mosquitto 客户端工具:

```bash
# 订阅测试
mosquitto_sub -h localhost -p 1883 -t "test/topic"

# 发布测试
mosquitto_pub -h localhost -p 1883 -t "test/topic" -m "Hello MQTT"
```

## 平台特性

- **Windows**: 使用 IOCP (I/O Completion Ports)
- **Linux**: 使用 io_uring (需要内核 5.1+)
- **macOS**: 使用 kqueue

## 配置说明

当前配置位于 `src/config.zig`,关键配置项:

- `MAX_CONNECTIONS`: 10000 (最大并发连接数)
- `READ_BUFFER_SIZE`: 8192 (读缓冲区大小)
- `INITIAL_POOL_SIZE`: 1000 (连接池初始大小)
- `DEFAULT_SESSION_EXPIRY_SEC`: 3600 (会话过期时间)

## 故障排查

### 端口被占用

```bash
# Linux
sudo lsof -i :1883

# Windows
netstat -ano | findstr :1883
```

### 文件描述符不足 (Linux)

```bash
# 临时增加
ulimit -n 100000

# 永久修改 /etc/security/limits.conf
* soft nofile 100000
* hard nofile 100000
```

### 权限不足 (Linux)

```bash
# 使用非特权端口 (>1024) 或以 root 运行
# 或者使用 setcap 授权
sudo setcap 'cap_net_bind_service=+ep' /opt/mqtt-broker/mqtt-broker
```

## 许可证

本项目采用 [LICENSE](LICENSE) 文件中指定的许可证。

---

**维护者**: PeiKeSmart Team  
**最后更新**: 2025年10月27日
