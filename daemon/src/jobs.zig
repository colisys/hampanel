const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const exec = @import("shared").exec;
const engine_mod = @import("runtime/engine.zig");

pub const Status = enum { running, succeeded, failed, cancelled };

pub const Snapshot = struct {
    id: []const u8,
    kind: []const u8,
    label: []const u8,
    status: []const u8,
    output: []const u8,
    truncated: bool,
    exit_code: ?u8,
    started_at: i64,
    finished_at: ?i64,
    result_path: ?[]const u8,
};

const max_output = 4 * 1024 * 1024;
const snapshot_limit = 256 * 1024;
const ttl_seconds = 3600;
const max_jobs = 64;

const Job = struct {
    id: []const u8,
    kind: []const u8,
    label: []const u8,
    status: Status = .running,
    output: std.array_list.Managed(u8),
    truncated: bool = false,
    exit_code: ?u8 = null,
    started_at: i64,
    finished_at: ?i64 = null,
    result_path: ?[]const u8 = null,
    pid: ?u32 = null,
    cancel_requested: bool = false,
    mutex: std.Io.Mutex = .init,
};

const Task = struct {
    job: *Job,
    argv: [][]const u8,
    engine: engine_mod.Engine,
    socket: []const u8,
};

var registry: std.StringHashMap(*Job) = undefined;
var registry_mutex: std.Io.Mutex = .init;
var initialized = false;

pub const Options = struct {
    kind: []const u8,
    label: []const u8,
    argv: []const []const u8,
    engine: engine_mod.Engine,
    socket: []const u8 = "",
    result_path: ?[]const u8 = null,
};

pub fn start(options: Options) ![]const u8 {
    const gpa = std.heap.page_allocator;
    var raw: [8]u8 = undefined;
    compat.randomBytes(&raw);
    const id = try std.fmt.allocPrint(gpa, "{s}", .{std.fmt.bytesToHex(raw, .lower)});
    errdefer gpa.free(id);

    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    const kind = try gpa.dupe(u8, options.kind);
    errdefer gpa.free(kind);
    const label = try gpa.dupe(u8, options.label);
    errdefer gpa.free(label);
    const result_path = if (options.result_path) |path| try gpa.dupe(u8, path) else null;
    errdefer if (result_path) |path| gpa.free(path);
    job.* = .{
        .id = id,
        .kind = kind,
        .label = label,
        .output = std.array_list.Managed(u8).init(gpa),
        .started_at = compat.timestamp(),
        .result_path = result_path,
    };

    const argv = try gpa.alloc([]const u8, options.argv.len);
    errdefer gpa.free(argv);
    var copied: usize = 0;
    errdefer for (argv[0..copied]) |arg| gpa.free(arg);
    for (options.argv, 0..) |arg, index| {
        argv[index] = try gpa.dupe(u8, arg);
        copied += 1;
    }

    const task = try gpa.create(Task);
    errdefer gpa.destroy(task);
    const socket = try gpa.dupe(u8, options.socket);
    errdefer gpa.free(socket);
    task.* = .{
        .job = job,
        .argv = argv,
        .engine = options.engine,
        .socket = socket,
    };

    registry_mutex.lockUncancelable(compat.io());
    defer registry_mutex.unlock(compat.io());
    ensureLocked();
    pruneLocked();
    if (registry.count() >= max_jobs) return error.TooManyJobs;
    try registry.put(id, job);

    const thread = std.Thread.spawn(.{}, worker, .{task}) catch {
        _ = registry.remove(id);
        return error.SpawnFailed;
    };
    thread.detach();
    return id;
}

pub fn get(allocator: std.mem.Allocator, id: []const u8) !?Snapshot {
    registry_mutex.lockUncancelable(compat.io());
    defer registry_mutex.unlock(compat.io());
    ensureLocked();
    pruneLocked();
    const found = registry.get(id);
    const job = found orelse return null;

    job.mutex.lockUncancelable(compat.io());
    defer job.mutex.unlock(compat.io());
    const offset = if (job.output.items.len > snapshot_limit) job.output.items.len - snapshot_limit else 0;
    return .{
        .id = try allocator.dupe(u8, job.id),
        .kind = try allocator.dupe(u8, job.kind),
        .label = try allocator.dupe(u8, job.label),
        .status = statusName(job.status),
        .output = try allocator.dupe(u8, job.output.items[offset..]),
        .truncated = job.truncated or offset > 0,
        .exit_code = job.exit_code,
        .started_at = job.started_at,
        .finished_at = job.finished_at,
        .result_path = if (job.result_path) |path| try allocator.dupe(u8, path) else null,
    };
}

pub fn cancel(id: []const u8) bool {
    registry_mutex.lockUncancelable(compat.io());
    defer registry_mutex.unlock(compat.io());
    ensureLocked();
    const job = registry.get(id) orelse return false;
    job.mutex.lockUncancelable(compat.io());
    defer job.mutex.unlock(compat.io());
    if (job.status != .running) return false;
    if (builtin.os.tag != .windows) {
        if (job.pid) |pid| {
            std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch return false;
            job.cancel_requested = true;
            return true;
        }
    }
    return false;
}

fn worker(task: *Task) void {
    const gpa = std.heap.page_allocator;
    const io = compat.io();
    defer {
        for (task.argv) |arg| gpa.free(arg);
        gpa.free(task.argv);
        gpa.free(task.socket);
        gpa.destroy(task);
    }

    var env_map: ?std.process.Environ.Map = null;
    if (task.socket.len > 0) {
        env_map = compat.cloneEnv(gpa) catch {
            finish(task.job, .failed, null);
            return;
        };
        if (env_map) |*map| {
            const key = engine_mod.hostVariable(task.engine, task.argv);
            map.put(key, task.socket) catch {
                map.deinit();
                finish(task.job, .failed, null);
                return;
            };
        }
    }
    defer if (env_map) |*map| map.deinit();

    if (task.argv.len == 0 or !exec.commandExists(gpa, task.argv[0])) {
        finish(task.job, .failed, null);
        return;
    }

    var child = std.process.spawn(io, .{
        .argv = task.argv,
        .environ_map = if (env_map) |*map| map else null,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        finish(task.job, .failed, null);
        return;
    };

    if (builtin.os.tag != .windows) {
        if (child.id) |value| {
            task.job.mutex.lockUncancelable(compat.io());
            task.job.pid = @intCast(value);
            task.job.mutex.unlock(compat.io());
        }
    }

    const stdout_thread = std.Thread.spawn(.{}, pump, .{ task.job, child.stdout.? }) catch null;
    const stderr_thread = std.Thread.spawn(.{}, pump, .{ task.job, child.stderr.? }) catch null;
    const term = child.wait(io) catch null;
    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();

    const exit_code: ?u8 = if (term) |value| switch (value) {
        .exited => |code| code,
        else => 255,
    } else null;
    finish(task.job, if (exit_code == 0) .succeeded else .failed, exit_code);
}

fn pump(job: *Job, file: std.Io.File) void {
    const io = compat.io();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io, &.{&buffer}) catch break;
        if (count == 0) break;
        append(job, buffer[0..count]);
    }
}

fn append(job: *Job, bytes: []const u8) void {
    if (bytes.len == 0) return;
    job.mutex.lockUncancelable(compat.io());
    defer job.mutex.unlock(compat.io());

    if (bytes.len >= max_output) {
        job.output.clearRetainingCapacity();
        job.output.appendSlice(bytes[bytes.len - max_output ..]) catch {};
        job.truncated = true;
        return;
    }

    const total = job.output.items.len + bytes.len;
    if (total > max_output) {
        const drop = total - max_output;
        if (drop >= job.output.items.len) {
            job.output.clearRetainingCapacity();
        } else {
            std.mem.copyForwards(u8, job.output.items[0..], job.output.items[drop..]);
            job.output.shrinkRetainingCapacity(job.output.items.len - drop);
        }
        job.truncated = true;
    }
    job.output.appendSlice(bytes) catch {};
}

fn finish(job: *Job, status: Status, exit_code: ?u8) void {
    job.mutex.lockUncancelable(compat.io());
    defer job.mutex.unlock(compat.io());
    job.status = if (job.cancel_requested) .cancelled else status;
    job.exit_code = exit_code;
    job.finished_at = compat.timestamp();
    job.pid = null;
}

fn ensureLocked() void {
    if (initialized) return;
    registry = std.StringHashMap(*Job).init(std.heap.page_allocator);
    initialized = true;
}

fn pruneLocked() void {
    if (!initialized) return;
    const now = compat.timestamp();
    var iterator = registry.iterator();
    while (iterator.next()) |entry| {
        const job = entry.value_ptr.*;
        job.mutex.lockUncancelable(compat.io());
        const expired = job.status != .running and job.finished_at != null and
            now - job.finished_at.? > ttl_seconds;
        job.mutex.unlock(compat.io());
        if (expired) {
            _ = registry.remove(job.id);
            const allocator = std.heap.page_allocator;
            allocator.free(job.id);
            allocator.free(job.kind);
            allocator.free(job.label);
            if (job.result_path) |path| allocator.free(path);
            job.output.deinit();
            allocator.destroy(job);
            iterator = registry.iterator();
        }
    }
}

fn statusName(status: Status) []const u8 {
    return switch (status) {
        .running => "running",
        .succeeded => "succeeded",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

test "cancelled worker retains cancelled terminal status" {
    var job = Job{
        .id = "test",
        .kind = "test",
        .label = "test",
        .output = std.array_list.Managed(u8).init(std.testing.allocator),
        .started_at = 0,
        .cancel_requested = true,
    };
    defer job.output.deinit();
    finish(&job, .failed, 255);
    try std.testing.expectEqual(Status.cancelled, job.status);
    try std.testing.expect(job.finished_at != null);
    try std.testing.expect(job.pid == null);
}
