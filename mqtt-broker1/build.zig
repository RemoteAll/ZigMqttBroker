const std = @import("std");

/// 平台配置结构
const PlatformConfig = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    strip: bool,
    use_sync: bool, // 是否强制使用同步版本
};

/// 检测平台类型并返回优化配置
fn detectPlatformConfig(target_query: std.Target.Query, optimize: std.builtin.OptimizeMode) PlatformConfig {
    const cpu_arch = target_query.cpu_arch orelse @import("builtin").cpu.arch;

    // 检测是否是嵌入式 ARM 设备（使用 musl）
    const is_embedded_arm = blk: {
        if (cpu_arch != .arm) break :blk false;

        // musl libc + ARM 32位 → 嵌入式设备（如 OpenWrt）
        if (target_query.abi) |abi| {
            if (abi == .musleabi or abi == .musleabihf) {
                break :blk true;
            }
        }
        break :blk false;
    };

    // 检测是否是高性能服务器平台
    const is_high_perf = blk: {
        if (is_embedded_arm) break :blk false;

        // x86_64 或 aarch64 → 高性能服务器
        if (cpu_arch == .x86_64 or cpu_arch == .aarch64) {
            break :blk true;
        }
        break :blk false;
    };

    // 根据平台返回优化配置
    if (is_embedded_arm) {
        return PlatformConfig{
            .name = "embedded_arm",
            .optimize = .ReleaseSafe, // 嵌入式：安全和体积优先
            .linkage = .static, // 静态链接提高兼容性
            .strip = true, // 减小二进制体积
            .use_sync = true, // 强制使用同步版本（io_uring 不可用）
        };
    } else if (is_high_perf) {
        return PlatformConfig{
            .name = "high_perf",
            .optimize = switch (optimize) {
                .Debug => .Debug,
                else => .ReleaseFast, // 高性能：速度第一
            },
            .linkage = .dynamic, // 动态链接使用系统优化库
            .strip = false, // 保留符号便于性能分析
            .use_sync = false, // 优先使用异步版本
        };
    } else {
        return PlatformConfig{
            .name = "generic",
            .optimize = optimize,
            .linkage = .dynamic,
            .strip = false,
            .use_sync = true, // 其他平台：兼容性优先，使用同步版本
        };
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========== 平台检测与配置 ==========
    const platform_config = detectPlatformConfig(target.query, optimize);

    // 输出平台信息（编译时）
    const platform_info = b.fmt(
        \\
        \\===== Build Configuration =====
        \\Platform: {s}
        \\Optimize: {s}
        \\Linkage: {s}
        \\Preferred: {s} version
        \\================================
        \\
    , .{
        platform_config.name,
        @tagName(platform_config.optimize),
        @tagName(platform_config.linkage),
        if (platform_config.use_sync) "sync" else "async",
    });
    _ = platform_info; // 暂时不输出，避免干扰构建日志

    // 根据目标平台生成带平台标识的文件名
    const target_query = target.query;
    const platform_suffix = blk: {
        const os_tag = target_query.os_tag orelse @import("builtin").os.tag;
        const cpu_arch = target_query.cpu_arch orelse @import("builtin").cpu.arch;

        const os_name = switch (os_tag) {
            .windows => "windows",
            .linux => "linux",
            .macos => "macos",
            else => @tagName(os_tag),
        };

        const arch_name = switch (cpu_arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "arm",
            else => @tagName(cpu_arch),
        };

        break :blk b.fmt("-{s}-{s}", .{ os_name, arch_name });
    };

    // 异步版本 (使用 iobeetle IO) - 高性能平台默认
    const exe_async = b.addExecutable(.{
        .name = b.fmt("mqtt-broker-async{s}", .{platform_suffix}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_async.zig"),
            .target = target,
            .optimize = platform_config.optimize,
        }),
    });

    // 应用平台特定配置
    exe_async.linkage = platform_config.linkage;
    exe_async.root_module.strip = platform_config.strip;

    // 同步版本（兼容性优先，支持所有平台）
    const exe_sync = b.addExecutable(.{
        .name = b.fmt("mqtt-broker-sync{s}", .{platform_suffix}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = platform_config.optimize,
        }),
    });

    // 应用平台特定配置
    exe_sync.linkage = platform_config.linkage;
    exe_sync.root_module.strip = platform_config.strip;

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).

    // 根据平台配置决定安装哪个版本
    if (!platform_config.use_sync) {
        // 高性能平台：优先安装异步版本
        b.installArtifact(exe_async);
        b.installArtifact(exe_sync); // 也安装同步版本作为备选
    } else {
        // 嵌入式/兼容性平台：优先安装同步版本
        b.installArtifact(exe_sync);
        // 仍然尝试构建异步版本（可能在运行时失败）
        b.installArtifact(exe_async);
    }

    // 添加交叉编译目标（针对不同平台和架构）
    const cross_targets = [_]struct {
        query: std.Target.Query,
        name: []const u8,
    }{
        // 嵌入式 ARM (OpenWrt) - ARMv6 软浮点 + musl + 静态链接
        .{
            .query = .{
                .cpu_arch = .arm,
                .os_tag = .linux,
                .abi = .musleabi, // 软浮点，最大兼容性
                // 使用 baseline CPU，不指定特定型号
            },
            .name = "linux-arm-embedded",
        },
        // Linux ARM64 服务器
        .{
            .query = .{
                .cpu_arch = .aarch64,
                .os_tag = .linux,
                .abi = .gnu, // glibc，高性能
            },
            .name = "linux-aarch64",
        },
        // Linux x86_64 服务器
        .{
            .query = .{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .gnu, // glibc，高性能
            },
            .name = "linux-x86_64",
        },
        // Windows x86_64
        .{
            .query = .{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            },
            .name = "windows-x86_64",
        },
    };

    // 为每个目标创建交叉编译步骤
    for (cross_targets) |cross_target| {
        const cross_target_resolved = b.resolveTargetQuery(cross_target.query);
        const cross_platform_config = detectPlatformConfig(cross_target.query, .ReleaseFast);

        // 异步版本交叉编译
        const cross_exe_async = b.addExecutable(.{
            .name = b.fmt("mqtt-broker-async-{s}", .{cross_target.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_async.zig"),
                .target = cross_target_resolved,
                .optimize = cross_platform_config.optimize,
            }),
        });
        cross_exe_async.linkage = cross_platform_config.linkage;
        cross_exe_async.root_module.strip = cross_platform_config.strip;
        b.installArtifact(cross_exe_async);

        // 同步版本交叉编译
        const cross_exe_sync = b.addExecutable(.{
            .name = b.fmt("mqtt-broker-sync-{s}", .{cross_target.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = cross_target_resolved,
                .optimize = cross_platform_config.optimize,
            }),
        });
        cross_exe_sync.linkage = cross_platform_config.linkage;
        cross_exe_sync.root_module.strip = cross_platform_config.strip;
        b.installArtifact(cross_exe_sync);
    }

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_async_cmd = b.addRunArtifact(exe_async);
    const run_sync_cmd = b.addRunArtifact(exe_sync);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_async_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_async_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".

    // 默认 run 根据平台配置自动选择版本
    const run_step = b.step("run", "Run the MQTT broker (auto-select version based on platform)");
    if (platform_config.use_sync) {
        run_step.dependOn(&run_sync_cmd.step);
    } else {
        run_step.dependOn(&run_async_cmd.step);
    }

    // 异步版本运行步骤（保留向后兼容）
    const run_async_step = b.step("run-async", "Run the async IO version");
    run_async_step.dependOn(b.getInstallStep());
    run_async_step.dependOn(&run_async_cmd.step);

    // 同步版本运行步骤
    const run_sync_step = b.step("run-sync", "Run the sync version");
    run_sync_step.dependOn(b.getInstallStep());
    run_sync_step.dependOn(&run_sync_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
