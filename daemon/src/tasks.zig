const std = @import("std");
const compat = @import("compat");
const db = @import("db.zig");
const log = @import("log.zig");

pub const max_output: u64 = 16 * 1024 * 1024;
pub const max_queued = 200;
pub const max_running = 4;
const ttl_days = 7;
const ttl_ms: i64 = ttl_days * 24 * 60 * 60 * 1000;
const max_finished = 500;

pub const Status = enum {
    queued,
    running,
    canceling,
    succeeded,
    failed,
    canceled,
    interrupted,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn terminal(self: Status) bool {
        return switch (self) {
            .queued, .running, .canceling => false,
            else => true,
        };
    }
};

pub const Summary = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    status: []const u8,
    phase: []const u8,
    progress: ?i64,
    created_at: i64,
    started_at: ?i64,
    finished_at: ?i64,
    updated_at: i64,
    owner_cn: []const u8,
};

pub const Detail = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    status: []const u8,
    phase: []const u8,
    progress: ?i64,
    params: []const u8,
    result: []const u8,
    error_text: []const u8,
    output_path: []const u8,
    output_base: i64,
    output_bytes: i64,
    output_truncated: bool,
    created_at: i64,
    started_at: ?i64,
    finished_at: ?i64,
    updated_at: i64,
    owner_cn: []const u8,
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    file: compat.File,
    bytes: u64 = 0,
    truncated: bool = false,

    pub fn append(self: *Output, data: []const u8) !void {
        if (data.len == 0) return;
        if (self.bytes >= max_output) {
            self.truncated = true;
            return;
        }
        const room: usize = @intCast(@min(max_output - self.bytes, data.len));
        try self.file.writeAll(data[0..room]);
        self.bytes += room;
        if (room < data.len) self.truncated = true;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    manager: *Manager,
    task_id: []const u8,
    params_json: []const u8,
    params: std.json.Value,
    output: *Output,
    cancelled: *std.atomic.Value(bool),
    phase: []const u8 = "",
    progress: ?u8 = null,
    result: []const u8 = "",

    pub fn write(self: *Context, bytes: []const u8) !void {
        try self.output.append(bytes);
    }

    pub fn isCancelled(self: *Context) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn setPhase(self: *Context, phase: []const u8) !void {
        self.phase = phase;
        try self.manager.updateProgress(self.task_id, self.phase, self.progress);
    }

    pub fn setProgress(self: *Context, progress: u8) !void {
        self.progress = progress;
        try self.manager.updateProgress(self.task_id, self.phase, self.progress);
    }
};

pub const Handler = *const fn (*Context) anyerror!void;

pub const Spec = struct {
    kind: []const u8,
    lock_key: []const u8 = "",
    handler: Handler,
};

const Task = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    params_json: []const u8,
    lock_key: []const u8,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    database: *db.Db,
    data_dir: []const u8,
    mutex: std.Io.Mutex = .init,
    active: std.StringHashMap(*Task),
    specs: std.StringHashMap(Spec),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scheduler: ?std.Thread = null,
    last_prune: i64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db.Db,
        data_dir: []const u8,
    ) !*Manager {
        const self = try allocator.create(Manager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .database = database,
            .data_dir = try allocator.dupe(u8, data_dir),
            .active = std.StringHashMap(*Task).init(allocator),
            .specs = std.StringHashMap(Spec).init(allocator),
        };
        const dir = try self.tasksDir();
        defer allocator.free(dir);
        try compat.cwd().makePath(dir);
        try self.recover();
        return self;
    }

    pub fn deinit(self: *Manager) void {
        self.stop();
        if (self.scheduler) |thread| thread.join();
        self.scheduler = null;
        self.mutex.lockUncancelable(compat.io());
        var it = self.active.iterator();
        while (it.next()) |entry| self.freeTask(entry.value_ptr.*);
        self.active.deinit();
        self.mutex.unlock(compat.io());
        var specs = self.specs.iterator();
        while (specs.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.specs.deinit();
        self.allocator.free(self.data_dir);
        self.allocator.destroy(self);
    }

    pub fn register(self: *Manager, spec: Spec) !void {
        const key = try self.allocator.dupe(u8, spec.kind);
        try self.specs.put(key, spec);
    }

    pub fn start(self: *Manager) !void {
        if (self.scheduler != null) return;
        self.stopping.store(false, .release);
        self.scheduler = try std.Thread.spawn(.{}, schedulerLoop, .{self});
    }

    pub fn stop(self: *Manager) void {
        self.stopping.store(true, .release);
    }

    pub fn create(
        self: *Manager,
        allocator: std.mem.Allocator,
        kind: []const u8,
        title: []const u8,
        params_json: []const u8,
        idempotency_key: []const u8,
        owner_cn: []const u8,
    ) !Summary {
        const spec = self.specs.get(kind) orelse return error.UnknownKind;
        if (kind.len > 96 or title.len > 256 or idempotency_key.len > 128) {
            return error.InvalidTask;
        }
        if (params_json.len > 256 * 1024) return error.InvalidTask;
        _ = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.allocator,
            params_json,
            .{},
        ) catch return error.InvalidTask;

        if (idempotency_key.len > 0) {
            if (try self.findIdempotent(kind, idempotency_key)) |existing| {
                defer self.allocator.free(existing);
                if (try self.getSummary(allocator, existing)) |summary| return summary;
            }
        }

        if (try self.pendingCount() >= max_queued) return error.TooManyTasks;

        var random: [16]u8 = undefined;
        compat.randomBytes(&random);
        const id = try std.fmt.allocPrint(
            self.allocator,
            "{s}",
            .{std.fmt.bytesToHex(random, .lower)},
        );
        defer self.allocator.free(id);
        const output_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/tasks/{s}.log",
            .{ self.data_dir, id },
        );
        defer self.allocator.free(output_path);

        const now = compat.milliTimestamp();
        const final_title = if (title.len > 0) title else kind;
        try self.database.execute(
            "INSERT INTO tasks(id, kind, title, status, params, output_path, " ++
                "idempotency_key, lock_key, owner_cn, created_at, updated_at) " ++
                "VALUES(?1, ?2, ?3, 'queued', ?4, ?5, ?6, ?7, ?8, ?9, ?9)",
            &.{
                .{ .text = id },
                .{ .text = kind },
                .{ .text = final_title },
                .{ .text = params_json },
                .{ .text = output_path },
                .{ .text = idempotency_key },
                .{ .text = spec.lock_key },
                .{ .text = owner_cn },
                .{ .int = now },
            },
        );
        return .{
            .id = try allocator.dupe(u8, id),
            .kind = try allocator.dupe(u8, kind),
            .title = try allocator.dupe(u8, final_title),
            .status = try allocator.dupe(u8, "queued"),
            .phase = try allocator.dupe(u8, ""),
            .progress = null,
            .created_at = now,
            .started_at = null,
            .finished_at = null,
            .updated_at = now,
            .owner_cn = try allocator.dupe(u8, owner_cn),
        };
    }

    fn findIdempotent(self: *Manager, kind: []const u8, key: []const u8) !?[]u8 {
        self.database.lock();
        defer self.database.unlock();
        var statement = try self.database.prepareUnlocked(
            "SELECT id FROM tasks WHERE kind = ?1 AND idempotency_key = ?2 LIMIT 1",
        );
        defer statement.deinit();
        try statement.bind(&.{ .{ .text = kind }, .{ .text = key } });
        if (!(try statement.step())) return null;
        return try self.allocator.dupe(u8, statement.columnText(0));
    }

    fn pendingCount(self: *Manager) !usize {
        self.database.lock();
        defer self.database.unlock();
        var statement = try self.database.prepareUnlocked(
            "SELECT COUNT(*) FROM tasks WHERE status IN ('queued','running','canceling')",
        );
        defer statement.deinit();
        if (!(try statement.step())) return 0;
        return @intCast(statement.columnInt(0));
    }

    fn getSummary(self: *Manager, allocator: std.mem.Allocator, id: []const u8) !?Summary {
        self.database.lock();
        defer self.database.unlock();
        var statement = try self.database.prepareUnlocked(
            "SELECT id, kind, title, status, phase, progress, created_at, started_at, " ++
                "finished_at, updated_at, owner_cn FROM tasks WHERE id = ?1",
        );
        defer statement.deinit();
        try statement.bind(&.{.{ .text = id }});
        if (!(try statement.step())) return null;
        return try summaryFrom(&statement, allocator);
    }

    fn tasksDir(self: *Manager) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/tasks", .{self.data_dir});
    }

    fn recover(self: *Manager) !void {
        const now = compat.milliTimestamp();
        try self.database.execute(
            "UPDATE tasks SET status = 'interrupted', error = 'daemon restarted', " ++
                "finished_at = ?1, updated_at = ?1 WHERE status = 'running'",
            &.{.{ .int = now }},
        );
        try self.database.execute(
            "UPDATE tasks SET status = 'canceled', error = 'daemon restarted', " ++
                "finished_at = ?1, updated_at = ?1 WHERE status = 'canceling'",
            &.{.{ .int = now }},
        );
    }

    pub fn updateProgress(
        self: *Manager,
        id: []const u8,
        phase: []const u8,
        progress: ?u8,
    ) !void {
        try self.database.execute(
            "UPDATE tasks SET phase = ?1, progress = ?2, updated_at = ?3 WHERE id = ?4",
            &.{
                .{ .text = phase },
                if (progress) |value| .{ .int = value } else .{ .null = {} },
                .{ .int = compat.milliTimestamp() },
                .{ .text = id },
            },
        );
    }

    pub fn list(
        self: *Manager,
        allocator: std.mem.Allocator,
        since: i64,
        active_only: bool,
        limit: usize,
    ) ![]Summary {
        self.database.lock();
        defer self.database.unlock();
        const sql = if (active_only)
            "SELECT id, kind, title, status, phase, progress, created_at, started_at, " ++
                "finished_at, updated_at, owner_cn FROM tasks " ++
                "WHERE status IN ('queued','running','canceling') " ++
                "ORDER BY updated_at DESC LIMIT ?1"
        else
            "SELECT id, kind, title, status, phase, progress, created_at, started_at, " ++
                "finished_at, updated_at, owner_cn FROM tasks " ++
                "WHERE updated_at > ?2 ORDER BY updated_at DESC LIMIT ?1";
        var statement = try self.database.prepareUnlocked(sql);
        defer statement.deinit();
        if (active_only) {
            try statement.bind(&.{.{ .int = @intCast(limit) }});
        } else {
            try statement.bind(&.{
                .{ .int = @intCast(limit) },
                .{ .int = since },
            });
        }
        var items = std.array_list.Managed(Summary).init(allocator);
        while (try statement.step()) try items.append(try summaryFrom(&statement, allocator));
        return items.items;
    }

    pub fn get(self: *Manager, allocator: std.mem.Allocator, id: []const u8) !?Detail {
        self.database.lock();
        defer self.database.unlock();
        var statement = try self.database.prepareUnlocked(
            "SELECT id, kind, title, status, phase, progress, params, result, error, " ++
                "output_path, output_base, output_bytes, output_truncated, created_at, " ++
                "started_at, finished_at, updated_at, owner_cn FROM tasks WHERE id = ?1",
        );
        defer statement.deinit();
        try statement.bind(&.{.{ .text = id }});
        if (!(try statement.step())) return null;
        return .{
            .id = try allocator.dupe(u8, statement.columnText(0)),
            .kind = try allocator.dupe(u8, statement.columnText(1)),
            .title = try allocator.dupe(u8, statement.columnText(2)),
            .status = try allocator.dupe(u8, statement.columnText(3)),
            .phase = try allocator.dupe(u8, statement.columnText(4)),
            .progress = if (statement.columnIsNull(5)) null else statement.columnInt(5),
            .params = try allocator.dupe(u8, statement.columnText(6)),
            .result = try allocator.dupe(u8, statement.columnText(7)),
            .error_text = try allocator.dupe(u8, statement.columnText(8)),
            .output_path = try allocator.dupe(u8, statement.columnText(9)),
            .output_base = statement.columnInt(10),
            .output_bytes = statement.columnInt(11),
            .output_truncated = statement.columnInt(12) != 0,
            .created_at = statement.columnInt(13),
            .started_at = if (statement.columnIsNull(14)) null else statement.columnInt(14),
            .finished_at = if (statement.columnIsNull(15)) null else statement.columnInt(15),
            .updated_at = statement.columnInt(16),
            .owner_cn = try allocator.dupe(u8, statement.columnText(17)),
        };
    }

    pub fn cancel(self: *Manager, id: []const u8) bool {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        const task = self.active.get(id) orelse return false;
        task.cancel.store(true, .release);
        self.database.execute(
            "UPDATE tasks SET status = 'canceling', updated_at = ?1 WHERE id = ?2",
            &.{ .{ .int = compat.milliTimestamp() }, .{ .text = id } },
        ) catch {};
        return true;
    }

    pub fn prune(self: *Manager) !void {
        try self.pruneWithCap(max_finished);
    }

    pub fn pruneWithCap(self: *Manager, keep: usize) !void {
        const now = compat.milliTimestamp();
        const stale = try self.selectExpired(now - ttl_ms);
        defer self.allocator.free(stale);
        for (stale) |item| try self.drop(item.id, item.output_path);
        const excess = try self.excessFinished(keep);
        defer self.allocator.free(excess);
        for (excess) |item| try self.drop(item.id, item.output_path);
    }

    const Prunable = struct { id: []u8, output_path: []u8 };

    fn selectExpired(self: *Manager, cutoff: i64) ![]Prunable {
        return self.selectPrunable(
            "SELECT id, output_path FROM tasks WHERE finished_at IS NOT NULL " ++
                "AND updated_at < ?1 ORDER BY updated_at ASC LIMIT 200",
            &.{.{ .int = cutoff }},
        );
    }

    fn excessFinished(self: *Manager, keep: usize) ![]Prunable {
        return self.selectPrunable(
            "SELECT id, output_path FROM tasks WHERE finished_at IS NOT NULL " ++
                "ORDER BY updated_at DESC LIMIT -1 OFFSET ?1",
            &.{.{ .int = @intCast(keep) }},
        );
    }

    fn selectPrunable(self: *Manager, sql: []const u8, args: []const db.Value) ![]Prunable {
        self.database.lock();
        defer self.database.unlock();
        var statement = try self.database.prepareUnlocked(sql);
        defer statement.deinit();
        try statement.bind(args);
        var items = std.array_list.Managed(Prunable).init(self.allocator);
        errdefer {
            for (items.items) |item| {
                self.allocator.free(item.id);
                self.allocator.free(item.output_path);
            }
            items.deinit();
        }
        while (try statement.step()) {
            try items.append(.{
                .id = try self.allocator.dupe(u8, statement.columnText(0)),
                .output_path = try self.allocator.dupe(u8, statement.columnText(1)),
            });
        }
        return items.items;
    }

    fn drop(self: *Manager, id: []const u8, output_path: []const u8) !void {
        defer {
            self.allocator.free(id);
            self.allocator.free(output_path);
        }
        self.mutex.lockUncancelable(compat.io());
        const busy = self.active.get(id) != null;
        self.mutex.unlock(compat.io());
        if (busy) return;
        try self.database.execute("DELETE FROM tasks WHERE id = ?1", &.{.{ .text = id }});
        if (output_path.len > 0) compat.deleteFileAbsolute(output_path) catch {};
    }

    pub fn dismiss(self: *Manager, id: []const u8) !bool {
        const detail = try self.get(self.allocator, id) orelse return false;
        defer self.freeDetail(detail);
        const status = parseStatus(detail.status);
        if (!status.terminal()) return error.TaskRunning;
        try self.database.execute("DELETE FROM tasks WHERE id = ?1", &.{.{ .text = id }});
        compat.deleteFileAbsolute(detail.output_path) catch {};
        return true;
    }

    fn freeDetail(self: *Manager, detail: Detail) void {
        self.allocator.free(detail.id);
        self.allocator.free(detail.kind);
        self.allocator.free(detail.title);
        self.allocator.free(detail.status);
        self.allocator.free(detail.phase);
        self.allocator.free(detail.params);
        self.allocator.free(detail.result);
        self.allocator.free(detail.error_text);
        self.allocator.free(detail.output_path);
        self.allocator.free(detail.owner_cn);
    }

    fn freeTask(self: *Manager, task: *Task) void {
        self.allocator.free(task.id);
        self.allocator.free(task.kind);
        self.allocator.free(task.title);
        self.allocator.free(task.params_json);
        self.allocator.free(task.lock_key);
        self.allocator.destroy(task);
    }

    fn schedulerLoop(self: *Manager) void {
        while (!self.stopping.load(.acquire)) {
            self.runQueued() catch |err| log.warn("task scheduler: {s}", .{@errorName(err)});
            const now = compat.milliTimestamp();
            if (now - self.last_prune >= 5 * 60 * 1000) {
                self.last_prune = now;
                self.prune() catch |err| log.warn("task prune: {s}", .{@errorName(err)});
            }
            compat.sleep(250 * std.time.ns_per_ms);
        }
    }

    fn lockBusy(self: *Manager, key: []const u8) bool {
        self.mutex.lockUncancelable(compat.io());
        defer self.mutex.unlock(compat.io());
        var it = self.active.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.lock_key.len > 0 and
                std.mem.eql(u8, entry.value_ptr.*.lock_key, key)) return true;
        }
        return false;
    }

    fn runQueued(self: *Manager) !void {
        self.mutex.lockUncancelable(compat.io());
        const running = self.active.count();
        self.mutex.unlock(compat.io());
        if (running >= max_running) return;

        const Pending = struct {
            id: []u8,
            kind: []u8,
            title: []u8,
            params_json: []u8,
            lock_key: []u8,
        };
        var pending = std.array_list.Managed(Pending).init(self.allocator);
        defer {
            for (pending.items) |item| {
                self.allocator.free(item.id);
                self.allocator.free(item.kind);
                self.allocator.free(item.title);
                self.allocator.free(item.params_json);
                self.allocator.free(item.lock_key);
            }
            pending.deinit();
        }

        self.database.lock();
        {
            defer self.database.unlock();
            var statement = try self.database.prepareUnlocked(
                "SELECT id, kind, title, params, lock_key FROM tasks " ++
                    "WHERE status = 'queued' ORDER BY created_at ASC LIMIT 16",
            );
            defer statement.deinit();
            while (try statement.step()) {
                try pending.append(.{
                    .id = try self.allocator.dupe(u8, statement.columnText(0)),
                    .kind = try self.allocator.dupe(u8, statement.columnText(1)),
                    .title = try self.allocator.dupe(u8, statement.columnText(2)),
                    .params_json = try self.allocator.dupe(u8, statement.columnText(3)),
                    .lock_key = try self.allocator.dupe(u8, statement.columnText(4)),
                });
            }
        }

        for (pending.items) |item| {
            self.mutex.lockUncancelable(compat.io());
            const current = self.active.count();
            self.mutex.unlock(compat.io());
            if (current >= max_running) return;

            if (item.lock_key.len > 0 and self.lockBusy(item.lock_key)) continue;

            if (self.specs.get(item.kind) == null) {
                try self.database.execute(
                    "UPDATE tasks SET status = 'failed', error = 'unknown task kind', " ++
                        "finished_at = ?1, updated_at = ?1 WHERE id = ?2",
                    &.{ .{ .int = compat.milliTimestamp() }, .{ .text = item.id } },
                );
                continue;
            }

            const now = compat.milliTimestamp();
            try self.database.execute(
                "UPDATE tasks SET status = 'running', started_at = ?1, updated_at = ?1 " ++
                    "WHERE id = ?2 AND status = 'queued'",
                &.{ .{ .int = now }, .{ .text = item.id } },
            );
            if (self.database.changes() == 0) continue;

            const task = try self.allocator.create(Task);
            task.* = .{
                .id = try self.allocator.dupe(u8, item.id),
                .kind = try self.allocator.dupe(u8, item.kind),
                .title = try self.allocator.dupe(u8, item.title),
                .params_json = try self.allocator.dupe(u8, item.params_json),
                .lock_key = try self.allocator.dupe(u8, item.lock_key),
            };
            self.mutex.lockUncancelable(compat.io());
            try self.active.put(task.id, task);
            self.mutex.unlock(compat.io());
            const thread = std.Thread.spawn(.{}, worker, .{ self, task }) catch {
                self.mutex.lockUncancelable(compat.io());
                _ = self.active.remove(task.id);
                self.mutex.unlock(compat.io());
                self.freeTask(task);
                continue;
            };
            thread.detach();
        }
    }

    fn worker(self: *Manager, task: *Task) void {
        const spec = self.specs.get(task.kind) orelse {
            self.finish(task, .failed, "unknown task kind", "");
            return;
        };
        const output_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/tasks/{s}.log",
            .{ self.data_dir, task.id },
        ) catch {
            self.finish(task, .failed, "cannot allocate output path", "");
            return;
        };
        defer self.allocator.free(output_path);

        var output = Output{
            .allocator = self.allocator,
            .file = compat.createFileAbsolute(output_path, .{
                .truncate = true,
                .read = true,
                .mode = 0o600,
            }) catch {
                self.finish(task, .failed, "cannot create output file", "");
                return;
            },
        };
        defer output.file.close();

        const params = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.allocator,
            task.params_json,
            .{},
        ) catch {
            self.finish(task, .failed, "invalid task params", "");
            return;
        };
        var ctx = Context{
            .allocator = self.allocator,
            .manager = self,
            .task_id = task.id,
            .params_json = task.params_json,
            .params = params,
            .output = &output,
            .cancelled = &task.cancel,
        };
        spec.handler(&ctx) catch |err| {
            self.finishWithOutput(task, &output, .failed, @errorName(err), "");
            return;
        };
        const status: Status = if (task.cancel.load(.acquire)) .canceled else .succeeded;
        self.finishWithOutput(task, &output, status, "", ctx.result);
    }

    fn finishWithOutput(
        self: *Manager,
        task: *Task,
        output: *Output,
        status: Status,
        error_text: []const u8,
        result: []const u8,
    ) void {
        const now = compat.milliTimestamp();
        self.database.execute(
            "UPDATE tasks SET status = ?1, error = ?2, result = ?3, output_bytes = ?4, " ++
                "output_truncated = ?5, finished_at = ?6, updated_at = ?6, phase = '' " ++
                "WHERE id = ?7",
            &.{
                .{ .text = status.name() },
                .{ .text = error_text },
                .{ .text = result },
                .{ .int = @intCast(output.bytes) },
                .{ .int = if (output.truncated) 1 else 0 },
                .{ .int = now },
                .{ .text = task.id },
            },
        ) catch {};
        self.removeActive(task);
    }

    fn finish(
        self: *Manager,
        task: *Task,
        status: Status,
        error_text: []const u8,
        result: []const u8,
    ) void {
        const now = compat.milliTimestamp();
        self.database.execute(
            "UPDATE tasks SET status = ?1, error = ?2, result = ?3, finished_at = ?4, " ++
                "updated_at = ?4, phase = '' WHERE id = ?5",
            &.{
                .{ .text = status.name() },
                .{ .text = error_text },
                .{ .text = result },
                .{ .int = now },
                .{ .text = task.id },
            },
        ) catch {};
        self.removeActive(task);
    }

    fn removeActive(self: *Manager, task: *Task) void {
        self.mutex.lockUncancelable(compat.io());
        _ = self.active.remove(task.id);
        self.mutex.unlock(compat.io());
        self.freeTask(task);
    }
};

pub fn terminalStatus(value: []const u8) bool {
    return parseStatus(value).terminal();
}

fn parseStatus(value: []const u8) Status {
    if (std.mem.eql(u8, value, "queued")) return .queued;
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "canceling")) return .canceling;
    if (std.mem.eql(u8, value, "succeeded")) return .succeeded;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    if (std.mem.eql(u8, value, "canceled")) return .canceled;
    if (std.mem.eql(u8, value, "interrupted")) return .interrupted;
    return .failed;
}

fn summaryFrom(statement: *db.Statement, allocator: std.mem.Allocator) !Summary {
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0)),
        .kind = try allocator.dupe(u8, statement.columnText(1)),
        .title = try allocator.dupe(u8, statement.columnText(2)),
        .status = try allocator.dupe(u8, statement.columnText(3)),
        .phase = try allocator.dupe(u8, statement.columnText(4)),
        .progress = if (statement.columnIsNull(5)) null else statement.columnInt(5),
        .created_at = statement.columnInt(6),
        .started_at = if (statement.columnIsNull(7)) null else statement.columnInt(7),
        .finished_at = if (statement.columnIsNull(8)) null else statement.columnInt(8),
        .updated_at = statement.columnInt(9),
        .owner_cn = try allocator.dupe(u8, statement.columnText(10)),
    };
}

fn testEcho(ctx: *Context) anyerror!void {
    switch (ctx.params) {
        .object => |object| {
            if (object.get("message")) |value| {
                if (value == .string) try ctx.write(value.string);
            }
        },
        else => {},
    }
}

fn testSlow(ctx: *Context) anyerror!void {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (ctx.isCancelled()) return;
        if (i % 10 == 0) try ctx.setProgress(@intCast(i % 100));
        compat.sleep(10 * std.time.ns_per_ms);
    }
}

fn waitStatus(
    manager: *Manager,
    id: []const u8,
    want: Status,
    timeout_ms: usize,
) !void {
    var waited: usize = 0;
    while (waited < timeout_ms) : (waited += 25) {
        if (try manager.get(std.heap.smp_allocator, id)) |detail| {
            const status = parseStatus(detail.status);
            manager.freeDetail(detail);
            if (status == want) return;
            if (status.terminal() and want == .running) return error.TaskFinished;
        }
        compat.sleep(25 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

test "tasks run, persist output and dedupe idempotency" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(db_path);

    var database = try db.Db.open(db_path);
    defer database.close();
    try @import("migrations.zig").migrate(allocator, &database);

    const manager = try Manager.init(std.heap.smp_allocator, &database, dir);
    defer manager.deinit();
    try manager.register(.{ .kind = "test.echo", .handler = testEcho });
    try manager.start();

    const summary = try manager.create(
        std.heap.smp_allocator,
        "test.echo",
        "echo",
        "{\"message\":\"hello\"}",
        "idem-1",
        "test",
    );
    try waitStatus(manager, summary.id, .succeeded, 3000);

    const detail = (try manager.get(std.heap.smp_allocator, summary.id)).?;
    defer manager.freeDetail(detail);
    const file = try compat.openFileAbsolute(detail.output_path, .{});
    defer file.close();
    const text = try file.readToEndAlloc(std.heap.smp_allocator, 4096);
    defer std.heap.smp_allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);

    const again = try manager.create(
        std.heap.smp_allocator,
        "test.echo",
        "echo",
        "{\"message\":\"hello\"}",
        "idem-1",
        "test",
    );
    try std.testing.expectEqualStrings(summary.id, again.id);

    try std.testing.expect(try manager.dismiss(summary.id));
    try std.testing.expect((try manager.get(std.heap.smp_allocator, summary.id)) == null);
}

test "tasks can be canceled while running" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(db_path);

    var database = try db.Db.open(db_path);
    defer database.close();
    try @import("migrations.zig").migrate(allocator, &database);

    const manager = try Manager.init(std.heap.smp_allocator, &database, dir);
    defer manager.deinit();
    try manager.register(.{ .kind = "test.slow", .handler = testSlow });
    try manager.start();

    const summary = try manager.create(
        std.heap.smp_allocator,
        "test.slow",
        "slow",
        "{}",
        "",
        "test",
    );
    try waitStatus(manager, summary.id, .running, 3000);
    try std.testing.expect(manager.cancel(summary.id));
    try waitStatus(manager, summary.id, .canceled, 3000);
}

test "task pruning removes expired finished tasks and their output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(db_path);

    var database = try db.Db.open(db_path);
    defer database.close();
    try @import("migrations.zig").migrate(allocator, &database);

    const manager = try Manager.init(std.heap.smp_allocator, &database, dir);
    defer manager.deinit();
    try manager.register(.{ .kind = "test.echo", .handler = testEcho });
    try manager.start();

    const summary = try manager.create(
        std.heap.smp_allocator,
        "test.echo",
        "echo",
        "{\"message\":\"keep\"}",
        "",
        "test",
    );
    try waitStatus(manager, summary.id, .succeeded, 3000);

    const detail = (try manager.get(std.heap.smp_allocator, summary.id)).?;
    const output_path = try std.heap.smp_allocator.dupe(u8, detail.output_path);
    defer std.heap.smp_allocator.free(output_path);
    manager.freeDetail(detail);

    // Age the task past the retention window and prune it.
    try database.execute(
        "UPDATE tasks SET finished_at = ?1, updated_at = ?1 WHERE id = ?2",
        &.{ .{ .int = compat.milliTimestamp() - ttl_ms - 1000 }, .{ .text = summary.id } },
    );
    try manager.prune();

    const removed = (try manager.get(std.heap.smp_allocator, summary.id)) == null;
    try std.testing.expect(removed);
    const file = compat.openFileAbsolute(output_path, .{});
    try std.testing.expect(file == error.FileNotFound);
}

test "task pruning keeps the newest finished tasks within the cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(db_path);

    var database = try db.Db.open(db_path);
    defer database.close();
    try @import("migrations.zig").migrate(allocator, &database);

    const manager = try Manager.init(std.heap.smp_allocator, &database, dir);
    defer manager.deinit();

    const names = [_][]const u8{ "first", "second", "third", "fourth" };
    const now = compat.milliTimestamp();
    for (names, 0..) |name, index| {
        try database.execute(
            "INSERT INTO tasks(id, kind, title, status, params, output_path, " ++
                "idempotency_key, lock_key, owner_cn, created_at, finished_at, updated_at) " ++
                "VALUES(?1, 'test.echo', 'echo', 'succeeded', '{}', '', '', '', 'test', ?2, ?2, ?2)",
            &.{ .{ .text = name }, .{ .int = now - 4_000 + @as(i64, @intCast(index)) * 1000 } },
        );
    }

    try manager.pruneWithCap(2);
    try std.testing.expect((try manager.get(std.heap.smp_allocator, "fourth")) != null);
    try std.testing.expect((try manager.get(std.heap.smp_allocator, "third")) != null);
    try std.testing.expect((try manager.get(std.heap.smp_allocator, "second")) == null);
    try std.testing.expect((try manager.get(std.heap.smp_allocator, "first")) == null);
}
