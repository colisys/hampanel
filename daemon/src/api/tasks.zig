const std = @import("std");
const context = @import("context.zig");
const compat = @import("compat");
const tasks = @import("../tasks.zig");

const CreateBody = struct {
    kind: []const u8,
    title: []const u8 = "",
    params: ?std.json.Value = null,
    idempotency_key: []const u8 = "",
};

const DetailView = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    status: []const u8,
    phase: []const u8,
    progress: ?i64,
    params: []const u8,
    result: []const u8,
    @"error": []const u8,
    output_base: i64,
    output_bytes: i64,
    output_truncated: bool,
    output: []const u8,
    output_offset: u64,
    has_more: bool,
    created_at: i64,
    started_at: ?i64,
    finished_at: ?i64,
    updated_at: i64,
    owner_cn: []const u8,
};

pub fn create(ctx: *context.Context) anyerror!void {
    const body = ctx.requireJson(CreateBody) catch {
        ctx.fail(400, "bad_task", "body must be a JSON object");
        return;
    };
    if (body.kind.len == 0) {
        ctx.fail(400, "bad_task", "kind is required");
        return;
    }
    const allowed = ctx.app.task_limits.allow(
        ctx.app.allocator,
        ctx.peer_cn,
        max_submissions_per_minute,
        60 * 1000,
        compat.milliTimestamp(),
    ) catch true;
    if (!allowed) {
        ctx.fail(429, "too_many_submissions", "task submission rate exceeded");
        return;
    }

    const params = if (body.params) |value|
        std.json.Stringify.valueAlloc(ctx.arena, value, .{}) catch {
            ctx.fail(400, "bad_task", "params must be JSON");
            return;
        }
    else
        "{}";

    const summary = ctx.app.tasks.create(
        ctx.arena,
        body.kind,
        body.title,
        params,
        body.idempotency_key,
        ctx.peer_cn,
    ) catch |err| switch (err) {
        error.UnknownKind => {
            ctx.fail(400, "unknown_kind", "unknown task kind");
            return;
        },
        error.TooManyTasks => {
            ctx.fail(429, "too_many_tasks", "task queue is full");
            return;
        },
        error.InvalidTask => {
            ctx.fail(400, "bad_task", "task fields are invalid");
            return;
        },
        else => {
            ctx.fail(500, "task_failed", "could not create task");
            return;
        },
    };
    try ctx.jsonStatus(202, .{ .task = summary });
}

pub fn index(ctx: *context.Context) anyerror!void {
    const since_text = try ctx.query("since");
    const since = if (since_text) |text|
        std.fmt.parseInt(i64, text, 10) catch 0
    else
        0;
    const active_text = try ctx.query("active");
    const active_only = if (active_text) |text| std.mem.eql(u8, text, "1") else false;
    const limit_text = try ctx.query("limit");
    const parsed_limit = if (limit_text) |text|
        std.fmt.parseInt(usize, text, 10) catch 100
    else
        100;
    const limit = @min(@max(parsed_limit, 1), 500);
    const items = try ctx.app.tasks.list(ctx.arena, since, active_only, limit);
    try ctx.json(.{ .tasks = items });
}

pub fn get(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_task", "missing task id");
        return;
    };
    const detail = (try ctx.app.tasks.get(ctx.arena, id)) orelse {
        ctx.fail(404, "not_found", "task not found");
        return;
    };

    const offset_text = try ctx.query("output_offset");
    const offset = if (offset_text) |text|
        std.fmt.parseInt(u64, text, 10) catch 0
    else
        0;
    const limit_text = try ctx.query("output_limit");
    const parsed_limit = if (limit_text) |text|
        std.fmt.parseInt(usize, text, 10) catch 64 * 1024
    else
        64 * 1024;
    const limit = @min(@max(parsed_limit, 1), 512 * 1024);

    var output: []const u8 = "";
    var next_offset = offset;
    var total = detail.output_bytes;
    if (detail.output_path.len > 0) {
        if (compat.openFileAbsolute(detail.output_path, .{})) |file| {
            defer file.close();
            if (file.stat()) |stat| {
                if (stat.size > @as(u64, @intCast(total))) total = @intCast(stat.size);
            } else |_| {}
            const buffer = try ctx.arena.alloc(u8, limit);
            const read = file.readPositionalAll(buffer, offset) catch 0;
            output = buffer[0..read];
            next_offset = offset + read;
        } else |_| {}
    }

    try ctx.json(DetailView{
        .id = detail.id,
        .kind = detail.kind,
        .title = detail.title,
        .status = detail.status,
        .phase = detail.phase,
        .progress = detail.progress,
        .params = detail.params,
        .result = detail.result,
        .@"error" = detail.error_text,
        .output_base = detail.output_base,
        .output_bytes = total,
        .output_truncated = detail.output_truncated,
        .output = output,
        .output_offset = offset,
        .has_more = next_offset < @as(u64, @intCast(total)),
        .created_at = detail.created_at,
        .started_at = detail.started_at,
        .finished_at = detail.finished_at,
        .updated_at = detail.updated_at,
        .owner_cn = detail.owner_cn,
    });
}

pub fn cancel(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_task", "missing task id");
        return;
    };
    if (ctx.app.tasks.cancel(id)) {
        try ctx.json(.{ .ok = true });
        return;
    }
    if ((try ctx.app.tasks.get(ctx.arena, id)) == null) {
        ctx.fail(404, "not_found", "task not found");
        return;
    }
    ctx.fail(409, "not_running", "task is not running");
}

pub fn dismiss(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_task", "missing task id");
        return;
    };
    const removed = ctx.app.tasks.dismiss(id) catch |err| switch (err) {
        error.TaskRunning => {
            ctx.fail(409, "task_running", "task is still running");
            return;
        },
        else => {
            ctx.fail(500, "task_failed", "could not dismiss task");
            return;
        },
    };
    if (!removed) {
        ctx.fail(404, "not_found", "task not found");
        return;
    }
    try ctx.json(.{ .ok = true });
}

const http_response = @import("../http/response.zig");
const log = @import("../log.zig");

const max_sse_connections = 32;
const max_streams_per_client = 4;
const max_submissions_per_minute = 30;
const sse_lifetime_ms: i64 = 30 * 60 * 1000;

pub fn events(ctx: *context.Context) anyerror!void {
    const count = ctx.app.sse_connections.fetchAdd(1, .acq_rel) + 1;
    if (count > max_sse_connections) {
        _ = ctx.app.sse_connections.fetchSub(1, .acq_rel);
        ctx.fail(503, "too_many_streams", "too many event streams");
        return;
    }
    defer _ = ctx.app.sse_connections.fetchSub(1, .acq_rel);
    if (!(ctx.app.stream_clients.acquire(ctx.app.allocator, ctx.peer_cn, max_streams_per_client) catch true)) {
        ctx.fail(503, "too_many_streams", "too many event streams for this client");
        return;
    }
    defer ctx.app.stream_clients.release(ctx.app.allocator, ctx.peer_cn);

    ctx.hijacked = true;
    http_response.beginEventStream(ctx.conn) catch return;
    const started = compat.milliTimestamp();
    var last_heartbeat = started;

    while (true) {
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const items = ctx.app.tasks.list(arena.allocator(), 0, false, 200) catch
                @as([]tasks.Summary, &.{});
            const body = std.json.Stringify.valueAlloc(
                arena.allocator(),
                .{ .tasks = items },
                .{},
            ) catch "{\"tasks\":[]}";
            http_response.event(ctx.conn, "snapshot", body) catch return;
        }
        const now = compat.milliTimestamp();
        if (now - started >= sse_lifetime_ms) break;
        if (now - last_heartbeat >= 15_000) {
            http_response.comment(ctx.conn, "ping") catch return;
            last_heartbeat = now;
        }
        compat.sleep(1000 * std.time.ns_per_ms);
    }
    http_response.endEventStream(ctx.conn) catch {};
}

pub fn outputEvents(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_task", "missing task id");
        return;
    };
    if ((try ctx.app.tasks.get(ctx.arena, id)) == null) {
        ctx.fail(404, "not_found", "task not found");
        return;
    }
    const offset_text = try ctx.query("output_offset");
    var offset: u64 = if (offset_text) |text|
        std.fmt.parseInt(u64, text, 10) catch 0
    else
        0;

    const count = ctx.app.sse_connections.fetchAdd(1, .acq_rel) + 1;
    if (count > max_sse_connections) {
        _ = ctx.app.sse_connections.fetchSub(1, .acq_rel);
        ctx.fail(503, "too_many_streams", "too many event streams");
        return;
    }
    defer _ = ctx.app.sse_connections.fetchSub(1, .acq_rel);
    if (!(ctx.app.stream_clients.acquire(ctx.app.allocator, ctx.peer_cn, max_streams_per_client) catch true)) {
        ctx.fail(503, "too_many_streams", "too many event streams for this client");
        return;
    }
    defer ctx.app.stream_clients.release(ctx.app.allocator, ctx.peer_cn);

    ctx.hijacked = true;
    http_response.beginEventStream(ctx.conn) catch return;
    const started = compat.milliTimestamp();
    var last_heartbeat = started;
    const encoder = std.base64.standard.Encoder;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const detail = (ctx.app.tasks.get(arena.allocator(), id) catch null) orelse {
            http_response.event(ctx.conn, "gone", "{\"code\":\"not_found\"}") catch {};
            break;
        };

        var seen_base = detail.output_base;
        if (detail.output_path.len > 0) {
            if (compat.openFileAbsolute(detail.output_path, .{})) |file| {
                defer file.close();
                if (file.stat()) |stat| {
                    if (@as(i64, @intCast(offset)) < seen_base) {
                        offset = 0;
                        http_response.event(ctx.conn, "reset", "{}") catch return;
                        seen_base = 0;
                    }
                    while (offset < stat.size) {
                        const want: usize = @intCast(@min(stat.size - offset, 32 * 1024));
                        const buffer = arena.allocator().alloc(u8, want) catch break;
                        const read = file.readPositionalAll(buffer, offset) catch break;
                        if (read == 0) break;
                        const encoded = arena.allocator().alloc(u8, encoder.calcSize(read)) catch break;
                        _ = encoder.encode(encoded, buffer[0..read]);
                        const payload = std.json.Stringify.valueAlloc(
                            arena.allocator(),
                            .{ .offset = offset, .data = encoded },
                            .{},
                        ) catch break;
                        http_response.event(ctx.conn, "output", payload) catch return;
                        offset += read;
                    }
                } else |_| {}
            } else |_| {}
        }

        const status_body = std.json.Stringify.valueAlloc(
            arena.allocator(),
            .{
                .id = detail.id,
                .status = detail.status,
                .phase = detail.phase,
                .progress = detail.progress,
                .output_bytes = detail.output_bytes,
                .output_truncated = detail.output_truncated,
                .@"error" = detail.error_text,
            },
            .{},
        ) catch "{}";
        http_response.event(ctx.conn, "status", status_body) catch return;

        if (tasks.terminalStatus(detail.status)) break;
        const now = compat.milliTimestamp();
        if (now - started >= sse_lifetime_ms) break;
        if (now - last_heartbeat >= 15_000) {
            http_response.comment(ctx.conn, "ping") catch return;
            last_heartbeat = now;
        }
        compat.sleep(400 * std.time.ns_per_ms);
    }
    http_response.endEventStream(ctx.conn) catch {};
}
