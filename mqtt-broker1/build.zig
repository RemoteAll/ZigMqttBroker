const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // 获取 ARM 版本参数 (v5 或 v7)，默认使用标准 target
    const arm_version = b.option([]const u8, "arm", "ARM version (v5 or v7) for cross-compilation") orelse "";

    // 根据 ARM 版本构建 target
    var target: std.Build.ResolvedTarget = undefined;
    if (std.mem.eql(u8, arm_version, "v5")) {
        // ARMv5TE: 支持 Thumb 指令集，兼容性更好
        // 适用于较老的 ARM 设备，如 ARMv5TE 架构的嵌入式系统
        target = b.resolveTargetQuery(.{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .musleabi,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
        });
    } else if (std.mem.eql(u8, arm_version, "v7")) {
        // 针对不支持 NEON 的 ARMv7 设备（如 Cortex-A9）
        // 使用软浮点 ABI 和通用 ARMv7 特性集
        target = b.resolveTargetQuery(.{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .musleabi, // 改用软浮点 ABI，兼容性更好
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.generic },
            .cpu_features_add = std.Target.arm.featureSet(&.{
                .v7a, // ARMv7-A 基础架构
            }),
        });
    } else {
        // 默认：标准 target 选项
        target = b.standardTargetOptions(.{});
    }

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // 根据目标平台生成文件名后缀
    const target_suffix = blk: {
        if (std.mem.eql(u8, arm_version, "v5")) {
            break :blk "-armv5";
        } else if (std.mem.eql(u8, arm_version, "v7")) {
            break :blk "-armv7";
        } else if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux) {
            break :blk "-linux-x64";
        } else {
            break :blk "";
        }
    };

    // 异步版本 (使用 iobeetle IO) - 作为默认编译目标
    const async_name = b.fmt("mqtt-broker{s}", .{target_suffix});
    const exe_async = b.addExecutable(.{
        .name = async_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_async.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const sync_name = b.fmt("mqtt-broker-sync{s}", .{sync_name_suffix: {
        break :sync_name_suffix target_suffix;
    }});
    const exe = b.addExecutable(.{
        .name = sync_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe_async);
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_async_cmd = b.addRunArtifact(exe_async);
    const run_cmd = b.addRunArtifact(exe);

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
    const run_step = b.step("run", "Run the async app");
    run_step.dependOn(&run_async_cmd.step);

    // 同步版本运行步骤
    const run_sync_step = b.step("run-sync", "Run the sync IO version");
    run_sync_step.dependOn(b.getInstallStep());
    run_sync_step.dependOn(&run_cmd.step);

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
