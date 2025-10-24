#!/usr/bin/env python3
"""
MQTT内存泄漏测试工具
通过重复连接/断开操作检测MQTT broker和客户端的内存泄漏问题
"""

import time
import gc
import threading
import psutil
import os
import json
import logging
from datetime import datetime
from typing import List, Dict, Any, Tuple
from dataclasses import dataclass, asdict
import paho.mqtt.client as mqtt
from colorama import init, Fore, Style
import argparse

# 初始化colorama
init()

@dataclass
class MemorySnapshot:
    """内存快照数据"""
    timestamp: float
    iteration: int
    process_memory_mb: float
    system_memory_percent: float
    system_available_mb: float
    gc_objects: int
    active_threads: int

@dataclass
class MemoryLeakConfig:
    """内存泄漏测试配置"""
    broker_host: str = "localhost"
    broker_port: int = 1883
    iterations: int = 1000
    clients_per_iteration: int = 1
    connection_hold_time: float = 0.1  # 连接保持时间(秒)
    disconnect_wait_time: float = 0.1  # 断开后等待时间(秒)
    snapshot_interval: int = 10  # 每N次迭代记录一次内存快照
    username: str = None
    password: str = None
    use_ssl: bool = False
    client_id_prefix: str = "memory_test"
    topic_prefix: str = "test/memory"
    message_count_per_connection: int = 5  # 每次连接发送的消息数
    message_size: int = 100
    qos: int = 0

class MemoryMonitor:
    """内存监控器"""
    
    def __init__(self):
        self.process = psutil.Process(os.getpid())
        self.snapshots: List[MemorySnapshot] = []
        self.lock = threading.Lock()
    
    def take_snapshot(self, iteration: int) -> MemorySnapshot:
        """获取内存快照"""
        with self.lock:
            # 强制垃圾回收
            gc.collect()
            
            # 获取进程内存信息
            memory_info = self.process.memory_info()
            process_memory_mb = memory_info.rss / (1024 * 1024)
            
            # 获取系统内存信息
            system_memory = psutil.virtual_memory()
            system_memory_percent = system_memory.percent
            system_available_mb = system_memory.available / (1024 * 1024)
            
            # 获取垃圾回收对象数量
            gc_objects = len(gc.get_objects())
            
            # 获取活跃线程数
            active_threads = threading.active_count()
            
            snapshot = MemorySnapshot(
                timestamp=time.time(),
                iteration=iteration,
                process_memory_mb=process_memory_mb,
                system_memory_percent=system_memory_percent,
                system_available_mb=system_available_mb,
                gc_objects=gc_objects,
                active_threads=active_threads
            )
            
            self.snapshots.append(snapshot)
            return snapshot
    
    def get_memory_trend(self) -> Dict[str, Any]:
        """分析内存使用趋势"""
        if len(self.snapshots) < 2:
            return {"error": "快照数量不足"}
        
        first_snapshot = self.snapshots[0]
        last_snapshot = self.snapshots[-1]
        
        # 计算内存增长
        memory_growth_mb = last_snapshot.process_memory_mb - first_snapshot.process_memory_mb
        memory_growth_percent = (memory_growth_mb / first_snapshot.process_memory_mb) * 100
        
        # 计算对象增长
        objects_growth = last_snapshot.gc_objects - first_snapshot.gc_objects
        objects_growth_percent = (objects_growth / first_snapshot.gc_objects) * 100
        
        # 计算线程增长
        threads_growth = last_snapshot.active_threads - first_snapshot.active_threads
        
        # 计算平均内存使用
        avg_memory = sum(s.process_memory_mb for s in self.snapshots) / len(self.snapshots)
        max_memory = max(s.process_memory_mb for s in self.snapshots)
        min_memory = min(s.process_memory_mb for s in self.snapshots)
        
        # 检测内存泄漏
        leak_detected = False
        leak_severity = "无"
        
        if memory_growth_percent > 50:
            leak_detected = True
            leak_severity = "严重"
        elif memory_growth_percent > 20:
            leak_detected = True
            leak_severity = "中等"
        elif memory_growth_percent > 10:
            leak_detected = True
            leak_severity = "轻微"
        
        return {
            "initial_memory_mb": first_snapshot.process_memory_mb,
            "final_memory_mb": last_snapshot.process_memory_mb,
            "memory_growth_mb": memory_growth_mb,
            "memory_growth_percent": memory_growth_percent,
            "avg_memory_mb": avg_memory,
            "max_memory_mb": max_memory,
            "min_memory_mb": min_memory,
            "initial_objects": first_snapshot.gc_objects,
            "final_objects": last_snapshot.gc_objects,
            "objects_growth": objects_growth,
            "objects_growth_percent": objects_growth_percent,
            "initial_threads": first_snapshot.active_threads,
            "final_threads": last_snapshot.active_threads,
            "threads_growth": threads_growth,
            "leak_detected": leak_detected,
            "leak_severity": leak_severity,
            "total_snapshots": len(self.snapshots)
        }

class MemoryLeakTestClient:
    """内存泄漏测试客户端"""
    
    def __init__(self, client_id: str, config: MemoryLeakConfig):
        self.client_id = client_id
        self.config = config
        self.client = None
        self.connected = False
        self.messages_sent = 0
        self.connection_time = 0
        self.disconnect_time = 0
        self.lock = threading.Lock()
    
    def on_connect(self, client, userdata, flags, rc):
        """连接回调"""
        with self.lock:
            if rc == 0:
                self.connected = True
                self.connection_time = time.time()
            else:
                logging.error(f"客户端 {self.client_id} 连接失败: {rc}")
    
    def on_disconnect(self, client, userdata, rc):
        """断开连接回调"""
        with self.lock:
            self.connected = False
            self.disconnect_time = time.time()
    
    def on_publish(self, client, userdata, mid):
        """发布消息回调"""
        with self.lock:
            self.messages_sent += 1
    
    def connect_and_test(self) -> bool:
        """连接并执行测试"""
        try:
            # 创建新的客户端实例
            # 兼容paho-mqtt 2.0+版本
            self.client = mqtt.Client(client_id=self.client_id, callback_api_version=mqtt.CallbackAPIVersion.VERSION1)
            self.client.on_connect = self.on_connect
            self.client.on_disconnect = self.on_disconnect
            self.client.on_publish = self.on_publish
            
            # 设置认证
            if self.config.username and self.config.password:
                self.client.username_pw_set(self.config.username, self.config.password)
            
            # 设置SSL
            if self.config.use_ssl:
                self.client.tls_set()
            
            # 连接
            self.client.connect(self.config.broker_host, self.config.broker_port, 60)
            self.client.loop_start()
            
            # 等待连接成功
            wait_time = 0
            while not self.connected and wait_time < 5:
                time.sleep(0.01)
                wait_time += 0.01
            
            if not self.connected:
                return False
            
            # 发送测试消息
            topic = f"{self.config.topic_prefix}/{self.client_id}"
            for i in range(self.config.message_count_per_connection):
                message = f"Memory test message {i+1} from {self.client_id}"
                # 填充到指定大小
                if len(message) < self.config.message_size:
                    message += "x" * (self.config.message_size - len(message))
                
                self.client.publish(topic, message, self.config.qos)
            
            # 保持连接一段时间
            time.sleep(self.config.connection_hold_time)
            
            # 断开连接
            self.client.loop_stop()
            self.client.disconnect()
            
            # 等待断开完成
            time.sleep(self.config.disconnect_wait_time)
            
            # 清理客户端对象
            self.client = None
            
            return True
            
        except Exception as e:
            logging.error(f"客户端 {self.client_id} 测试异常: {e}")
            if self.client:
                try:
                    self.client.loop_stop()
                    self.client.disconnect()
                except:
                    pass
                self.client = None
            return False

class MemoryLeakTester:
    """内存泄漏测试器"""
    
    def __init__(self, config: MemoryLeakConfig):
        self.config = config
        self.monitor = MemoryMonitor()
        self.total_connections = 0
        self.successful_connections = 0
        self.failed_connections = 0
        self.start_time = 0
        self.end_time = 0
        
    def run_test(self):
        """运行内存泄漏测试"""
        print(f"{Fore.CYAN}{'='*60}")
        print("MQTT内存泄漏测试")
        print(f"{'='*60}{Style.RESET_ALL}")
        print(f"目标Broker: {self.config.broker_host}:{self.config.broker_port}")
        print(f"测试迭代: {self.config.iterations} 次")
        print(f"每次迭代客户端: {self.config.clients_per_iteration} 个")
        print(f"每连接消息数: {self.config.message_count_per_connection}")
        print(f"连接保持时间: {self.config.connection_hold_time} 秒")
        print(f"快照间隔: 每 {self.config.snapshot_interval} 次迭代")
        print("-" * 60)
        
        # 记录初始内存快照
        initial_snapshot = self.monitor.take_snapshot(0)
        print(f"{Fore.GREEN}初始内存使用: {initial_snapshot.process_memory_mb:.2f} MB{Style.RESET_ALL}")
        print(f"初始对象数量: {initial_snapshot.gc_objects:,}")
        print(f"初始线程数量: {initial_snapshot.active_threads}")
        print()
        
        self.start_time = time.time()
        
        try:
            for iteration in range(1, self.config.iterations + 1):
                # 执行连接测试
                success = self._run_iteration(iteration)
                
                if success:
                    self.successful_connections += self.config.clients_per_iteration
                else:
                    self.failed_connections += self.config.clients_per_iteration
                
                self.total_connections += self.config.clients_per_iteration
                
                # 记录内存快照
                if iteration % self.config.snapshot_interval == 0:
                    snapshot = self.monitor.take_snapshot(iteration)
                    self._print_progress(iteration, snapshot)
                
                # 强制垃圾回收
                if iteration % 50 == 0:
                    gc.collect()
            
            self.end_time = time.time()
            
            # 最终内存快照
            final_snapshot = self.monitor.take_snapshot(self.config.iterations)
            
            # 生成和显示报告
            self._generate_and_display_report(final_snapshot)
            
        except KeyboardInterrupt:
            print(f"\n{Fore.YELLOW}测试被用户中断{Style.RESET_ALL}")
            self.end_time = time.time()
            final_snapshot = self.monitor.take_snapshot(-1)
            self._generate_and_display_report(final_snapshot)
        except Exception as e:
            print(f"{Fore.RED}测试过程中发生错误: {e}{Style.RESET_ALL}")
            logging.exception("内存泄漏测试异常")
    
    def _run_iteration(self, iteration: int) -> bool:
        """执行单次迭代测试"""
        success_count = 0
        
        for i in range(self.config.clients_per_iteration):
            client_id = f"{self.config.client_id_prefix}_{iteration:04d}_{i:02d}"
            client = MemoryLeakTestClient(client_id, self.config)
            
            if client.connect_and_test():
                success_count += 1
        
        return success_count == self.config.clients_per_iteration
    
    def _print_progress(self, iteration: int, snapshot: MemorySnapshot):
        """打印测试进度"""
        progress = (iteration / self.config.iterations) * 100
        elapsed = time.time() - self.start_time
        rate = iteration / elapsed if elapsed > 0 else 0
        
        # 计算内存增长
        initial_memory = self.monitor.snapshots[0].process_memory_mb
        memory_growth = snapshot.process_memory_mb - initial_memory
        memory_growth_percent = (memory_growth / initial_memory) * 100
        
        print(f"\r{Fore.YELLOW}进度: {progress:.1f}% | "
              f"迭代: {iteration}/{self.config.iterations} | "
              f"速率: {rate:.1f} iter/s | "
              f"内存: {snapshot.process_memory_mb:.1f}MB "
              f"({memory_growth:+.1f}MB, {memory_growth_percent:+.1f}%) | "
              f"对象: {snapshot.gc_objects:,} | "
              f"线程: {snapshot.active_threads}{Style.RESET_ALL}", end="")
        
        # 每10个快照换行一次
        if len(self.monitor.snapshots) % 10 == 0:
            print()
    
    def _generate_and_display_report(self, final_snapshot: MemorySnapshot):
        """生成并显示测试报告"""
        print(f"\n\n{Fore.CYAN}{'='*60}")
        print("内存泄漏测试报告")
        print(f"{'='*60}{Style.RESET_ALL}")
        
        # 基本测试信息
        duration = self.end_time - self.start_time
        print(f"\n{Fore.YELLOW}测试摘要:{Style.RESET_ALL}")
        print(f"  测试时长: {duration:.2f} 秒")
        print(f"  总迭代数: {self.config.iterations}")
        print(f"  总连接数: {self.total_connections}")
        print(f"  成功连接: {self.successful_connections}")
        print(f"  失败连接: {self.failed_connections}")
        print(f"  连接成功率: {(self.successful_connections/self.total_connections*100):.2f}%")
        
        # 内存分析
        trend = self.monitor.get_memory_trend()
        print(f"\n{Fore.YELLOW}内存分析:{Style.RESET_ALL}")
        print(f"  初始内存: {trend['initial_memory_mb']:.2f} MB")
        print(f"  最终内存: {trend['final_memory_mb']:.2f} MB")
        print(f"  内存增长: {trend['memory_growth_mb']:+.2f} MB ({trend['memory_growth_percent']:+.2f}%)")
        print(f"  平均内存: {trend['avg_memory_mb']:.2f} MB")
        print(f"  峰值内存: {trend['max_memory_mb']:.2f} MB")
        print(f"  最低内存: {trend['min_memory_mb']:.2f} MB")
        
        # 对象分析
        print(f"\n{Fore.YELLOW}对象分析:{Style.RESET_ALL}")
        print(f"  初始对象: {trend['initial_objects']:,}")
        print(f"  最终对象: {trend['final_objects']:,}")
        print(f"  对象增长: {trend['objects_growth']:+,} ({trend['objects_growth_percent']:+.2f}%)")
        
        # 线程分析
        print(f"\n{Fore.YELLOW}线程分析:{Style.RESET_ALL}")
        print(f"  初始线程: {trend['initial_threads']}")
        print(f"  最终线程: {trend['final_threads']}")
        print(f"  线程增长: {trend['threads_growth']:+}")
        
        # 泄漏检测结果
        print(f"\n{Fore.YELLOW}泄漏检测:{Style.RESET_ALL}")
        if trend['leak_detected']:
            severity_color = Fore.RED if trend['leak_severity'] == "严重" else Fore.YELLOW
            print(f"  {severity_color}⚠ 检测到内存泄漏 - {trend['leak_severity']}级别{Style.RESET_ALL}")
            
            # 提供建议
            print(f"\n{Fore.YELLOW}优化建议:{Style.RESET_ALL}")
            if trend['memory_growth_percent'] > 50:
                print("  • 存在严重内存泄漏，建议检查连接清理逻辑")
                print("  • 检查是否正确调用disconnect()和loop_stop()")
                print("  • 验证客户端对象是否被正确释放")
            elif trend['memory_growth_percent'] > 20:
                print("  • 存在中等程度内存泄漏，建议优化资源管理")
                print("  • 检查消息缓冲区是否正确清理")
                print("  • 考虑增加垃圾回收频率")
            else:
                print("  • 存在轻微内存增长，属于正常范围")
                print("  • 可以考虑定期执行垃圾回收")
        else:
            print(f"  {Fore.GREEN}✓ 未检测到明显内存泄漏{Style.RESET_ALL}")
            print("  • 内存使用稳定，broker表现良好")
        
        # 性能评估
        print(f"\n{Fore.YELLOW}性能评估:{Style.RESET_ALL}")
        if not trend['leak_detected'] and self.successful_connections / self.total_connections > 0.95:
            print(f"  {Fore.GREEN}✓ 优秀 - 无内存泄漏，连接稳定{Style.RESET_ALL}")
        elif trend['leak_severity'] in ["轻微", "无"] and self.successful_connections / self.total_connections > 0.90:
            print(f"  {Fore.YELLOW}⚠ 良好 - 轻微内存增长，连接基本稳定{Style.RESET_ALL}")
        else:
            print(f"  {Fore.RED}✗ 需要改进 - 存在内存泄漏或连接不稳定{Style.RESET_ALL}")
        
        # 保存详细报告
        # self._save_detailed_report(trend, duration)
    
    def _save_detailed_report(self, trend: Dict[str, Any], duration: float):
        """保存详细报告到文件"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"memory_leak_test_report_{timestamp}.json"
        
        report = {
            "test_config": asdict(self.config),
            "test_summary": {
                "duration_seconds": duration,
                "total_iterations": self.config.iterations,
                "total_connections": self.total_connections,
                "successful_connections": self.successful_connections,
                "failed_connections": self.failed_connections,
                "connection_success_rate_percent": (self.successful_connections/self.total_connections*100) if self.total_connections > 0 else 0
            },
            "memory_analysis": trend,
            "memory_snapshots": [asdict(snapshot) for snapshot in self.monitor.snapshots],
            "system_info": {
                "cpu_count": psutil.cpu_count(),
                "memory_total_gb": round(psutil.virtual_memory().total / (1024**3), 2),
                "test_timestamp": datetime.now().isoformat()
            }
        }
        
        with open(filename, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        
        print(f"\n{Fore.GREEN}详细报告已保存到: {filename}{Style.RESET_ALL}")

def main():
    """主函数"""
    parser = argparse.ArgumentParser(description="MQTT内存泄漏测试工具")
    parser.add_argument("--host", default="localhost", help="MQTT broker主机地址")
    parser.add_argument("--port", type=int, default=1883, help="MQTT broker端口")
    parser.add_argument("--iterations", type=int, default=1000, help="测试迭代次数")
    parser.add_argument("--clients", type=int, default=1, help="每次迭代的客户端数量")
    parser.add_argument("--hold-time", type=float, default=0.1, help="连接保持时间(秒)")
    parser.add_argument("--wait-time", type=float, default=0.1, help="断开后等待时间(秒)")
    parser.add_argument("--snapshot-interval", type=int, default=10, help="内存快照间隔")
    parser.add_argument("--messages", type=int, default=5, help="每连接发送消息数")
    parser.add_argument("--size", type=int, default=100, help="消息大小(字节)")
    parser.add_argument("--qos", type=int, default=0, choices=[0, 1, 2], help="QoS级别")
    parser.add_argument("--username", help="MQTT用户名")
    parser.add_argument("--password", help="MQTT密码")
    parser.add_argument("--ssl", action="store_true", help="使用SSL/TLS")
    parser.add_argument("--verbose", "-v", action="store_true", help="详细输出")
    
    args = parser.parse_args()
    
    # 配置日志
    log_level = logging.INFO if args.verbose else logging.WARNING
    logging.basicConfig(
        level=log_level,
        format='%(asctime)s - %(levelname)s - %(message)s',
        datefmt='%H:%M:%S'
    )
    
    # 创建测试配置
    config = MemoryLeakConfig(
        broker_host=args.host,
        broker_port=args.port,
        iterations=args.iterations,
        clients_per_iteration=args.clients,
        connection_hold_time=args.hold_time,
        disconnect_wait_time=args.wait_time,
        snapshot_interval=args.snapshot_interval,
        message_count_per_connection=args.messages,
        message_size=args.size,
        qos=args.qos,
        username=args.username,
        password=args.password,
        use_ssl=args.ssl
    )
    
    # 创建并运行测试
    tester = MemoryLeakTester(config)
    tester.run_test()

if __name__ == "__main__":
    main()