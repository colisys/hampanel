// Built-in update channel. Binary installs can query GitHub releases and apply
// updates; source installs have updates disabled and refuse to schedule checks.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const exec = @import("shared").exec;
const version = @import("version.zig");

const update_cron_path = "/etc/cron.d/hampanel-update";
const update_begin_marker = "# BEGIN HAMPANEL UPDATE";
const update_end_marker = "# END HAMPANEL UPDATE";
const update_task_name = "\\Hampanel\\update";

pub const State = struct {
    checked_at: i64 = 0,
    current_version: []const u8 = "",
    latest_version: []const u8 = "",
    update_available: bool = false,
    channel: []const u8 = "",
    install_mode: []const u8 = "",
    error_message: []const u8 = "",
};

pub const ApplyOutcome = struct {
    updated: bool,
    message: []const u8,
};

pub const ApplyError = error{
    UpdateDisabled,
    UnsupportedPlatform,
    NothingToDo,
    DownloadFailed,
    ChecksumMismatch,
    ExtractFailed,
    ReplaceFailed,
    RestartFailed,
    SpawnFailed,
    OutOfMemory,
};

/// Returns whether `latest` is newer than `current`. Versions look like
/// `0.1.0+abc1234`; nightly builds share a semantic version but differ by commit.
pub fn updateAvailable(current: []const u8, latest: []const u8) bool {
    if (latest.len == 0) return false;
    if (std.mem.eql(u8, current, latest)) return false;

    const current_base = baseVersion(current);
    const latest_base = baseVersion(latest);
    const order = compareBaseVersion(current_base, latest_base);
    if (order < 0) return true;
    if (order > 0) return false;
    return true;
}

/// Source installs must not schedule update checks; the panel API uses this to
/// reject user-created cron entries that invoke the updater.
pub fn isUpdateCommand(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, "hampaneld update") != null) return true;
    if (std.mem.indexOf(u8, command, "hampaneld.exe update") != null) return true;
    return false;
}

pub fn check(allocator: std.mem.Allocator, cfg: config.Config) State {
    var state = State{
        .checked_at = std.time.timestamp(),
        .current_version = version.version,
        .channel = cfg.update_channel,
        .install_mode = cfg.install_mode,
    };

    if (!cfg.updatesEnabled()) {
        state.error_message = "update channel is disabled for source installs";
        saveState(allocator, cfg, state) catch {};
        return state;
    }

    const latest = fetchLatestVersion(allocator, cfg) catch |err| {
        state.error_message = @errorName(err);
        saveState(allocator, cfg, state) catch {};
        return state;
    };
    state.latest_version = latest;
    state.update_available = updateAvailable(version.version, latest);
    saveState(allocator, cfg, state) catch {};
    return state;
}

pub fn loadState(allocator: std.mem.Allocator, cfg: config.Config) State {
    const path = statePath(allocator, cfg) catch return .{};
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024) catch return .{};
    defer allocator.free(data);
    return std.json.parseFromSliceLeaky(State, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{};
}

pub fn apply(allocator: std.mem.Allocator, cfg: config.Config) ApplyError!ApplyOutcome {
    if (!cfg.updatesEnabled()) return error.UpdateDisabled;
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.UnsupportedPlatform;

    const latest = fetchLatestVersion(allocator, cfg) catch return error.DownloadFailed;
    if (!updateAvailable(version.version, latest)) return error.NothingToDo;

    const workdir = workDir(allocator, cfg) catch return error.DownloadFailed;
    defer allocator.free(workdir);
    std.fs.cwd().deleteTree(workdir) catch {};
    std.fs.cwd().makePath(workdir) catch return error.DownloadFailed;

    const asset = assetName();
    const base = releaseBase(allocator, cfg) catch return error.OutOfMemory;
    const archive_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, asset }) catch return error.OutOfMemory;
    const sums_url = std.fmt.allocPrint(allocator, "{s}/SHA256SUMS.txt", .{base}) catch return error.OutOfMemory;
    const archive_path = std.fs.path.join(allocator, &.{ workdir, asset }) catch return error.OutOfMemory;
    const sums_path = std.fs.path.join(allocator, &.{ workdir, "SHA256SUMS.txt" }) catch return error.OutOfMemory;

    download(allocator, archive_url, archive_path) catch return error.DownloadFailed;
    download(allocator, sums_url, sums_path) catch return error.ChecksumMismatch;
    const sums = std.fs.cwd().readFileAlloc(allocator, sums_path, 1024 * 1024) catch return error.ChecksumMismatch;
    const expected = expectedHash(sums, asset) orelse return error.ChecksumMismatch;
    if (!hashMatches(archive_path, expected)) return error.ChecksumMismatch;

    if (builtin.os.tag == .linux) {
        extractLinux(allocator, archive_path, workdir) catch return error.ExtractFailed;
        replaceLinux(allocator, workdir, cfg) catch return error.ReplaceFailed;
        std.fs.cwd().deleteTree(workdir) catch {};
    } else {
        extractWindows(allocator, archive_path, workdir) catch return error.ExtractFailed;
        replaceWindows(allocator, workdir, cfg) catch return error.ReplaceFailed;
    }

    const state = State{
        .checked_at = std.time.timestamp(),
        .current_version = latest,
        .latest_version = latest,
        .update_available = false,
        .channel = cfg.update_channel,
        .install_mode = cfg.install_mode,
    };
    saveState(allocator, cfg, state) catch {};

    return .{ .updated = true, .message = "update downloaded and applied" };
}

pub const ScheduleOutcome = struct {
    installed: bool,
    message: []const u8,
};

pub fn installSchedule(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    self_exe: []const u8,
    config_path: []const u8,
) !ScheduleOutcome {
    if (!cfg.updatesEnabled()) return error.UpdateDisabled;

    if (builtin.os.tag == .windows) {
        const task_run = try std.fmt.allocPrint(
            allocator,
            "\"{s}\" update --auto --config \"{s}\"",
            .{ self_exe, config_path },
        );
        const result = try exec.run(allocator, &.{
            "schtasks.exe", "/Create", "/F", "/TN", update_task_name, "/TR", task_run,
            "/SC",    "DAILY",   "/ST", "04:17", "/RU", "SYSTEM", "/RL", "HIGHEST",
        }, 1024 * 1024);
        if (!result.ok()) return .{ .installed = false, .message = result.stderr };
        return .{ .installed = true, .message = "scheduled daily update check" };
    }

    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    if (isRoot()) {
        const body = try std.fmt.allocPrint(
            allocator,
            "# Managed by Hampanel\nSHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n" ++
                "17 4 * * * root {s} update --auto --config {s}\n",
            .{ self_exe, config_path },
        );
        if (std.fs.path.dirname(update_cron_path)) |dir| std.fs.cwd().makePath(dir) catch {};
        var file = std.fs.cwd().createFile(update_cron_path, .{ .mode = 0o644 }) catch
            return .{ .installed = false, .message = "cannot write update cron file" };
        defer file.close();
        file.writeAll(body) catch return .{ .installed = false, .message = "cannot write update cron file" };
        return .{ .installed = true, .message = "scheduled daily update check" };
    }

    const line = try std.fmt.allocPrint(allocator, "17 4 * * * {s} update --auto --config {s}", .{ self_exe, config_path });
    const existing = readUserCrontab(allocator);
    const rewritten = try rewriteUserCrontab(allocator, existing, line);
    const result = installUserCrontab(allocator, rewritten) catch
        return .{ .installed = false, .message = "crontab unavailable" };
    return .{ .installed = result.ok(), .message = if (result.ok()) "scheduled daily update check" else textOf(result) };
}

pub fn removeSchedule(allocator: std.mem.Allocator) !ScheduleOutcome {
    if (builtin.os.tag == .windows) {
        const result = try exec.run(allocator, &.{ "schtasks.exe", "/Delete", "/F", "/TN", update_task_name }, 1024 * 1024);
        return .{ .installed = false, .message = if (result.ok()) "update check removed" else textOf(result) };
    }
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    if (isRoot()) {
        std.fs.deleteFileAbsolute(update_cron_path) catch {};
        return .{ .installed = false, .message = "update check removed" };
    }

    const existing = readUserCrontab(allocator);
    const rewritten = try rewriteUserCrontab(allocator, existing, null);
    const result = installUserCrontab(allocator, rewritten) catch
        return .{ .installed = false, .message = "crontab unavailable" };
    return .{ .installed = false, .message = if (result.ok()) "update check removed" else textOf(result) };
}

pub fn scheduleInstalled(allocator: std.mem.Allocator) bool {
    if (builtin.os.tag == .windows) {
        const result = exec.run(allocator, &.{ "schtasks.exe", "/Query", "/TN", update_task_name }, 1024 * 1024) catch return false;
        return result.ok();
    }
    if (builtin.os.tag != .linux) return false;
    if (isRoot()) {
        std.fs.cwd().access(update_cron_path, .{}) catch return false;
        return true;
    }
    const existing = readUserCrontab(allocator);
    return std.mem.indexOf(u8, existing, update_begin_marker) != null;
}

// ------------------------------------------------------------------ internals

fn baseVersion(value: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, value, "+-") orelse value.len;
    return value[0..cut];
}

fn compareBaseVersion(a: []const u8, b: []const u8) i8 {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const an = ai.next();
        const bn = bi.next();
        if (an == null and bn == null) return 0;
        const av = std.fmt.parseInt(u64, std.mem.trim(u8, an orelse "0", " \t"), 10) catch 0;
        const bv = std.fmt.parseInt(u64, std.mem.trim(u8, bn orelse "0", " \t"), 10) catch 0;
        if (av < bv) return -1;
        if (av > bv) return 1;
    }
}

fn releaseBase(allocator: std.mem.Allocator, cfg: config.Config) ![]u8 {
    if (std.mem.eql(u8, cfg.update_channel, "stable") or std.mem.eql(u8, cfg.update_channel, "latest")) {
        return std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/latest/download", .{cfg.update_repo});
    }
    return std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/releases/download/{s}",
        .{ cfg.update_repo, cfg.update_channel },
    );
}

fn fetchLatestVersion(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    const base = try releaseBase(allocator, cfg);
    const url = try std.fmt.allocPrint(allocator, "{s}/version.txt", .{base});
    const text = try curlText(allocator, url);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '.') == null) return error.InvalidVersion;
    return trimmed;
}

fn curlText(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const result = try exec.run(allocator, &.{
        "curl", "-fsSL", "--retry", "2", "--connect-timeout", "15", "--max-time", "30",
        "-H", "User-Agent: hampaneld",
        url,
    }, 256 * 1024);
    if (!result.ok()) return error.HttpFailed;
    return result.stdout;
}

fn download(allocator: std.mem.Allocator, url: []const u8, path: []const u8) !void {
    const result = try exec.run(allocator, &.{
        "curl", "-fsSL", "--retry", "2", "--connect-timeout", "15", "--max-time", "600",
        "-H", "User-Agent: hampaneld", "-o", path, url,
    }, 256 * 1024);
    if (!result.ok()) return error.DownloadFailed;
}

fn assetName() []const u8 {
    return if (builtin.os.tag == .windows)
        "hampanel-daemon-windows-x86_64.zip"
    else
        "hampanel-daemon-linux-x86_64.tar.gz";
}

fn expectedHash(sums: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const hash = tokens.next() orelse continue;
        const name = tokens.next() orelse continue;
        const clean = std.mem.trimLeft(u8, name, "*");
        if (std.mem.eql(u8, clean, asset)) return hash;
    }
    return null;
}

fn hashMatches(path: []const u8, expected: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return false;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(hex[0..], expected);
}

fn extractLinux(allocator: std.mem.Allocator, archive: []const u8, workdir: []const u8) !void {
    const result = try exec.run(allocator, &.{ "tar", "-xzf", archive, "-C", workdir }, 1024 * 1024);
    if (!result.ok()) return error.ExtractFailed;
}

fn replaceLinux(allocator: std.mem.Allocator, workdir: []const u8, cfg: config.Config) !void {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    const new_bin = try std.fs.path.join(allocator, &.{ workdir, "hampaneld" });
    const staged = try std.fmt.allocPrint(allocator, "{s}.new", .{self_exe});
    std.fs.cwd().deleteFile(staged) catch {};
    std.fs.cwd().copyFile(new_bin, std.fs.cwd(), staged, .{}) catch return error.ReplaceFailed;
    setExecutable(staged) catch return error.ReplaceFailed;
    std.fs.cwd().rename(staged, self_exe) catch return error.ReplaceFailed;

    const risk_new = std.fs.path.join(allocator, &.{ workdir, "hampanel-risk" }) catch return;
    if (std.fs.path.dirname(self_exe)) |dir| {
        const risk_old = std.fs.path.join(allocator, &.{ dir, "hampanel-risk" }) catch return;
        if (std.fs.cwd().access(risk_old, .{})) |_| {
            const staged_risk = std.fmt.allocPrint(allocator, "{s}.new", .{risk_old}) catch return;
            std.fs.cwd().deleteFile(staged_risk) catch {};
            std.fs.cwd().copyFile(risk_new, std.fs.cwd(), staged_risk, .{}) catch return;
            setExecutable(staged_risk) catch return;
            std.fs.cwd().rename(staged_risk, risk_old) catch return;
        } else |_| {}
    }

    const result = exec.run(allocator, &.{ "systemctl", "restart", cfg.service_name }, 1024 * 1024) catch
        return error.RestartFailed;
    if (!result.ok()) return error.RestartFailed;
}

fn extractWindows(allocator: std.mem.Allocator, archive: []const u8, workdir: []const u8) !void {
    const script = try std.fmt.allocPrint(
        allocator,
        "Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force",
        .{ archive, workdir },
    );
    const result = try exec.run(allocator, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script }, 1024 * 1024);
    if (!result.ok()) return error.ExtractFailed;
}

fn replaceWindows(allocator: std.mem.Allocator, workdir: []const u8, cfg: config.Config) !void {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    const install_dir = std.fs.path.dirname(self_exe) orelse return error.ReplaceFailed;

    const script_path = try std.fs.path.join(allocator, &.{ workdir, "apply-update.cmd" });
    const script = try std.fmt.allocPrint(
        allocator,
        "@echo off\r\n" ++
            "timeout /t 3 /nobreak >nul\r\n" ++
            "sc stop \"{s}\" >nul 2>&1\r\n" ++
            "copy /y \"{s}\\*\" \"{s}\\\" >nul\r\n" ++
            "sc start \"{s}\" >nul 2>&1\r\n" ++
            "del \"%~f0\"\r\n",
        .{ cfg.service_name, workdir, install_dir, cfg.service_name },
    );
    var file = std.fs.cwd().createFile(script_path, .{}) catch return error.ReplaceFailed;
    defer file.close();
    file.writeAll(script) catch return error.ReplaceFailed;

    const result = try exec.run(allocator, &.{ "cmd.exe", "/c", "start", "", "/b", script_path }, 1024 * 1024);
    if (!result.ok()) return error.ReplaceFailed;
}

fn statePath(allocator: std.mem.Allocator, cfg: config.Config) ![]u8 {
    return std.fs.path.join(allocator, &.{ cfg.data_dir, "update-state.json" });
}

fn workDir(allocator: std.mem.Allocator, cfg: config.Config) ![]u8 {
    return std.fs.path.join(allocator, &.{ cfg.data_dir, "update-work" });
}

fn saveState(allocator: std.mem.Allocator, cfg: config.Config, state: State) !void {
    const path = try statePath(allocator, cfg);
    defer allocator.free(path);
    const body = try std.json.stringifyAlloc(allocator, state, .{ .whitespace = .indent_2 });
    defer allocator.free(body);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(body);
    try file.writeAll("\n");
}

fn isRoot() bool {
    if (builtin.os.tag == .windows) return false;
    return std.os.linux.geteuid() == 0;
}

fn setExecutable(path: []const u8) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    try file.chmod(0o755);
}

fn readUserCrontab(allocator: std.mem.Allocator) []const u8 {
    const result = exec.run(allocator, &.{ "crontab", "-l" }, 1024 * 1024) catch return "";
    if (!result.ok()) return "";
    return result.stdout;
}

fn rewriteUserCrontab(allocator: std.mem.Allocator, current: []const u8, line: ?[]const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    var inside = false;
    var lines = std.mem.splitScalar(u8, current, '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, trimmed, update_begin_marker)) {
            inside = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, update_end_marker)) {
            inside = false;
            continue;
        }
        if (inside) continue;
        try out.appendSlice(raw);
        try out.append('\n');
    }
    if (line) |value| {
        try out.writer().print("{s}\n{s}\n{s}\n", .{ update_begin_marker, value, update_end_marker });
    }
    return out.toOwnedSlice();
}

fn installUserCrontab(allocator: std.mem.Allocator, text: []const u8) !exec.Result {
    var random: [6]u8 = undefined;
    std.crypto.random.bytes(&random);
    const path = try std.fmt.allocPrint(allocator, "/tmp/hampanel-update-cron-{s}", .{std.fmt.bytesToHex(random, .lower)});
    errdefer std.fs.deleteFileAbsolute(path) catch {};
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    try file.writeAll(text);
    file.close();
    const result = try exec.run(allocator, &.{ "crontab", path }, 1024 * 1024);
    std.fs.deleteFileAbsolute(path) catch {};
    return result;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}

test "version comparison handles semver and nightly commits" {
    try std.testing.expect(updateAvailable("0.1.0+aaaa", "0.1.1+bbbb"));
    try std.testing.expect(updateAvailable("0.1.0+aaaa", "0.2.0+aaaa"));
    try std.testing.expect(!updateAvailable("0.1.0+aaaa", "0.1.0+aaaa"));
    try std.testing.expect(!updateAvailable("0.2.0+aaaa", "0.1.9+zzzz"));
    try std.testing.expect(updateAvailable("0.1.0+aaaa", "0.1.0+bbbb"));
    try std.testing.expect(!updateAvailable("0.1.0+aaaa", ""));
}

test "update command detection" {
    try std.testing.expect(isUpdateCommand("/usr/local/bin/hampaneld update --auto"));
    try std.testing.expect(isUpdateCommand("C:\\Program Files\\Hampanel\\hampaneld.exe update --check"));
    try std.testing.expect(!isUpdateCommand("/usr/bin/apt update"));
    try std.testing.expect(!isUpdateCommand("hampaneld init"));
}

test "user crontab rewrite adds and removes managed block" {
    const allocator = std.testing.allocator;
    const with_block = try rewriteUserCrontab(
        allocator,
        "0 * * * * /usr/bin/foo\n",
        "17 4 * * * /usr/local/bin/hampaneld update --auto",
    );
    defer allocator.free(with_block);
    try std.testing.expect(std.mem.indexOf(u8, with_block, update_begin_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, with_block, "hampaneld update --auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_block, "/usr/bin/foo") != null);

    const removed = try rewriteUserCrontab(allocator, with_block, null);
    defer allocator.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, update_begin_marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "/usr/bin/foo") != null);
}

test "state json round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    var cfg = config.Config{};
    cfg.data_dir = dir;
    cfg.install_mode = "binary";

    const state = State{
        .checked_at = 123,
        .current_version = "0.1.0+aaaa",
        .latest_version = "0.1.1+bbbb",
        .update_available = true,
        .channel = "stable",
        .install_mode = "binary",
    };
    try saveState(allocator, cfg, state);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const loaded = loadState(arena.allocator(), cfg);
    try std.testing.expect(loaded.update_available);
    try std.testing.expectEqualStrings("0.1.1+bbbb", loaded.latest_version);
}
