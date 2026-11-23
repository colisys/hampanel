const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// Immutable-attribute protection for critical paths.
///
/// `chattr +i` is the enforcement: files and directories carrying it cannot be
/// modified, renamed or deleted even by root until the attribute is cleared.
/// The panel keeps a manifest so it can report what it protected and restore
/// protection after maintenance.
pub const Entry = struct {
    path: []const u8,
    /// Raw `lsattr` flags, e.g. "----i---------e------".
    attributes: []const u8,
    immutable: bool,
    /// Whether the path still exists.
    present: bool,
};

pub const Status = struct {
    available: bool,
    /// chattr/lsattr resolved from PATH.
    tooling: bool,
    entries: []const Entry,
    ebpf_detection: bool,
    ebpf_reason: []const u8,
    message: []const u8 = "",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const manifest_name = "tamper-manifest.txt";

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    const tooling = exec.commandExists(allocator, "chattr") and exec.commandExists(allocator, "lsattr");
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);

    const raw = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch "";
    defer if (raw.len > 0) allocator.free(raw);

    var entries = std.array_list.Managed(Entry).init(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \r\t");
        if (path.len == 0) continue;
        try entries.append(.{
            .path = try allocator.dupe(u8, path),
            .attributes = try readAttributes(allocator, path),
            .immutable = false,
            .present = exists(path),
        });
        const last = &entries.items[entries.items.len - 1];
        last.immutable = std.mem.indexOfScalar(u8, last.attributes, 'i') != null;
    }

    // The caller owns and frees `entries`, so return a slice whose allocation is
    // exactly as long as its length. Handing back `entries.items` while the list
    // still holds its capacity makes `free(entries)` an invalid free, which the
    // CI test runner (root, so `chattr` succeeds) aborts on.
    const owned = try entries.toOwnedSlice();
    const probe_error: ?anyerror = blk: {
        _ = sampleWrites(allocator, 0, 0, 1) catch |err| break :blk err;
        break :blk null;
    };
    return .{
        .ebpf_detection = probe_error == null,
        .ebpf_reason = if (probe_error) |err| @errorName(err) else "",
        .available = tooling and owned.len > 0,
        .tooling = tooling,
        .entries = owned,
        .message = if (!tooling)
            "缺少 chattr/lsattr，无法进行不可变保护"
        else if (owned.len == 0)
            "尚未保护任何路径"
        else
            "",
    };
}

pub fn protect(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !Outcome {
    if (!exec.commandExists(allocator, "chattr")) return error.ChattrUnavailable;
    // A directory needs -R: attaching +i to the directory alone still allows
    // creating and rewriting entries inside it, and only the recursive form
    // stops new files from appearing under a protected path.
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("chattr");
    if (try isDirectory(allocator, path)) try argv.append("-R");
    try argv.append("+i");
    try argv.append(path);

    const result = exec.run(allocator, argv.items, 256 * 1024) catch
        return error.ChattrUnavailable;
    // `textOf` borrows from the buffers, so the failure output is copied before
    // they are released.
    if (!result.ok()) {
        const output = try allocator.dupe(u8, textOf(result));
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return .{ .ok = false, .output = output };
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    // A zero exit status is not proof: busybox `chattr` prints "getting flags:
    // Not a tty" and still exits 0 when the filesystem does not support the
    // immutable attribute (overlayfs in a container, tmpfs, ...). Read the flag
    // back so a protection that did not take effect is reported as a failure
    // instead of silently claiming the path is immutable.
    const verification = try readAttributes(allocator, path);
    defer allocator.free(verification);
    if (std.mem.indexOfScalar(u8, verification, 'i') == null) {
        return .{
            .ok = false,
            .output = try std.fmt.allocPrint(
                allocator,
                "文件系统不支持不可变属性（lsattr: {s}）",
                .{if (verification.len == 0) "无输出" else verification},
            ),
        };
    }

    // Persist only after the attribute was actually applied.
    try appendManifest(allocator, data_dir, path);
    return .{ .ok = true, .output = "" };
}

pub fn unprotect(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !Outcome {
    if (!exec.commandExists(allocator, "chattr")) return error.ChattrUnavailable;
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("chattr");
    if (try isDirectory(allocator, path)) try argv.append("-R");
    try argv.append("-i");
    try argv.append(path);

    const result = exec.run(allocator, argv.items, 256 * 1024) catch
        return error.ChattrUnavailable;
    if (!result.ok()) {
        const output = try allocator.dupe(u8, textOf(result));
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return .{ .ok = false, .output = output };
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    try removeFromManifest(allocator, data_dir, path);
    return .{ .ok = true, .output = "" };
}

/// Re-applies every manifest entry after a reboot: +i survives on most
/// filesystems, but a mount, image rebuild or fsck can drop it, and silent loss
/// of protection is exactly what this feature exists to prevent.
pub fn restoreAll(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);
    const raw = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch return 0;
    defer allocator.free(raw);

    var restored: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \r\t");
        if (path.len == 0 or !exists(path)) continue;
        const attributes = readAttributes(allocator, path) catch "";
        defer allocator.free(attributes);
        if (std.mem.indexOfScalar(u8, attributes, 'i') != null) continue;
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("chattr");
        if (try isDirectory(allocator, path)) try argv.append("-R");
        try argv.append("+i");
        try argv.append(path);
        const result = exec.run(allocator, argv.items, 256 * 1024) catch continue;
        const ok = result.ok();
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (ok) restored += 1;
    }
    return restored;
}

fn isDirectory(allocator: std.mem.Allocator, path: []const u8) !bool {
    _ = allocator;
    var dir = std.Io.Dir.openDirAbsolute(compat.io(), path, .{ .iterate = false }) catch return false;
    dir.close(compat.io());
    return true;
}

fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn manifestPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    const root = try compat.path.join(allocator, &.{ data_dir, "security" });
    defer allocator.free(root);
    return compat.path.join(allocator, &.{ root, manifest_name });
}

fn readAttributes(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!exec.commandExists(allocator, "lsattr")) return try allocator.dupe(u8, "");
    const result = exec.run(allocator, &.{ "lsattr", "-d", path }, 64 * 1024) catch
        return try allocator.dupe(u8, "");
    // Copy the first field before the buffers are released: `first` borrows
    // from `result.stdout`.
    const owned = blk: {
        if (!result.ok()) break :blk try allocator.dupe(u8, "");
        var tokens = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
        const first = tokens.next() orelse break :blk try allocator.dupe(u8, "");
        break :blk try allocator.dupe(u8, first);
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return owned;
}

fn appendManifest(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !void {
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);
    if (compat.path.dirname(manifest)) |dir| compat.cwd().makePath(dir) catch {};

    const existing = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch "";
    defer if (existing.len > 0) allocator.free(existing);
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), path)) return;
    }

    const updated = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ existing, path });
    defer allocator.free(updated);
    var file = try compat.createFileAbsolute(manifest, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(updated);
    // Read back immediately below (restoreAll runs at startup), so make the
    // bytes durable here rather than relying on close.
    try file.sync();
}

fn removeFromManifest(allocator: std.mem.Allocator, data_dir: []const u8, path: []const u8) !void {
    const manifest = try manifestPath(allocator, data_dir);
    defer allocator.free(manifest);
    const existing = compat.cwd().readFileAlloc(allocator, manifest, 1024 * 1024) catch return;
    defer allocator.free(existing);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, path)) continue;
        try out.writer.print("{s}\n", .{text});
    }
    var file = try compat.createFileAbsolute(manifest, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(out.written());
}

/// A bounded observation of the inode selected at the start, not a policy
/// attached to a pathname. Never persist this result in the immutable manifest.
pub fn detectWrites(a: std.mem.Allocator, path: []const u8) !u64 {
    const linux = std.os.linux;
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const z = try compat.dupeZ(a, path);
    defer a.free(z);
    // O_PATH does not open devices or block on FIFOs. Holding the descriptor
    // also prevents inode reuse if the file is unlinked during observation.
    const opened = linux.openat(linux.AT.FDCWD, z.ptr, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    switch (linux.errno(opened)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.StatFailed,
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &st)) != .SUCCESS) return error.StatFailed;
    // STATX_TYPE (bit 0) and STATX_INO (bit 8) must both be present.
    if (@as(u32, @bitCast(st.mask)) & 0x101 != 0x101) return error.StatFailed;
    if (st.mode & 0o170000 != 0o100000) return error.RegularFileRequired;
    // Kernel dev_t uses MINORBITS=20 (not the userspace st_dev encoding).
    const device = (@as(u64, st.dev_major) << 20) | st.dev_minor;
    return sampleWrites(a, device, st.ino, 5);
}

var sampling = std.atomic.Value(bool).init(false);

fn sampleWrites(a: std.mem.Allocator, device: u64, inode: u64, seconds: u8) !u64 {
    if (sampling.swap(true, .acq_rel)) return error.ProbeBusy;
    defer sampling.store(false, .release);
    if (!exec.commandExists(a, "bpftrace")) return error.BpftraceMissing;
    if (!exec.commandExists(a, "timeout")) return error.TimeoutToolMissing;
    const program = try std.fmt.allocPrint(a,
        \\BEGIN {{ @writes = sum(0); }}
        \\kprobe:vfs_write /((struct file *)arg0)->f_inode->i_sb->s_dev == {d} && ((struct file *)arg0)->f_inode->i_ino == {d}/ {{ @writes = sum(1); }}
        \\interval:s:{d} {{ printf("TAMPER:%llu\n", (uint64)@writes); exit(); }}
        \\END {{ clear(@writes); }}
    , .{ device, inode, seconds });
    defer a.free(program);
    const result = try exec.run(a, &.{ "timeout", "-k", "1", "15", "bpftrace", "-q", "-e", program }, 64 * 1024);
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    return sampleResult(result.exit_code, result.stdout, result.stderr);
}

fn sampleResult(code: u8, stdout: []const u8, stderr: []const u8) !u64 {
    if (code == 124 or code == 137) return error.ProbeTimedOut;
    // Partial attachment or lost events must not masquerade as a clean zero.
    if (code != 0 or std.mem.trim(u8, stderr, " \r\n\t").len != 0) return error.ProbeFailed;
    return parseSample(stdout);
}

fn parseSample(raw: []const u8) !u64 {
    const line = std.mem.trim(u8, raw, " \r\n\t");
    const prefix = "TAMPER:";
    if (!std.mem.startsWith(u8, line, prefix)) return error.IncompleteSample;
    const digits = line[prefix.len..];
    for (digits) |c| if (!std.ascii.isDigit(c)) return error.IncompleteSample;
    return std.fmt.parseInt(u64, digits, 10) catch error.IncompleteSample;
}

test "tamper observation requires a complete count" {
    try std.testing.expectEqual(@as(u64, 0), try parseSample("TAMPER:0\n"));
    try std.testing.expectEqual(@as(u64, 12), try parseSample("TAMPER:12\n"));
    for ([_][]const u8{ "", "TAMPER:", "TAMPER:1\nerror", "TAMPER:-1", "TAMPER:0\nTAMPER:0", "TAMPER:18446744073709551616" }) |raw| try std.testing.expectError(error.IncompleteSample, parseSample(raw));
}

test "tamper observation never reports a failed probe as a zero" {
    for ([_]u8{ 124, 137 }) |code| try std.testing.expectError(error.ProbeTimedOut, sampleResult(code, "TAMPER:0", ""));
    try std.testing.expectError(error.ProbeFailed, sampleResult(1, "TAMPER:0", ""));
    try std.testing.expectError(error.ProbeFailed, sampleResult(0, "TAMPER:0", "lost events"));
}

test "tamper refuses overlapping probe without releasing its owner" {
    sampling.store(true, .release);
    defer sampling.store(false, .release);
    try std.testing.expectError(error.ProbeBusy, sampleWrites(std.testing.allocator, 1, 2, 1));
    try std.testing.expect(sampling.load(.acquire));
}

test "tamper rejects invalid and nonregular targets before tracing" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "relative", "", "/a\x00b" }) |path| try std.testing.expectError(error.InvalidPath, detectWrites(a, path));
    try std.testing.expectError(error.RegularFileRequired, detectWrites(a, "/"));
    try std.testing.expectError(error.RegularFileRequired, detectWrites(a, "/proc/self/exe"));
    try std.testing.expectError(error.FileNotFound, detectWrites(a, "/proc/self/no-such-tamper-target"));
}

var lsm_busy = std.atomic.Value(bool).init(false);

/// The one-shot helper exits after pinning; no process or request owns a guard.
pub fn lsm(a: std.mem.Allocator, operation: []const u8, path: []const u8) ![]const u8 {
    if (path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (lsm_busy.swap(true, .acq_rel)) return error.PolicyConflict;
    defer lsm_busy.store(false, .release);
    const helper = "/usr/libexec/hampanel/tamper_lsm.py";
    for ([_][]const u8{ helper, "/usr/bin/timeout", "/usr/bin/python3" }) |tool| if (!exec.commandExists(a, tool)) return error.Unsupported;
    const result = try exec.run(a, &.{ "/usr/bin/timeout", "-k", "1", "10", "/usr/bin/python3", "-I", helper, operation, path }, 2 * 1024 * 1024);
    defer a.free(result.stderr);
    errdefer a.free(result.stdout);
    switch (result.exit_code) {
        0 => return result.stdout,
        10 => return error.Unsupported,
        11 => return error.InvalidPath,
        12 => return error.FileNotFound,
        13 => return error.PolicyConflict,
        124, 137 => return error.LoaderTimedOut,
        else => return error.LoaderFailed,
    }
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
