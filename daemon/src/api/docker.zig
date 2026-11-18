const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const notify = @import("../notify.zig");
const engine_mod = @import("../runtime/engine.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const log = @import("../log.zig");

const max_output = 8 * 1024 * 1024;
const Engine = engine_mod.Engine;

fn socketPath(ctx: *context.Context) []const u8 {
    return engine_mod.socketFromDb(ctx.arena, ctx.app.db);
}

fn unavailable(ctx: *context.Context) void {
    ctx.fail(501, "engine_unavailable", "未检测到 Docker 或 Podman");
}

const Network = struct {
    name: []const u8,
    ip: []const u8,
};

const PortMap = struct {
    host_ip: []const u8,
    host_port: []const u8,
    container_port: []const u8,
    protocol: []const u8,
};

const Stats = struct {
    cpu_percent: []const u8,
    mem_percent: []const u8,
    mem_usage: []const u8,
    net_io: []const u8,
    block_io: []const u8,
    pids: []const u8,
};

const Container = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    state: []const u8,
    status: []const u8,
    ports: []const u8,
    created_at: []const u8,
    image_id: []const u8 = "",
    started_at: []const u8 = "",
    note: []const u8 = "",
    compose_project: []const u8 = "",
    networks: []const Network = &.{},
    port_map: []const PortMap = &.{},
    stats: ?Stats = null,
};

const Image = struct {
    id: []const u8,
    repository: []const u8,
    tag: []const u8,
    size: []const u8,
    created_at: []const u8,
    digest: []const u8 = "",
    dangling: bool = false,
    in_use: bool = false,
    used_by: []const []const u8 = &.{},
};

pub fn overview(ctx: *context.Context) anyerror!void {
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };

    const ps = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "ps", "-a", "--no-trunc", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!ps.ok()) {
        ctx.fail(502, "docker_failed", textOf(ps));
        return;
    }

    var running: usize = 0;
    var stopped: usize = 0;
    var restarting: usize = 0;
    var failed: usize = 0;
    for (try engine_mod.parseJsonObjects(ctx.arena, ps.stdout)) |value| {
        const state = stringField(value, "State");
        if (std.mem.eql(u8, state, "running")) {
            running += 1;
        } else if (std.mem.eql(u8, state, "restarting")) {
            restarting += 1;
        } else if (std.mem.eql(u8, state, "dead")) {
            failed += 1;
        } else {
            stopped += 1;
        }
    }

    try ctx.json(.{
        .available = true,
        .engine = engine.name,
        .podman = engine.podman,
        .containers = .{
            .running = running,
            .stopped = stopped,
            .restarting = restarting,
            .failed = failed,
            .@"error" = failed,
        },
        .compose = composeCount(ctx, engine, socket),
        .images = countLines(ctx, engine, socket, &.{ engine.name, "images", "-q" }),
        .networks = countLines(ctx, engine, socket, &.{ engine.name, "network", "ls", "-q" }),
        .volumes = countLines(ctx, engine, socket, &.{ engine.name, "volume", "ls", "-q" }),
    });
}

pub fn info(ctx: *context.Context) anyerror!void {
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "info", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "docker_failed", textOf(result));
        return;
    }
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        ctx.fail(502, "docker_failed", "invalid docker info output");
        return;
    };
    try ctx.json(.{
        .engine = engine.name,
        .podman = engine.podman,
        .info = value,
    });
}

pub fn testConnection(ctx: *context.Context) anyerror!void {
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "未检测到 Docker 或 Podman");
        return;
    };
    try ctx.json(.{
        .ok = true,
        .engine = engine.name,
        .podman = engine.podman,
        .socket_path = socket,
    });
}

pub fn containers(ctx: *context.Context) anyerror!void {
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "ps", "-a", "--no-trunc", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "docker_failed", textOf(result));
        return;
    }

    var items = std.array_list.Managed(Container).init(ctx.arena);
    var ids = std.array_list.Managed([]const u8).init(ctx.arena);
    for (try engine_mod.parseJsonObjects(ctx.arena, result.stdout)) |value| {
        if (value != .object) continue;
        const id = stringFieldAny(value, &.{ "ID", "Id", "id" });
        try items.append(.{
            .id = id,
            .name = nameField(value),
            .image = stringField(value, "Image"),
            .state = stringField(value, "State"),
            .status = stringField(value, "Status"),
            .ports = stringField(value, "Ports"),
            .created_at = stringFieldAny(value, &.{ "CreatedAt", "Created" }),
        });
        try ids.append(id);
    }

    const inspected = inspectAll(ctx, engine, socket, ids.items) catch null;
    var note_map = loadNotes(ctx) catch std.StringHashMap([]const u8).init(ctx.arena);
    var stats: ?std.StringHashMap(Stats) = null;
    if (try ctx.query("stats")) |raw| {
        if (std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true")) {
            stats = loadStats(ctx, engine, socket) catch null;
        }
    }

    for (items.items) |*item| {
        if (inspected) |map| {
            if (map.get(item.id)) |value| try enrich(ctx.arena, item, value);
        }
        if (note_map.get(item.name)) |note| item.note = note;
        if (stats) |*map| {
            if (map.get(item.name)) |entry| item.stats = entry;
        }
    }

    try ctx.json(.{
        .available = true,
        .engine = engine.name,
        .podman = engine.podman,
        .containers = items.items,
    });
}

pub fn images(ctx: *context.Context) anyerror!void {
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "images", "--no-trunc", "--digests", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "docker_failed", textOf(result));
        return;
    }

    const usage = loadImageUsage(ctx, engine, socket) catch &[_]UsageEntry{};
    var items = std.array_list.Managed(Image).init(ctx.arena);
    for (try engine_mod.parseJsonObjects(ctx.arena, result.stdout)) |value| {
        if (value != .object) continue;
        const id = stringFieldAny(value, &.{ "ID", "Id", "id" });
        var repository = stringField(value, "Repository");
        var tag = stringField(value, "Tag");
        if (repository.len == 0) {
            if (value.object.get("RepoTags")) |repo_tags| {
                if (repo_tags == .array) {
                    for (repo_tags.array.items) |entry| {
                        if (entry != .string) continue;
                        const reference = entry.string;
                        if (std.mem.eql(u8, reference, "<none>:<none>") or reference.len == 0) continue;
                        if (std.mem.lastIndexOfScalar(u8, reference, ':')) |colon| {
                            repository = reference[0..colon];
                            tag = reference[colon + 1 ..];
                        } else {
                            repository = reference;
                            tag = "latest";
                        }
                        break;
                    }
                }
            }
        }
        const size_text = imageSize(ctx.arena, value) catch "";
        const created_text = imageCreated(ctx.arena, value) catch "";
        const reference = if (std.mem.eql(u8, tag, "<none>"))
            repository
        else if (std.mem.eql(u8, repository, "<none>"))
            ""
        else
            try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ repository, tag });
        var used_by = std.array_list.Managed([]const u8).init(ctx.arena);
        for (usage) |entry| {
            if (std.mem.eql(u8, entry.image_id, id) or
                (reference.len > 0 and std.mem.eql(u8, entry.reference, reference)))
            {
                try used_by.append(entry.name);
            }
        }
        try items.append(.{
            .id = id,
            .repository = repository,
            .tag = tag,
            .size = size_text,
            .created_at = created_text,
            .digest = stringField(value, "Digest"),
            .dangling = std.mem.eql(u8, repository, "<none>") or std.mem.eql(u8, tag, "<none>"),
            .in_use = used_by.items.len > 0,
            .used_by = used_by.items,
        });
    }

    try ctx.json(.{
        .available = true,
        .engine = engine.name,
        .podman = engine.podman,
        .images = items.items,
    });
}

pub fn action(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing container id");
        return;
    };
    const action_name = ctx.param("action") orelse {
        ctx.fail(400, "bad_action", "missing action");
        return;
    };
    if (!validate.isContainerId(id)) {
        ctx.fail(400, "bad_id", "invalid container id");
        return;
    }

    const allowed = [_][]const u8{ "start", "stop", "restart", "pause", "unpause", "rm" };
    var valid = false;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, action_name, candidate)) valid = true;
    }
    if (!valid) {
        ctx.fail(400, "bad_action", "unsupported action");
        return;
    }

    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    const argv = if (std.mem.eql(u8, action_name, "rm"))
        &[_][]const u8{ engine.name, "rm", "-f", id }
    else
        &[_][]const u8{ engine.name, action_name, id };

    const result = engine_mod.run(ctx.arena, engine, socket, argv, .{ .max_output = 1024 * 1024 }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };

    const Body = struct {
        id: []const u8,
        action: []const u8,
        ok: bool,
        output: []const u8,
    };
    if (!result.ok()) ctx.response.status = 502;
    if (result.ok()) {
        log.info("docker: {s} container={s}", .{ action_name, id });
    } else {
        log.warn("docker: {s} failed container={s}", .{ action_name, id });
    }
    if (std.mem.eql(u8, action_name, "restart") and result.ok()) {
        const body = std.fmt.allocPrint(ctx.arena, "容器 {s} 已重启", .{id}) catch "容器已重启";
        notify.emit(ctx.app.db, .docker_restart, "容器重启", body);
    }
    try ctx.json(Body{ .id = id, .action = action_name, .ok = result.ok(), .output = textOf(result) });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing container id");
        return;
    };
    if (!validate.isContainerId(id)) {
        ctx.fail(400, "bad_id", "invalid container id");
        return;
    }

    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }
    const tail = try std.fmt.allocPrint(ctx.arena, "{d}", .{lines});

    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "logs", "--tail", tail, id }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };

    const output = try std.mem.concat(ctx.arena, u8, &.{ result.stdout, result.stderr });
    try ctx.json(.{ .id = id, .ok = result.ok(), .output = output });
}

const Mount = struct {
    type: []const u8,
    source: []const u8,
    destination: []const u8,
    read_only: bool,
    name: []const u8 = "",
};

const Detail = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    image_id: []const u8,
    state: []const u8,
    status: []const u8,
    created_at: []const u8,
    started_at: []const u8,
    restart_policy: []const u8,
    restart_max: u32,
    env: []const []const u8,
    ports: []const PortMap,
    mounts: []const Mount,
    networks: []const Network,
    network_mode: []const u8,
    labels: []const []const u8,
    cpus: ?f64,
    memory: ?u64,
    compose_project: []const u8,
    note: []const u8,
    command: []const []const u8,
    entrypoint: []const []const u8,
};

pub fn detail(ctx: *context.Context) anyerror!void {
    const id = requireContainerId(ctx) orelse return;
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "inspect", id }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.fail(404, "not_found", textOf(result));
        return;
    }
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        ctx.fail(502, "docker_failed", "invalid inspect output");
        return;
    };
    if (value != .array or value.array.items.len == 0) {
        ctx.fail(404, "not_found", "container not found");
        return;
    }
    const note_map = loadNotes(ctx) catch std.StringHashMap([]const u8).init(ctx.arena);
    const view = try detailFrom(ctx.arena, value.array.items[0], note_map);
    try ctx.json(view);
}

pub fn notes(ctx: *context.Context) anyerror!void {
    const NoteView = struct { name: []const u8, note: []const u8 };
    var list = std.array_list.Managed(NoteView).init(ctx.arena);
    const map = loadNotes(ctx) catch std.StringHashMap([]const u8).init(ctx.arena);
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        try list.append(.{ .name = entry.key_ptr.*, .note = entry.value_ptr.* });
    }
    try ctx.json(.{ .notes = list.items });
}

pub fn noteSave(ctx: *context.Context) anyerror!void {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing container name");
        return;
    };
    if (!validate.isContainerName(name)) {
        ctx.fail(400, "bad_name", "invalid container name");
        return;
    }
    const Body = struct { note: []const u8 = "" };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected note");
        return;
    };
    if (body.note.len > 4096 or std.mem.indexOfScalar(u8, body.note, 0) != null) {
        ctx.fail(400, "bad_note", "note is too long or invalid");
        return;
    }
    ctx.app.db.execute(
        "INSERT INTO container_notes(name, note, updated_at) VALUES(?1, ?2, ?3) " ++
            "ON CONFLICT(name) DO UPDATE SET note = excluded.note, updated_at = excluded.updated_at",
        &.{ .{ .text = name }, .{ .text = body.note }, .{ .int = compat.timestamp() } },
    ) catch |err| {
        ctx.fail(500, "db_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .name = name, .note = body.note });
}

pub fn create(ctx: *context.Context) anyerror!void {
    const body = parseCreateBody(ctx) orelse return;
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    if (!imageAvailable(ctx, engine, socket, body.image)) {
        ctx.fail(409, "image_missing", "本地没有该镜像，请先拉取");
        return;
    }
    const argv = buildRunArgv(ctx.arena, engine, body) catch |err| {
        ctx.fail(400, "bad_request", @errorName(err));
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, argv, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) {
        ctx.response.status = 502;
        try ctx.json(.{ .ok = false, .output = textOf(result) });
        return;
    }
    log.info("docker: created container name={s}", .{body.name});
    try ctx.jsonStatus(201, .{ .ok = true, .output = std.mem.trim(u8, result.stdout, " \t\r\n") });
}

pub fn recreate(ctx: *context.Context) anyerror!void {
    const id = requireContainerId(ctx) orelse return;
    const body = parseCreateBody(ctx) orelse return;
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    if (!imageAvailable(ctx, engine, socket, body.image)) {
        ctx.fail(409, "image_missing", "本地没有该镜像，请先拉取");
        return;
    }

    const inspect = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "inspect", id }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!inspect.ok()) {
        ctx.fail(404, "not_found", textOf(inspect));
        return;
    }
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, inspect.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        ctx.fail(502, "docker_failed", "invalid inspect output");
        return;
    };
    if (parsed != .array or parsed.array.items.len == 0) {
        ctx.fail(404, "not_found", "container not found");
        return;
    }
    const value = parsed.array.items[0];
    const old_name = stripSlash(stringField(value, "Name"));
    if (old_name.len == 0) {
        ctx.fail(502, "docker_failed", "container has no name");
        return;
    }
    if (composeProject(value).len > 0) {
        ctx.fail(409, "compose_managed", "compose 管理的容器请在编排页修改");
        return;
    }

    const backup_path = try saveContainerBackup(ctx, old_name, inspect.stdout);
    const stamp = compat.timestamp();
    const backup_name = try std.fmt.allocPrint(ctx.arena, "hampanel-backup-{d}", .{stamp});

    _ = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "stop", id }, .{ .max_output = 1024 * 1024 }) catch {};
    const renamed = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "rename", id, backup_name }, .{ .max_output = 1024 * 1024 }) catch {
        ctx.fail(502, "docker_unavailable", "unable to rename the old container");
        return;
    };
    if (!renamed.ok()) {
        ctx.fail(502, "recreate_failed", textOf(renamed));
        return;
    }

    const argv = buildRunArgv(ctx.arena, engine, body) catch |err| {
        _ = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "rename", backup_name, old_name }, .{ .max_output = 1024 * 1024 }) catch {};
        ctx.fail(400, "bad_request", @errorName(err));
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, argv, .{ .max_output = max_output }) catch {
        _ = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "rename", backup_name, old_name }, .{ .max_output = 1024 * 1024 }) catch {};
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };

    if (!result.ok()) {
        _ = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "rename", backup_name, old_name }, .{ .max_output = 1024 * 1024 }) catch {};
        _ = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "start", old_name }, .{ .max_output = 1024 * 1024 }) catch {};
        ctx.response.status = 502;
        try ctx.json(.{ .ok = false, .output = textOf(result), .backup = backup_path });
        return;
    }

    _ = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "rm", "-f", backup_name }, .{ .max_output = 1024 * 1024 }) catch {};
    log.info("docker: recreated container name={s}", .{body.name});
    try ctx.json(.{ .ok = true, .output = std.mem.trim(u8, result.stdout, " \t\r\n"), .backup = backup_path });
}

pub fn commit(ctx: *context.Context) anyerror!void {
    const id = requireContainerId(ctx) orelse return;
    const Body = struct {
        repository: []const u8,
        tag: []const u8 = "latest",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected repository and tag");
        return;
    };
    if (!validate.isImageRef(body.repository) or !validate.isImageRef(body.tag)) {
        ctx.fail(400, "bad_image", "invalid image reference");
        return;
    }
    const reference = try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ body.repository, body.tag });
    const socket = socketPath(ctx);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        unavailable(ctx);
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "commit", id, reference }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: committed container={s} image={s}", .{ id, reference });
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .image = reference });
}

const CreateBody = struct {
    name: []const u8,
    image: []const u8,
    command: []const []const u8 = &.{},
    entrypoint: []const u8 = "",
    env: []const []const u8 = &.{},
    ports: []const []const u8 = &.{},
    mounts: []const []const u8 = &.{},
    restart: []const u8 = "no",
    network: []const u8 = "",
    labels: []const []const u8 = &.{},
    cpus: ?f64 = null,
    memory: ?u64 = null,
};

fn parseCreateBody(ctx: *context.Context) ?CreateBody {
    const body = ctx.requireJson(CreateBody) catch {
        ctx.fail(400, "bad_request", "expected container configuration");
        return null;
    };
    if (!validate.isContainerName(body.name)) {
        ctx.fail(400, "bad_name", "invalid container name");
        return null;
    }
    if (!validate.isImageRef(body.image)) {
        ctx.fail(400, "bad_image", "invalid image reference");
        return null;
    }
    if (body.restart.len == 0 or body.restart.len > 32) {
        ctx.fail(400, "bad_restart", "invalid restart policy");
        return null;
    }
    for (body.restart) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != ':') {
            ctx.fail(400, "bad_restart", "invalid restart policy");
            return null;
        }
    }
    if (body.network.len > 0 and !validate.isNetworkName(body.network)) {
        ctx.fail(400, "bad_network", "invalid network name");
        return null;
    }
    for (body.env) |entry| {
        const index = std.mem.indexOfScalar(u8, entry, '=') orelse {
            ctx.fail(400, "bad_env", "environment entries must be KEY=VALUE");
            return null;
        };
        if (!validate.isEnvKey(entry[0..index]) or !validate.isEnvValue(entry[index + 1 ..])) {
            ctx.fail(400, "bad_env", "invalid environment entry");
            return null;
        }
    }
    for (body.ports) |entry| {
        if (!validate.isPortMapping(entry)) {
            ctx.fail(400, "bad_port", "invalid port mapping");
            return null;
        }
    }
    for (body.mounts) |entry| {
        if (!validate.isMountSpec(entry)) {
            ctx.fail(400, "bad_mount", "invalid mount specification");
            return null;
        }
    }
    for (body.labels) |entry| {
        const index = std.mem.indexOfScalar(u8, entry, '=') orelse {
            ctx.fail(400, "bad_label", "labels must be KEY=VALUE");
            return null;
        };
        if (!validate.isEnvKey(entry[0..index]) or !validate.isEnvValue(entry[index + 1 ..])) {
            ctx.fail(400, "bad_label", "invalid label");
            return null;
        }
    }
    if (body.entrypoint.len > 512) {
        ctx.fail(400, "bad_entrypoint", "entrypoint is too long");
        return null;
    }
    return body;
}

fn buildRunArgv(
    allocator: std.mem.Allocator,
    engine: Engine,
    body: CreateBody,
) ![]const []const u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(engine.name);
    try argv.append("run");
    try argv.append("-d");
    try argv.append("--name");
    try argv.append(body.name);
    try argv.append("--restart");
    try argv.append(body.restart);
    if (body.network.len > 0) {
        try argv.append("--network");
        try argv.append(body.network);
    }
    if (body.entrypoint.len > 0) {
        try argv.append("--entrypoint");
        try argv.append(body.entrypoint);
    }
    for (body.env) |entry| {
        try argv.append("-e");
        try argv.append(entry);
    }
    for (body.ports) |entry| {
        try argv.append("-p");
        try argv.append(entry);
    }
    for (body.mounts) |entry| {
        try argv.append("-v");
        try argv.append(entry);
    }
    for (body.labels) |entry| {
        try argv.append("--label");
        try argv.append(entry);
    }
    if (body.cpus) |cpus| {
        try argv.append("--cpus");
        try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{cpus}));
    }
    if (body.memory) |memory| {
        try argv.append("--memory");
        try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{memory}));
    }
    try argv.append(body.image);
    for (body.command) |arg| try argv.append(arg);
    return argv.items;
}

fn imageAvailable(ctx: *context.Context, engine: Engine, socket: []const u8, image: []const u8) bool {
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "image", "inspect", image }, .{ .max_output = 64 * 1024 }) catch return false;
    return result.ok();
}

fn saveContainerBackup(ctx: *context.Context, name: []const u8, inspect_json: []const u8) ![]const u8 {
    const dir = try std.fs.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "docker", "container-backups" });
    compat.cwd().makePath(dir) catch {};
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}-{d}.json", .{ dir, name, compat.timestamp() });
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(inspect_json);
    return path;
}

fn inspectAll(
    ctx: *context.Context,
    engine: Engine,
    socket: []const u8,
    ids: []const []const u8,
) !std.StringHashMap(std.json.Value) {
    var map = std.StringHashMap(std.json.Value).init(ctx.arena);
    if (ids.len == 0) return map;
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.append(engine.name);
    try argv.append("inspect");
    for (ids) |id| try argv.append(id);
    const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = max_output }) catch return map;
    if (!result.ok()) return map;
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return map;
    if (value != .array) return map;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const id = stringField(item, "Id");
        if (id.len > 0) try map.put(id, item);
    }
    return map;
}

fn loadStats(
    ctx: *context.Context,
    engine: Engine,
    socket: []const u8,
) !std.StringHashMap(Stats) {
    var map = std.StringHashMap(Stats).init(ctx.arena);
    const result = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "stats", "--no-stream", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch return map;
    if (!result.ok()) return map;
    for (try engine_mod.parseJsonObjects(ctx.arena, result.stdout)) |value| {
        if (value != .object) continue;
        const name = stringField(value, "Name");
        if (name.len == 0) continue;
        try map.put(name, .{
            .cpu_percent = stringField(value, "CPUPerc"),
            .mem_percent = stringField(value, "MemPerc"),
            .mem_usage = stringField(value, "MemUsage"),
            .net_io = stringField(value, "NetIO"),
            .block_io = stringField(value, "BlockIO"),
            .pids = stringField(value, "PIDs"),
        });
    }
    return map;
}

fn loadNotes(ctx: *context.Context) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(ctx.arena);
    const database = ctx.app.db;
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked("SELECT name, note FROM container_notes");
    defer statement.deinit();
    while (try statement.step()) {
        const name = try statement.dupeColumnText(ctx.arena, 0);
        const note = try statement.dupeColumnText(ctx.arena, 1);
        try map.put(name, note);
    }
    return map;
}

fn enrich(allocator: std.mem.Allocator, item: *Container, value: std.json.Value) !void {
    if (value != .object) return;
    item.image_id = stringField(value, "Image");
    const inspected_name = stripSlash(stringField(value, "Name"));
    if (inspected_name.len > 0) item.name = inspected_name;
    if (value.object.get("Created")) |created| {
        if (created == .string) item.created_at = created.string;
    }
    if (value.object.get("State")) |state| {
        if (state == .object) {
            item.started_at = stringField(state, "StartedAt");
            const status = stringField(state, "Status");
            if (status.len > 0) item.state = status;
        }
    }
    if (value.object.get("Config")) |config| {
        if (config == .object) {
            const image = stringField(config, "Image");
            if (image.len > 0) item.image = image;
            item.compose_project = composeProject(value);
        }
    }
    if (value.object.get("NetworkSettings")) |settings| {
        if (settings == .object) {
            if (settings.object.get("Networks")) |networks| {
                if (networks == .object) {
                    var list = std.array_list.Managed(Network).init(allocator);
                    var iterator = networks.object.iterator();
                    while (iterator.next()) |entry| {
                        const ip = if (entry.value_ptr.* == .object) stringField(entry.value_ptr.*, "IPAddress") else "";
                        try list.append(.{ .name = entry.key_ptr.*, .ip = ip });
                    }
                    item.networks = list.items;
                }
            }
            if (settings.object.get("Ports")) |ports| {
                if (ports == .object) {
                    var list = std.array_list.Managed(PortMap).init(allocator);
                    var iterator = ports.object.iterator();
                    while (iterator.next()) |entry| {
                        const spec = entry.key_ptr.*;
                        const slash = std.mem.indexOfScalar(u8, spec, '/') orelse spec.len;
                        const container_port = spec[0..slash];
                        const protocol = if (slash < spec.len) spec[slash + 1 ..] else "";
                        const bindings = entry.value_ptr.*;
                        if (bindings == .array and bindings.array.items.len > 0) {
                            for (bindings.array.items) |binding| {
                                try list.append(.{
                                    .host_ip = stringField(binding, "HostIp"),
                                    .host_port = stringField(binding, "HostPort"),
                                    .container_port = container_port,
                                    .protocol = protocol,
                                });
                            }
                        } else {
                            try list.append(.{
                                .host_ip = "",
                                .host_port = "",
                                .container_port = container_port,
                                .protocol = protocol,
                            });
                        }
                    }
                    item.port_map = list.items;
                }
            }
        }
    }
}

fn detailFrom(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    note_map: std.StringHashMap([]const u8),
) !Detail {
    var item = Container{
        .id = stringField(value, "Id"),
        .name = "",
        .image = "",
        .state = "",
        .status = "",
        .ports = "",
        .created_at = "",
    };
    try enrich(allocator, &item, value);

    var command = std.array_list.Managed([]const u8).init(allocator);
    var entrypoint = std.array_list.Managed([]const u8).init(allocator);
    var env = std.array_list.Managed([]const u8).init(allocator);
    if (value.object.get("Config")) |config| {
        if (config == .object) {
            if (config.object.get("Env")) |entries| {
                if (entries == .array) {
                    for (entries.array.items) |entry| {
                        if (entry == .string) try env.append(entry.string);
                    }
                }
            }
            if (config.object.get("Cmd")) |entries| {
                if (entries == .array) {
                    for (entries.array.items) |entry| {
                        if (entry == .string) try command.append(entry.string);
                    }
                }
            }
            if (config.object.get("Entrypoint")) |entries| {
                if (entries == .array) {
                    for (entries.array.items) |entry| {
                        if (entry == .string) try entrypoint.append(entry.string);
                    }
                }
            }
        }
    }
    var labels = std.array_list.Managed([]const u8).init(allocator);
    if (value.object.get("Config")) |config| {
        if (config == .object) {
            if (config.object.get("Labels")) |entries| {
                if (entries == .object) {
                    var iterator = entries.object.iterator();
                    while (iterator.next()) |entry| {
                        if (entry.value_ptr.* == .string) {
                            try labels.append(try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string }));
                        }
                    }
                }
            }
        }
    }
    var mounts = std.array_list.Managed(Mount).init(allocator);
    if (value.object.get("Mounts")) |entries| {
        if (entries == .array) {
            for (entries.array.items) |entry| {
                if (entry != .object) continue;
                const rw = if (entry.object.get("RW")) |rw_value| rw_value == .bool and rw_value.bool else true;
                try mounts.append(.{
                    .type = stringField(entry, "Type"),
                    .source = stringField(entry, "Source"),
                    .destination = stringField(entry, "Destination"),
                    .read_only = !rw,
                    .name = stringField(entry, "Name"),
                });
            }
        }
    }
    var restart_policy: []const u8 = "no";
    var restart_max: u32 = 0;
    var network_mode: []const u8 = "";
    var cpus: ?f64 = null;
    var memory: ?u64 = null;
    if (value.object.get("HostConfig")) |host| {
        if (host == .object) {
            network_mode = stringField(host, "NetworkMode");
            if (host.object.get("RestartPolicy")) |policy| {
                if (policy == .object) {
                    const name = stringField(policy, "Name");
                    if (name.len > 0) restart_policy = name;
                    if (policy.object.get("MaximumRetryCount")) |count| {
                        if (count == .integer and count.integer > 0) restart_max = @intCast(count.integer);
                    }
                }
            }
            if (host.object.get("NanoCpus")) |nano| {
                if (nano == .integer and nano.integer > 0) cpus = @as(f64, @floatFromInt(nano.integer)) / 1_000_000_000.0;
            }
            if (host.object.get("Memory")) |mem_value| {
                if (mem_value == .integer and mem_value.integer > 0) memory = @intCast(mem_value.integer);
            }
        }
    }
    const note = note_map.get(item.name) orelse "";
    return .{
        .id = item.id,
        .name = item.name,
        .image = item.image,
        .image_id = item.image_id,
        .state = item.state,
        .status = item.status,
        .created_at = item.created_at,
        .started_at = item.started_at,
        .restart_policy = restart_policy,
        .restart_max = restart_max,
        .env = env.items,
        .ports = item.port_map,
        .mounts = mounts.items,
        .networks = item.networks,
        .network_mode = network_mode,
        .labels = labels.items,
        .cpus = cpus,
        .memory = memory,
        .compose_project = item.compose_project,
        .note = note,
        .command = command.items,
        .entrypoint = entrypoint.items,
    };
}

fn composeProject(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    const config = value.object.get("Config") orelse return "";
    if (config != .object) return "";
    const labels = config.object.get("Labels") orelse return "";
    if (labels != .object) return "";
    const project = labels.object.get("com.docker.compose.project") orelse return "";
    return if (project == .string) project.string else "";
}

fn stripSlash(value: []const u8) []const u8 {
    return if (value.len > 0 and value[0] == '/') value[1..] else value;
}

fn requireContainerId(ctx: *context.Context) ?[]const u8 {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing container id");
        return null;
    };
    if (!validate.isContainerId(id)) {
        ctx.fail(400, "bad_id", "invalid container id");
        return null;
    }
    return id;
}

const UsageEntry = struct {
    image_id: []const u8,
    reference: []const u8,
    name: []const u8,
};

fn loadImageUsage(
    ctx: *context.Context,
    engine: Engine,
    socket: []const u8,
) ![]const UsageEntry {
    const result = engine_mod.run(ctx.arena, engine, socket, &.{
        engine.name, "ps", "-a", "--no-trunc", "--format", "{{json .}}",
    }, .{ .max_output = max_output }) catch return &.{};
    if (!result.ok()) return &.{};
    var ids = std.array_list.Managed([]const u8).init(ctx.arena);
    for (try engine_mod.parseJsonObjects(ctx.arena, result.stdout)) |value| {
        if (value != .object) continue;
        const id = stringField(value, "ID");
        if (id.len > 0) try ids.append(id);
    }
    const inspected = inspectAll(ctx, engine, socket, ids.items) catch return &.{};
    var usage = std.array_list.Managed(UsageEntry).init(ctx.arena);
    var iterator = inspected.iterator();
    while (iterator.next()) |entry| {
        const value = entry.value_ptr.*;
        const image_id = stringField(value, "Image");
        const reference = if (value == .object)
            stringField(value.object.get("Config") orelse std.json.Value{ .null = {} }, "Image")
        else
            "";
        try usage.append(.{
            .image_id = image_id,
            .reference = reference,
            .name = stripSlash(stringField(value, "Name")),
        });
    }
    return usage.items;
}

fn countLines(
    ctx: *context.Context,
    engine: Engine,
    socket: []const u8,
    argv: []const []const u8,
) usize {
    const result = engine_mod.run(ctx.arena, engine, socket, argv, .{ .max_output = 1024 * 1024 }) catch return 0;
    if (!result.ok()) return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    return count;
}

fn composeCount(ctx: *context.Context, engine: Engine, socket: []const u8) usize {
    const compose = engine_mod.composeCommand(ctx.arena, engine, socket) catch return 0;
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    argv.appendSlice(compose) catch return 0;
    argv.appendSlice(&.{ "ls", "--all", "--format", "json" }) catch return 0;
    const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = 1024 * 1024 }) catch return 0;
    if (!result.ok()) return 0;
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{}) catch return 0;
    if (value != .array) return 0;
    return value.array.items.len;
}

fn stringField(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const entry = value.object.get(key) orelse return "";
    return switch (entry) {
        .string => |text| text,
        else => "",
    };
}

fn stringFieldAny(value: std.json.Value, keys: []const []const u8) []const u8 {
    for (keys) |key| {
        const text = stringField(value, key);
        if (text.len > 0) return text;
    }
    return "";
}

fn nameField(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    if (value.object.get("Names")) |names| {
        if (names == .string) return names.string;
        if (names == .array) {
            for (names.array.items) |entry| {
                if (entry == .string) return entry.string;
            }
        }
    }
    return stringField(value, "Name");
}

fn imageSize(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value != .object) return "";
    const entry = value.object.get("Size") orelse return "";
    return switch (entry) {
        .string => |text| text,
        .integer => |bytes| formatSize(allocator, @intCast(bytes)),
        else => "",
    };
}

fn imageCreated(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const direct = stringFieldAny(value, &.{ "CreatedAt", "CreatedSince" });
    if (direct.len > 0) return direct;
    if (value != .object) return "";
    const entry = value.object.get("Created") orelse return "";
    return switch (entry) {
        .string => |text| text,
        .integer => |seconds| formatEpoch(allocator, seconds),
        else => "",
    };
}

fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    if (unit == 0) return std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[unit] });
    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ value, units[unit] });
}

fn formatEpoch(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    });
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
