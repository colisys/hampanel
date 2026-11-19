const std = @import("std");

const version_number = "0.1.0";

const GitInfo = struct {
    commit: []const u8 = "unknown",
    dirty: bool = false,
};

fn gitOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.graph.arena, b.graph.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    if (!result.term.success()) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return b.dupe(trimmed);
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

fn addOpensslIncludePaths(
    translate: *std.Build.Step.TranslateC,
    openssl_include: ?[]const u8,
) void {
    if (openssl_include) |dir| translate.addIncludePath(.{ .cwd_relative = dir });
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
    const openssl_dir = b.option([]const u8, "openssl-dir", "OpenSSL installation prefix (Windows)");
    const openssl_static = b.option(bool, "openssl-static", "Link OpenSSL statically") orelse false;

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", full_version);
    build_info.addOption([]const u8, "commit", commit);
    build_info.addOption(bool, "dirty", dirty);

    // C imports are translated by dedicated build steps in Zig 0.17.
    const openssl_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/openssl_headers.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addOpensslIncludePaths(openssl_headers, openssl_include);
    if (openssl_dir) |dir| openssl_headers.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dir, "include" }) });
    const openssl_c = openssl_headers.createModule();

    const libc_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/libc_headers.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const libc_c = libc_headers.createModule();

    const sqlite_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/sqlite_headers.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_headers.addIncludePath(b.path("vendor/sqlite"));
    const sqlite_c = sqlite_headers.createModule();

    const sqlite_flags = &.{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_DQS=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
    };
    const sqlite_source = b.path("vendor/sqlite/sqlite3.c");
    const sqlite_include = b.path("vendor/sqlite");

    const compat = b.createModule(.{
        .root_source_file = b.path("src/compat.zig"),
    });

    const shared = b.createModule(.{
        .root_source_file = b.path("src/shared.zig"),
    });
    shared.addImport("libc_c", libc_c);
    shared.addImport("compat", compat);

    const backend = b.createModule(.{
        .root_source_file = b.path(if (target.result.os.tag == .windows)
            "src/platform/windows/backend.zig"
        else
            "src/platform/linux/backend.zig"),
    });
    backend.addImport("shared", shared);
    backend.addImport("compat", compat);

    var windows_c: ?*std.Build.Module = null;
    if (target.result.os.tag == .linux) {
        const terminal_headers = b.addTranslateC(.{
            .root_source_file = b.path("src/terminal_headers.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        backend.addImport("terminal_c", terminal_headers.createModule());
    } else if (target.result.os.tag == .windows) {
        const windows_headers = b.addTranslateC(.{
            .root_source_file = b.path("src/windows_headers.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        windows_c = windows_headers.createModule();
        backend.addImport("windows_c", windows_c.?);
    }

    const service_module = b.createModule(.{
        .root_source_file = b.path(if (target.result.os.tag == .windows)
            "src/platform/windows/service.zig"
        else
            "src/service_stub.zig"),
    });
    service_module.addImport("platform_backend", backend);
    service_module.addImport("shared", shared);
    if (windows_c) |module| service_module.addImport("windows_c", module);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("platform_backend", backend);
    exe_module.addImport("shared", shared);
    exe_module.addImport("windows_service", service_module);
    exe_module.addImport("openssl_c", openssl_c);
    exe_module.addImport("compat", compat);
    exe_module.addImport("sqlite_c", sqlite_c);
    exe_module.addIncludePath(sqlite_include);
    exe_module.addCSourceFile(.{ .file = sqlite_source, .flags = sqlite_flags });
    exe_module.addOptions("build_info", build_info);
    if (openssl_include) |dir| exe_module.addIncludePath(.{ .cwd_relative = dir });
    if (openssl_lib_dir) |dir| exe_module.addLibraryPath(.{ .cwd_relative = dir });

    if (target.result.os.tag == .windows) {
        if (openssl_dir) |dir| {
            exe_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dir, "include" }) });
            exe_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ dir, "lib" }) });
            exe_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "lib", "libssl.lib" }) });
            exe_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "lib", "libcrypto.lib" }) });
        } else {
            exe_module.linkSystemLibrary("ssl", .{});
            exe_module.linkSystemLibrary("crypto", .{});
        }
        exe_module.linkSystemLibrary("advapi32", .{});
        exe_module.linkSystemLibrary("iphlpapi", .{});
        exe_module.linkSystemLibrary("psapi", .{});
        exe_module.linkSystemLibrary("ws2_32", .{});
    } else {
        const link_mode: std.builtin.LinkMode = if (openssl_static) .static else .dynamic;
        exe_module.linkSystemLibrary("ssl", .{ .preferred_link_mode = link_mode });
        exe_module.linkSystemLibrary("crypto", .{ .preferred_link_mode = link_mode });
    }

    const exe = b.addExecutable(.{
        .name = "hampaneld",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run hampaneld");
    run_step.dependOn(&run_cmd.step);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_module.addImport("platform_backend", backend);
    tests_module.addImport("shared", shared);
    tests_module.addImport("windows_service", service_module);
    tests_module.addImport("openssl_c", openssl_c);
    tests_module.addImport("compat", compat);
    tests_module.addImport("sqlite_c", sqlite_c);
    tests_module.addIncludePath(sqlite_include);
    tests_module.addCSourceFile(.{ .file = sqlite_source, .flags = sqlite_flags });
    tests_module.addOptions("build_info", build_info);
    if (openssl_include) |dir| tests_module.addIncludePath(.{ .cwd_relative = dir });
    if (openssl_lib_dir) |dir| tests_module.addLibraryPath(.{ .cwd_relative = dir });
    const test_link_mode: std.builtin.LinkMode = if (openssl_static) .static else .dynamic;
    tests_module.linkSystemLibrary("ssl", .{ .preferred_link_mode = test_link_mode });
    tests_module.linkSystemLibrary("crypto", .{ .preferred_link_mode = test_link_mode });

    const tests = b.addTest(.{
        .root_module = tests_module,
    });
    const test_cmd = b.addRunArtifact(tests);
    // `zig build test` only analyses functions the tests actually reach, so an
    // unreferenced handler body can fail to compile. The check step builds the
    // real executable, which forces every registered handler to be analysed.
    const local_check_step = b.step("check", "Type-check the daemon through the real executable");
    local_check_step.dependOn(&exe.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_check_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/windows_headers.h"),
        .target = windows_target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const windows_check_module = b.createModule(.{
        .root_source_file = b.path("src/platform/windows/check.zig"),
        .target = windows_target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const windows_check_c = windows_check_headers.createModule();
    const windows_check_service = b.createModule(.{
        .root_source_file = b.path("src/platform/windows/service.zig"),
        .target = windows_target,
        .optimize = .Debug,
        .link_libc = true,
    });
    windows_check_service.addImport("windows_c", windows_check_c);
    windows_check_module.addImport("shared", shared);
    windows_check_module.addImport("compat", compat);
    windows_check_module.addImport("windows_c", windows_check_c);
    windows_check_module.addImport("windows_service", windows_check_service);
    const windows_check = b.addObject(.{
        .name = "hampanel-windows-check",
        .root_module = windows_check_module,
    });
    const windows_shared_module = b.createModule(.{
        .root_source_file = b.path("src/windows_shared_check.zig"),
        .target = windows_target,
        .optimize = .Debug,
        .link_libc = true,
    });
    windows_shared_module.addImport("shared", shared);
    windows_shared_module.addImport("compat", compat);
    const windows_shared = b.addObject(.{
        .name = "hampanel-windows-shared-check",
        .root_module = windows_shared_module,
    });

    const check_step = b.step("check-windows", "Type-check the Windows backend");
    check_step.dependOn(&windows_check.step);
    check_step.dependOn(&windows_shared.step);
}
