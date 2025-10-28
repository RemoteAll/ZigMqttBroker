const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

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

    // 异步版本 (使用 iobeetle IO) - 默认主程序
    const exe_async = b.addExecutable(.{
        .name = b.fmt("mqtt-broker-async{s}", .{platform_suffix}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_async.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // 如果目标是 musl，使用静态链接
    const is_musl = if (target.query.abi) |abi|
        abi == .musl or abi == .musleabi or abi == .musleabihf
    else
        false;
    if (is_musl) {
        exe_async.linkage = .static;
    }

    // 同步版本（保留用于对比测试）
    const exe_sync = b.addExecutable(.{
        .name = b.fmt("mqtt-broker-sync{s}", .{platform_suffix}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (is_musl) {
        exe_sync.linkage = .static;
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe_async);
    b.installArtifact(exe_sync);

    // 添加交叉编译目标（针对不同平台和架构）
    const cross_targets = [_]std.Target.Query{
        // Linux ARMv7 (32位) - 适用于树莓派等设备
        // 修复：使用 baseline CPU 特性，避免 illegal instruction
        .{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .gnueabihf,
            // 不指定 cpu_model，让 Zig 自动选择兼容的基线
            // 不手动添加 CPU 特性，避免指令集不兼容
        },
        // Linux ARM64
        .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
        },
        // Linux x86_64
        .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
        },
    };

    // 为每个目标创建交叉编译步骤
    for (cross_targets) |cross_target| {
        const cross_target_resolved = b.resolveTargetQuery(cross_target);

        const cross_platform_suffix = blk: {
            const os_name = switch (cross_target.os_tag.?) {
                .linux => "linux",
                .windows => "windows",
                .macos => "macos",
                else => "unknown",
            };

            const arch_name = switch (cross_target.cpu_arch.?) {
                .x86_64 => "x86_64",
                .aarch64 => "aarch64",
                .arm => "armv7",
                else => "unknown",
            };

            break :blk b.fmt("-{s}-{s}", .{ os_name, arch_name });
        };

        // 异步版本交叉编译
        const cross_exe_async = b.addExecutable(.{
            .name = b.fmt("mqtt-broker-async{s}", .{cross_platform_suffix}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_async.zig"),
                .target = cross_target_resolved,
                .optimize = .ReleaseFast,
            }),
        });
        b.installArtifact(cross_exe_async);

        // 同步版本交叉编译
        const cross_exe_sync = b.addExecutable(.{
            .name = b.fmt("mqtt-broker-sync{s}", .{cross_platform_suffix}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = cross_target_resolved,
                .optimize = .ReleaseFast,
            }),
        });
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
    const run_step = b.step("run", "Run the app (async version by default)");
    run_step.dependOn(&run_async_cmd.step);

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
