# ARMv7 部署指南

本指南用于在 ARMv7 架构设备上部署 MQTT Broker。

## 目标设备要求

根据您的设备信息：
- **CPU 架构**: ARMv7 Processor rev 1 (v7l)
- **浮点单元**: VFPv3, VFPv4
- **指令集支持**: Thumb, NEON, IDIV

编译产物已针对此架构优化，包含：
- ARMv7-A 指令集支持
- VFPv3 硬件浮点
- NEON SIMD 指令
- 硬浮点 ABI (gnueabihf)

## 编译命令

在 **Windows (PowerShell)** 环境下编译：

```powershell
# 进入项目目录
cd f:\Project\ZigMqttBroker\mqtt-broker1

# 编译所有交叉平台目标（包括 ARMv7）
zig build -Doptimize=ReleaseFast

# 查看编译产物
Get-ChildItem zig-out\bin\*armv7*
```

编译完成后会生成：
- `zig-out/bin/mqtt-broker-async-linux-armv7` - 异步 IO 版本（推荐）
- `zig-out/bin/mqtt-broker-sync-linux-armv7` - 同步版本

## 部署步骤

### 1. 复制文件到目标设备

使用 SCP、FTP 或其他方式将文件传输到 ARMv7 设备：

```bash
# 使用 SCP (在本地 Windows 或 Linux 机器上执行)
scp zig-out/bin/mqtt-broker-async-linux-armv7 user@192.168.x.x:/opt/mqtt-broker/

# 或使用 SFTP
sftp user@192.168.x.x
put zig-out/bin/mqtt-broker-async-linux-armv7 /opt/mqtt-broker/
```

### 2. 在设备上配置

```bash
# SSH 登录到 ARMv7 设备
ssh user@192.168.x.x

# 创建工作目录
mkdir -p /opt/mqtt-broker
cd /opt/mqtt-broker

# 赋予执行权限
chmod +x mqtt-broker-async-linux-armv7

# 验证文件架构（确认是 ARM 32位）
file mqtt-broker-async-linux-armv7
# 输出应包含: "ELF 32-bit LSB executable, ARM, EABI5 version 1"

# 检查依赖库（通常无外部依赖）
ldd mqtt-broker-async-linux-armv7
```

### 3. 运行 MQTT Broker

```bash
# 直接运行（前台）
./mqtt-broker-async-linux-armv7

# 后台运行
nohup ./mqtt-broker-async-linux-armv7 > mqtt-broker.log 2>&1 &

# 查看进程
ps aux | grep mqtt-broker
```

### 4. 配置开机自启（可选）

#### 使用 systemd

创建 systemd 服务文件 `/etc/systemd/system/mqtt-broker.service`:

```ini
[Unit]
Description=MQTT Broker (Zig Implementation)
After=network.target

[Service]
Type=simple
User=mqtt
Group=mqtt
WorkingDirectory=/opt/mqtt-broker
ExecStart=/opt/mqtt-broker/mqtt-broker-async-linux-armv7
Restart=on-failure
RestartSec=5s

# 资源限制
LimitNOFILE=65536
LimitNPROC=4096

# 安全加固
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

启用并启动服务：

```bash
# 创建专用用户（可选）
sudo useradd -r -s /bin/false mqtt

# 更改文件所有者
sudo chown mqtt:mqtt /opt/mqtt-broker/mqtt-broker-async-linux-armv7

# 重载 systemd 配置
sudo systemctl daemon-reload

# 启动服务
sudo systemctl start mqtt-broker

# 查看状态
sudo systemctl status mqtt-broker

# 设置开机自启
sudo systemctl enable mqtt-broker
```

#### 使用 init.d（旧系统）

创建脚本 `/etc/init.d/mqtt-broker`:

```bash
#!/bin/sh
### BEGIN INIT INFO
# Provides:          mqtt-broker
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: MQTT Broker
### END INIT INFO

DAEMON=/opt/mqtt-broker/mqtt-broker-async-linux-armv7
PIDFILE=/var/run/mqtt-broker.pid
USER=mqtt

case "$1" in
  start)
    echo "Starting MQTT Broker..."
    start-stop-daemon --start --pidfile $PIDFILE --make-pidfile \
      --background --chuid $USER --exec $DAEMON
    ;;
  stop)
    echo "Stopping MQTT Broker..."
    start-stop-daemon --stop --pidfile $PIDFILE
    ;;
  restart)
    $0 stop
    $0 start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac

exit 0
```

配置权限并启用：

```bash
sudo chmod +x /etc/init.d/mqtt-broker
sudo update-rc.d mqtt-broker defaults
sudo /etc/init.d/mqtt-broker start
```

## 故障排查

### "Illegal instruction" 错误

如果出现此错误，说明编译时使用的指令集不兼容。检查：

```bash
# 查看 CPU 特性
cat /proc/cpuinfo | grep Features

# 查看可执行文件要求
readelf -A mqtt-broker-async-linux-armv7
```

**解决方案**：修改 `build.zig` 中的 CPU 特性配置，移除不支持的特性（如 NEON）：

```zig
.cpu_features_add = std.Target.arm.featureSet(&.{
    .v7a,
    .vfp3,
    // .neon,  // 如果设备不支持则注释
}),
```

### 端口被占用

```bash
# 检查 1883 端口是否被占用
netstat -lntp | grep 1883

# 或使用
ss -lntp | grep 1883

# 杀死占用进程
sudo kill <PID>
```

### 性能问题

```bash
# 查看系统资源
top
htop

# 查看进程详情
ps aux | grep mqtt-broker

# 查看网络连接
netstat -an | grep 1883
```

### 日志调试

```bash
# 查看实时日志
tail -f mqtt-broker.log

# 查看 systemd 日志
sudo journalctl -u mqtt-broker -f

# 启用详细日志（修改源码后重新编译）
```

## 性能优化建议

### 1. 系统参数调优

编辑 `/etc/sysctl.conf`:

```bash
# 增加文件描述符限制
fs.file-max = 100000

# TCP 优化
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_fin_timeout = 30

# 应用配置
sudo sysctl -p
```

### 2. ulimit 配置

编辑 `/etc/security/limits.conf`:

```
*  soft  nofile  65536
*  hard  nofile  65536
mqtt  soft  nofile  65536
mqtt  hard  nofile  65536
```

### 3. CPU 亲和性（多核设备）

```bash
# 绑定到特定 CPU 核心
taskset -c 0,1 ./mqtt-broker-async-linux-armv7
```

## 测试验证

### 1. 本地测试

```bash
# 使用 mosquitto 客户端测试
mosquitto_pub -h localhost -t test/topic -m "Hello MQTT"
mosquitto_sub -h localhost -t test/topic

# 使用 MQTT.fx 等图形工具连接
# 地址: 设备IP
# 端口: 1883
```

### 2. 性能测试

```bash
# 使用 mqtt-benchmark（需要另外安装）
mqtt-benchmark --broker tcp://localhost:1883 \
  --count 1000 --size 100 --clients 10 --qos 0

# 查看指标
curl http://localhost:8080/metrics  # 如果启用了 HTTP 监控
```

## 常见架构对比

| 架构 | 文件名后缀 | 位数 | ABI | 适用设备示例 |
|------|-----------|------|-----|------------|
| **ARMv7** | armv7 | 32位 | gnueabihf | 树莓派 2/3 (32位系统), BeagleBone |
| ARMv8/AArch64 | aarch64 | 64位 | gnu | 树莓派 3/4 (64位系统), Jetson Nano |
| x86_64 | x86_64 | 64位 | gnu | 普通 PC, 服务器 |

## 更新说明

### 架构适配变更

本次更新针对 ARMv7 架构进行了以下优化：

1. **原子操作适配**: 将 64位原子类型降级为 32位，避免 ARMv7 不支持 64位原子操作的问题
2. **类型转换修复**: 修复 `usize` 在 32位架构下的类型转换问题
3. **编译配置优化**: 添加 ARMv7 特定的 CPU 特性和浮点 ABI 配置

### 性能说明

- 32位计数器在高负载场景下可能溢出（约 43亿次），适合中小规模部署
- 如需更大容量，建议升级到 64位 ARM 架构 (AArch64)

## 联系与支持

如有问题，请检查：
1. 设备 CPU 架构是否匹配 (ARMv7)
2. 系统是否为 Linux (内核 3.10+)
3. 是否有足够的内存和文件描述符限制

---

**编译时间**: 2025-10-27  
**目标架构**: arm-linux-gnueabihf (ARMv7 + VFPv3 + NEON)  
**优化级别**: ReleaseFast
