# Linux 服务器快速部署指南

## 准备工作

本指南假设你已经编译好了 Linux x86_64 版本：

```powershell
# 在 Windows 上编译 Linux 版本
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
```

## 部署步骤

### 1. 上传二进制文件到服务器

**方法 A：使用 SCP（推荐）**

```powershell
# 在 Windows PowerShell 中执行
scp .\zig-out\bin\mqtt-broker-async-linux-x86_64 root@your-server-ip:/root/
```

**方法 B：使用 WinSCP 或 FileZilla**

通过图形界面上传 `zig-out\bin\mqtt-broker-async-linux-x86_64` 文件。

### 2. 在服务器上设置

登录服务器后执行：

```bash
# 创建目录
mkdir -p /opt/mqtt-broker/data

# 移动文件
mv /root/mqtt-broker-async-linux-x86_64 /opt/mqtt-broker/

# 添加执行权限
chmod +x /opt/mqtt-broker/mqtt-broker-async-linux-x86_64

# 测试运行
cd /opt/mqtt-broker
./mqtt-broker-async-linux-x86_64
```

如果看到类似以下输出，说明启动成功：

```
[INFO] Client pool initialized: initial_size=1024, max_size=100000
[INFO] Loaded subscriptions from 'data/subscriptions.json'
[INFO] Starting async MQTT broker on port 1883
[INFO] Entering event loop...
```

按 `Ctrl+C` 停止测试运行。

### 3. 配置 systemd 服务（生产环境）

创建服务文件：

```bash
sudo nano /etc/systemd/system/mqtt-broker.service
```

粘贴以下内容：

```ini
[Unit]
Description=MQTT Broker (Async IO)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mqtt-broker
ExecStart=/opt/mqtt-broker/mqtt-broker-async-linux-x86_64
Restart=on-failure
RestartSec=5s

# 资源限制
LimitNOFILE=100000

# 日志配置
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

启动服务：

```bash
# 重新加载 systemd 配置
sudo systemctl daemon-reload

# 启用开机自动启动
sudo systemctl enable mqtt-broker

# 启动服务
sudo systemctl start mqtt-broker

# 查看服务状态
sudo systemctl status mqtt-broker
```

### 4. 验证部署

**测试连接**：

```bash
# 安装 mosquitto 客户端工具
apt-get install mosquitto-clients  # Debian/Ubuntu
# 或
yum install mosquitto              # CentOS/RHEL

# 测试订阅
mosquitto_sub -h localhost -p 1883 -t "test/topic"

# 在另一个终端测试发布
mosquitto_pub -h localhost -p 1883 -t "test/topic" -m "Hello from MQTT!"
```

**查看日志**：

```bash
# 查看实时日志
sudo journalctl -u mqtt-broker -f

# 查看最近 100 行日志
sudo journalctl -u mqtt-broker -n 100

# 查看今天的日志
sudo journalctl -u mqtt-broker --since today
```

### 5. 防火墙配置

**开放 1883 端口**：

```bash
# UFW (Ubuntu/Debian)
sudo ufw allow 1883/tcp

# Firewalld (CentOS/RHEL)
sudo firewall-cmd --permanent --add-port=1883/tcp
sudo firewall-cmd --reload

# IPTables
sudo iptables -A INPUT -p tcp --dport 1883 -j ACCEPT
sudo service iptables save
```

### 6. 性能优化（可选）

```bash
# 增加文件描述符限制
echo "* soft nofile 100000" >> /etc/security/limits.conf
echo "* hard nofile 100000" >> /etc/security/limits.conf

# 优化内核参数
cat >> /etc/sysctl.conf <<EOF
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
EOF

# 应用配置
sysctl -p
```

## 常用命令

```bash
# 查看服务状态
sudo systemctl status mqtt-broker

# 启动服务
sudo systemctl start mqtt-broker

# 停止服务
sudo systemctl stop mqtt-broker

# 重启服务
sudo systemctl restart mqtt-broker

# 查看日志
sudo journalctl -u mqtt-broker -f

# 查看错误日志
sudo journalctl -u mqtt-broker -p err

# 检查端口监听
netstat -tlnp | grep 1883
# 或
ss -tlnp | grep 1883
```

## 更新部署

更新到新版本时：

```bash
# 1. 上传新版本到服务器
scp .\zig-out\bin\mqtt-broker-async-linux-x86_64 root@your-server-ip:/root/mqtt-broker-new

# 2. 在服务器上替换
sudo systemctl stop mqtt-broker
mv /root/mqtt-broker-new /opt/mqtt-broker/mqtt-broker-async-linux-x86_64
chmod +x /opt/mqtt-broker/mqtt-broker-async-linux-x86_64

# 3. 重新启动
sudo systemctl start mqtt-broker
sudo systemctl status mqtt-broker
```

## 故障排查

### 服务无法启动

```bash
# 查看详细错误信息
sudo journalctl -u mqtt-broker -n 50 --no-pager

# 检查文件权限
ls -la /opt/mqtt-broker/

# 手动运行测试
cd /opt/mqtt-broker
./mqtt-broker-async-linux-x86_64
```

### 端口被占用

```bash
# 查找占用 1883 端口的进程
sudo lsof -i :1883

# 或
sudo netstat -tlnp | grep 1883

# 杀死进程（如果需要）
sudo kill -9 <PID>
```

### 连接数限制

```bash
# 查看当前文件描述符限制
ulimit -n

# 查看系统最大文件描述符
cat /proc/sys/fs/file-max

# 查看当前打开的文件描述符数量
lsof | wc -l
```

## 卸载

```bash
# 停止并禁用服务
sudo systemctl stop mqtt-broker
sudo systemctl disable mqtt-broker

# 删除服务文件
sudo rm /etc/systemd/system/mqtt-broker.service

# 重新加载 systemd
sudo systemctl daemon-reload

# 删除程序文件
sudo rm -rf /opt/mqtt-broker
```

## 备份和恢复

### 备份数据

```bash
# 备份订阅数据
tar -czf mqtt-broker-backup-$(date +%Y%m%d).tar.gz /opt/mqtt-broker/data/
```

### 恢复数据

```bash
# 停止服务
sudo systemctl stop mqtt-broker

# 恢复数据
tar -xzf mqtt-broker-backup-20251027.tar.gz -C /

# 重启服务
sudo systemctl start mqtt-broker
```

---

**维护者**: PeiKeSmart Team  
**最后更新**: 2025年10月27日
