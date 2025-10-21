const std = @import("std");
const builtin = @import("builtin");
const net = std.net;

/// 批量写入助手 - 减少系统调用次数
pub const BatchWriter = struct {
    /// 批量写入到多个 socket
    pub fn writeToMultiple(streams: []const net.Stream, data: []const u8) !usize {
        var success_count: usize = 0;

        for (streams) |stream| {
            stream.writeAll(data) catch {
                continue;
            };
            success_count += 1;
        }

        return success_count;
    }

    /// Windows 平台使用 WSASend 批量发送
    pub fn writeAllWindows(stream: net.Stream, data: []const u8) !void {
        if (builtin.os.tag != .windows) {
            @compileError("writeAllWindows only works on Windows");
        }

        const windows = std.os.windows;
        var wsabuf = windows.ws2_32.WSABUF{
            .len = @intCast(data.len),
            .buf = @constCast(data.ptr),
        };

        var bytes_sent: u32 = undefined;
        const result = windows.ws2_32.WSASend(@ptrCast(stream.handle), @ptrCast(&wsabuf), 1, &bytes_sent, 0, null, null);

        if (result == windows.ws2_32.SOCKET_ERROR) {
            _ = windows.ws2_32.WSAGetLastError();
            return error.SendFailed;
        }
    }

    /// Unix 平台使用 writev 批量发送多个缓冲区
    pub fn writevUnix(stream: net.Stream, buffers: []const []const u8) !void {
        if (builtin.os.tag == .windows) {
            @compileError("writevUnix only works on Unix-like systems");
        }

        // 转换为 iovec 结构
        var iovecs = try std.heap.page_allocator.alloc(std.posix.iovec_const, buffers.len);
        defer std.heap.page_allocator.free(iovecs);

        for (buffers, 0..) |buf, i| {
            iovecs[i] = .{
                .base = buf.ptr,
                .len = buf.len,
            };
        }

        const total = try std.posix.writev(stream.handle, iovecs);
        _ = total;
    }
};
