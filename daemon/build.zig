const std = @import("std");

const version_number = "0.1.0";

const GitInfo = struct {
    commit: []const u8 = "unknown",
    dirty: bool = false,
};

fn gitOutput(b: *std.Build, argv: []const []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = argv,
        .max_output_bytes = 64 * 1024,
    }) catch return null;
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            b.allocator.free(result.stdout);
            return null;
        },
        else => {
            b.allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        b.allocator.free(result.stdout);
        return null;
    }
    const copy = b.allocator.dupe(u8, trimmed) catch {
        b.allocator.free(result.stdout);
        return null;
    };
    b.allocator.free(result.stdout);
    return copy;
}

fn detectGit(b: *std.Build) GitInfo {
    var info = GitInfo{};
    if (gitOutput(b, &.{ "git", "rev-parse", "--short", "HEAD" })) |commit| {
        info.commit = commit;
        if (gitOutput(b, &.{ "git", "status", "--porcelain", "--untracked-files=no" })) |status| {
            info.dirty = status.len > 0;
        }
    }
    return info;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const git = detectGit(b);
    const commit_override = b.option([]const u8, "commit", "Override git commit hash");
    const commit = commit_override orelse git.commit;
    const dirty = git.dirty and commit_override == null;
    const full_version = if (std.mem.eql(u8, commit, "unknown"))
        version_number
    else
        b.fmt("{s}+{s}{s}", .{ version_number, commit, if (dirty) ".dirty" else "" });

    const openssl_include = b.option([]const u8, "openssl-include", "Extra OpenSSL include directory");
    const openssl_lib_dir = b.option([]const u8, "openssl-lib-dir", "Extra OpenSSL library directory");

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", full_version);
    build_info.addOption([]const u8, "commit", commit);
    build_info.addOption(bool, "dirty", dirty);

    const shared = b.createModule(.{
        .root_source_file = b.path("src/shared.zig"),
    });

    const backend = b.createModule(.{
        .root_source_file = b.path(if (target.result.os.tag == .windows)
            "src/platform/windows/backend.zig"
        else
            "src/platform/linux/backend.zig"),
    });
    backend.addImport("shared", shared);

    const service_module = b.createModule(.{
        .root_source_file = b.path(if (target.result.os.tag == .windows)
            "src/platform/windows/service.zig"
        else
            "src/service_stub.zig"),
    });
    service_module.addImport("platform_backend", backend);
    service_module.addImport("shared", shared);

    const exe = b.addExecutable(.{
        .name = "hampaneld",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("platform_backend", backend);
    exe.root_module.addImport("shared", shared);
    exe.root_module.addImport("windows_service", service_module);
    exe.root_module.addOptions("build_info", build_info);
    if (openssl_include) |dir| exe.addIncludePath(.{ .cwd_relative = dir });
    if (openssl_lib_dir) |dir| exe.addLibraryPath(.{ .cwd_relative = dir });
    exe.linkLibC();

    const openssl_dir = b.option([]const u8, "openssl-dir", "OpenSSL installation prefix (Windows)");
    if (target.result.os.tag == .windows) {
        if (openssl_dir) |dir| {
            exe.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dir, "include" }) });
            exe.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ dir, "lib" }) });
            exe.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "lib", "libssl.lib" }) });
            exe.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "lib", "libcrypto.lib" }) });
        } else {
            exe.linkSystemLibrary("ssl");
            exe.linkSystemLibrary("crypto");
        }
        exe.linkSystemLibrary("advapi32");
        exe.linkSystemLibrary("iphlpapi");
        exe.linkSystemLibrary("psapi");
        exe.linkSystemLibrary("ws2_32");
    } else {
        exe.linkSystemLibrary("ssl");
        exe.linkSystemLibrary("crypto");
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run hampaneld");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("platform_backend", backend);
    tests.root_module.addImport("shared", shared);
    tests.root_module.addImport("windows_service", service_module);
    tests.root_module.addOptions("build_info", build_info);
    if (openssl_include) |dir| tests.addIncludePath(.{ .cwd_relative = dir });
    if (openssl_lib_dir) |dir| tests.addLibraryPath(.{ .cwd_relative = dir });
    tests.linkLibC();
    tests.linkSystemLibrary("ssl");
    tests.linkSystemLibrary("crypto");
    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_check = b.addObject(.{
        .name = "hampanel-windows-check",
        .root_source_file = b.path("src/platform/windows/check.zig"),
        .target = windows_target,
        .optimize = .Debug,
    });
    windows_check.linkLibC();
    windows_check.root_module.addImport("shared", shared);
    const check_step = b.step("check-windows", "Type-check the Windows backend");
    check_step.dependOn(&windows_check.step);
}
