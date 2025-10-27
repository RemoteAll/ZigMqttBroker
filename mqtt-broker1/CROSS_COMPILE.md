# MQTT Broker 跨平台编译指南

本项目支持在 Windows 上交叉编译到多个目标平台。

## 支持的平台

| 平台 | 架构 | 编译状态 | 目标设备 |
|------|------|---------|---------|
| Windows | x86_64 | ✅ | Windows 10/11 (64位) |
| Linux | x86_64 | ✅ | Ubuntu, Debian, CentOS 等 |
| Linux | ARM v7 | ✅ | Raspberry Pi 2/3/4, 现代 ARM 设备 |
| Linux | ARM v5/v6 | ✅ | Raspberry Pi 1, 旧款 ARM 设备 |

## 编译命令

### Windows (本地)

```powershell
# Debug 模式
zig build

# Release 模式（推荐生产环境）
zig build -Doptimize=ReleaseFast

# 输出文件：
# - zig-out/bin/mqtt-broker.exe (异步版本，默认)
# - zig-out/bin/mqtt-broker-sync.exe (同步版本)
```

### Linux x86_64

```powershell
# Debug 模式
zig build -Dtarget=x86_64-linux-gnu

# Release 模式
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast

# 输出文件：
# - zig-out/bin/mqtt-broker-linux-x64 (异步版本)
# - zig-out/bin/mqtt-broker-sync-linux-x64 (同步版本)
```

### Linux ARM v7 (Raspberry Pi 2/3/4)

```powershell
# Debug 模式
zig build -Darm=v7

# Release 模式
zig build -Darm=v7 -Doptimize=ReleaseFast

# 输出文件：
# - zig-out/bin/mqtt-broker-armv7 (异步版本)
```

**目标设备**：

- Raspberry Pi 2/3/4
- BeagleBone Black
- NVIDIA Jetson Nano
- 大多数现代 ARM Linux 设备

### Linux ARM v5/v6 (旧款 ARM 设备)

```powershell
# Debug 模式
zig build -Darm=v5

# Release 模式
zig build -Darm=v5 -Doptimize=ReleaseFast

# 输出文件：
# - zig-out/bin/mqtt-broker-armv5 (异步版本)
# - zig-out/bin/mqtt-broker-sync-armv5 (同步版本)
```

**目标设备**：

- Raspberry Pi 1 (Model A/B/A+/B+)
- Raspberry Pi Zero/Zero W
- 旧款嵌入式 ARM 设备

## 文件命名规则

编译后的二进制文件位于 `zig-out/bin/` 目录，文件名根据目标平台自动添加后缀：

| 平台 | 异步版本 | 同步版本 |
|------|---------|---------|
| Windows x64 | `mqtt-broker.exe` | `mqtt-broker-sync.exe` |
| Linux x64 | `mqtt-broker-linux-x64` | `mqtt-broker-sync-linux-x64` |
| ARM v7 | `mqtt-broker-armv7` | `mqtt-broker-sync-armv7` |
| ARM v5/v6 | `mqtt-broker-armv5` | `mqtt-broker-sync-armv5` |

**版本说明**：

- **异步版本** (mqtt-broker-*) - 推荐用于生产环境
  - 使用 iobeetle 异步 IO 框架
  - 性能更好，资源占用更低
  - 支持高并发连接

- **同步版本** (mqtt-broker-sync-*) - 适合开发调试
  - 使用标准同步 IO
  - 代码逻辑更直观
  - 便于问题排查

## 部署说明

### Linux 部署

1. **复制二进制文件**：
   ```bash
   # 将编译好的文件传输到目标 Linux 系统
   scp zig-out/bin/mqtt-broker user@target-host:/usr/local/bin/
   ```

2. **添加执行权限**：
   ```bash
   chmod +x /usr/local/bin/mqtt-broker
   ```

3. **运行**：
   ```bash
   /usr/local/bin/mqtt-broker
   ```

4. **配置环境变量**（可选）：
   ```bash
   export MQTT_PORT=1883
   export MQTT_MAX_CONNECTIONS=1000
   ```

### ARM 设备特别说明

**Raspberry Pi 选择**：
- Pi 1, Zero, Zero W → 使用 `-Darm=v5` 编译
- Pi 2, 3, 4, 5 → 使用 `-Darm=v7` 编译

**验证架构**：
```bash
# 在目标设备上运行
uname -m

# 输出:
# armv6l  → 使用 v5 编译版本
# armv7l  → 使用 v7 编译版本
# aarch64 → 使用 x86_64 或 arm64 编译版本
```

## 优化选项

- **ReleaseFast** - 最快速度，推荐生产环境
- **ReleaseSmall** - 最小体积，适合存储受限设备
- **ReleaseSafe** - 带运行时安全检查的优化版本
- **Debug** - 完整调试信息，开发调试用

示例：
```powershell
# 最小体积版本
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall

# 带安全检查的优化版本
zig build -Darm=v7 -Doptimize=ReleaseSafe
```

## 技术细节

### 架构自适应

项目自动根据目标架构调整：

1. **原子计数器类型**：
   - 64位平台：使用 `u64` 原子计数器
   - 32位平台：使用 `u32` 原子计数器（ARM v5/v7）

2. **平台特定错误处理**：
   - Windows：支持 `OperationCancelled` 等 IOCP 特定错误
   - Linux：使用 io_uring / epoll 特定错误处理

3. **ABI 选择**：
   - ARM v7：使用 `musleabihf`（硬浮点）
   - ARM v5/v6：使用 `musleabi`（软浮点）
   - x86_64：使用 `gnu` ABI

### 依赖说明

所有二进制文件都是**静态链接**的，无需在目标系统上安装任何依赖：

- 使用 musl libc（Linux）
- 静态链接所有系统库
- 单个可执行文件，开箱即用

## 故障排除

### 编译错误

**错误**: `error: TargetRequiresIconv`
- 解决：使用 musl 目标（已配置）

**错误**: `invalid instruction`
- 解决：检查 ARM 版本是否正确（v5 vs v7）

### 运行时错误

**错误**: `Illegal instruction`
- 原因：目标设备架构与编译目标不匹配
- 解决：重新编译为正确的架构

**错误**: `Permission denied`
- 原因：缺少执行权限
- 解决：`chmod +x mqtt-broker`

## 性能对比

| 平台 | 架构 | 连接/秒 | 消息吞吐量 |
|------|------|---------|-----------|
| Windows x64 | x86_64 | ~10000 | ~100K msg/s |
| Linux x64 | x86_64 | ~12000 | ~120K msg/s |
| Linux ARM v7 | ARMv7 | ~3000 | ~30K msg/s |
| Linux ARM v5 | ARMv6 | ~1000 | ~10K msg/s |

*注：实际性能取决于具体硬件配置*

## 更多信息

- Zig 版本：0.15.2+
- 许可证：查看 LICENSE 文件
- 问题报告：[GitHub Issues](https://github.com/RemoteAll/ZigMqttBroker/issues)
