const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const net = std.net;
const Allocator = std.mem.Allocator;
const Client = @import("client.zig").Client;

// 确保只在 Windows 平台编译
comptime {
    if (builtin.os.tag != .windows) {
        @compileError("IOCP is only supported on Windows");
    }
}

/// IO 操作类型
pub const IoType = enum(u32) {
    Accept,
    Receive,
    Send,
    Disconnect,
};

/// IO 重叠结构 - 必须是对齐的
pub const IoContext = struct {
    overlapped: windows.OVERLAPPED align(8),
    io_type: IoType,
    client: ?*Client,
    buffer: []u8,
    bytes_transferred: u32,

    pub fn init(allocator: Allocator, io_type: IoType, buffer_size: usize) !*IoContext {
        const ctx = try allocator.create(IoContext);
        ctx.* = .{
            .overlapped = std.mem.zeroes(windows.OVERLAPPED),
            .io_type = io_type,
            .client = null,
            .buffer = try allocator.alloc(u8, buffer_size),
            .bytes_transferred = 0,
        };
        return ctx;
    }

    pub fn deinit(self: *IoContext, allocator: Allocator) void {
        allocator.free(self.buffer);
        allocator.destroy(self);
    }

    pub fn reset(self: *IoContext) void {
        self.overlapped = std.mem.zeroes(windows.OVERLAPPED);
        self.bytes_transferred = 0;
    }
};

/// IOCP 管理器
pub const IocpManager = struct {
    allocator: Allocator,
    completion_port: windows.HANDLE,
    worker_threads: []std.Thread,
    is_running: bool,

    pub fn init(allocator: Allocator, thread_count: u32) !IocpManager {
        // 创建 IOCP
        const port = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, thread_count);

        const threads = try allocator.alloc(std.Thread, thread_count);

        return IocpManager{
            .allocator = allocator,
            .completion_port = port,
            .worker_threads = threads,
            .is_running = false,
        };
    }

    pub fn deinit(self: *IocpManager) void {
        self.is_running = false;

        // 通知所有工作线程退出
        for (self.worker_threads) |_| {
            _ = windows.kernel32.PostQueuedCompletionStatus(self.completion_port, 0, 0, null);
        }

        // 等待所有线程结束
        for (self.worker_threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.worker_threads);
        windows.CloseHandle(self.completion_port);
    }

    /// 将 socket 关联到 IOCP
    pub fn associateSocket(self: *IocpManager, socket: windows.SOCKET, client: *Client) !void {
        const handle = @as(windows.HANDLE, @ptrCast(socket));
        _ = try windows.CreateIoCompletionPort(handle, self.completion_port, @intFromPtr(client), 0);
    }

    /// 启动工作线程
    pub fn start(self: *IocpManager, handler: *const fn (*Client, []u8) anyerror!void) !void {
        self.is_running = true;

        for (self.worker_threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ self, handler });
        }
    }

    /// 投递接收操作
    pub fn postReceive(self: *IocpManager, client: *Client, ctx: *IoContext) !void {
        _ = self;

        var flags: u32 = 0;
        var wsabuf = windows.ws2_32.WSABUF{
            .len = @intCast(ctx.buffer.len),
            .buf = ctx.buffer.ptr,
        };

        const result = windows.ws2_32.WSARecv(@ptrCast(client.stream.handle), @ptrCast(&wsabuf), 1, null, &flags, @ptrCast(&ctx.overlapped), null);

        if (result == windows.ws2_32.SOCKET_ERROR) {
            const err = windows.ws2_32.WSAGetLastError();
            if (err != .WSA_IO_PENDING) {
                return error.IocpPostReceiveFailed;
            }
        }
    }

    /// 投递发送操作
    pub fn postSend(self: *IocpManager, client: *Client, data: []const u8, ctx: *IoContext) !void {
        _ = self;

        @memcpy(ctx.buffer[0..data.len], data);

        var wsabuf = windows.ws2_32.WSABUF{
            .len = @intCast(data.len),
            .buf = ctx.buffer.ptr,
        };

        const result = windows.ws2_32.WSASend(@ptrCast(client.stream.handle), @ptrCast(&wsabuf), 1, null, 0, @ptrCast(&ctx.overlapped), null);

        if (result == windows.ws2_32.SOCKET_ERROR) {
            const err = windows.ws2_32.WSAGetLastError();
            if (err != .WSA_IO_PENDING) {
                return error.IocpPostSendFailed;
            }
        }
    }

    /// 工作线程函数
    fn workerThread(self: *IocpManager, handler: *const fn (*Client, []u8) anyerror!void) void {
        while (self.is_running) {
            var bytes_transferred: u32 = undefined;
            var completion_key: usize = undefined;
            var overlapped: ?*windows.OVERLAPPED = undefined;

            const ok = windows.kernel32.GetQueuedCompletionStatus(self.completion_port, &bytes_transferred, &completion_key, &overlapped, windows.INFINITE) != 0;

            // 退出信号
            if (completion_key == 0) {
                break;
            }

            if (!ok or overlapped == null) {
                continue;
            }

            // 从 OVERLAPPED 获取 IoContext
            const overlapped_ptr = overlapped.?;
            const ctx_offset = @offsetOf(IoContext, "overlapped");
            const ctx_addr = @intFromPtr(overlapped_ptr) - ctx_offset;
            const ctx: *IoContext = @ptrFromInt(ctx_addr);

            const client = @as(*Client, @ptrFromInt(completion_key));

            ctx.bytes_transferred = bytes_transferred;

            switch (ctx.io_type) {
                .Receive => {
                    if (bytes_transferred == 0) {
                        // 客户端断开连接
                        std.log.info("Client {} disconnected", .{client.id});
                        client.is_connected = false;
                        continue;
                    }

                    // 处理接收到的数据
                    const data = ctx.buffer[0..bytes_transferred];
                    handler(client, data) catch |err| {
                        std.log.err("Error handling client data: {any}", .{err});
                    };

                    // 重置上下文并继续投递接收操作
                    ctx.reset();
                    self.postReceive(client, ctx) catch |err| {
                        std.log.err("Error posting receive: {any}", .{err});
                    };
                },
                .Send => {
                    // 发送完成,可以释放或重用上下文
                },
                .Disconnect => {
                    client.is_connected = false;
                },
                else => {},
            }
        }
    }
};
