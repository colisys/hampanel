const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const engine_mod = @import("../runtime/engine.zig");
const registries = @import("docker_registries.zig");
const jobs_mod = @import("../jobs.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const log = @import("../log.zig");

const max_output = 4 * 1024 * 1024;

pub fn pull(ctx: *context.Context) anyerror!void {
    const Body = struct {
        reference: []const u8,
        registry_id: ?[]const u8 = null,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected image reference");
        return;
    };
    return startImageJob(ctx, "pull", body.reference, body.registry_id);
}

pub fn update(ctx: *context.Context) anyerror!void {
    return pull(ctx);
}

pub fn push(ctx: *context.Context) anyerror!void {
    const Body = struct {
        reference: []const u8,
        registry_id: ?[]const u8 = null,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected image reference");
        return;
    };
    return startImageJob(ctx, "push", body.reference, body.registry_id);
}

fn startImageJob(
    ctx: *context.Context,
    action: []const u8,
    reference: []const u8,
    registry_id: ?[]const u8,
) !void {
    if (!validate.isImageRef(reference)) {
        ctx.fail(400, "bad_image", "invalid image reference");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    if (registry_id) |id| {
        const ok = registries.loginById(ctx, engine, socket, id) catch false;
        if (!ok) {
            ctx.fail(401, "login_failed", "镜像源登录失败");
            return;
        }
    }
    const argv = [_][]const u8{ engine.name, action, reference };
    const job_id = jobs_mod.start(.{
        .kind = if (std.mem.eql(u8, action, "pull")) "image-pull" else "image-push",
        .label = reference,
        .argv = &argv,
        .engine = engine,
        .socket = socket,
    }) catch {
        ctx.fail(503, "job_failed", "unable to start image job");
        return;
    };
    log.info("docker: image {s} reference={s}", .{ action, reference });
    try ctx.jsonStatus(202, .{ .job_id = job_id, .reference = reference });
}

pub fn tag(ctx: *context.Context) anyerror!void {
    const Body = struct {
        source: []const u8,
        target: []const u8,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected source and target");
        return;
    };
    if (!validate.isImageRef(body.source) or !validate.isImageRef(body.target)) {
        ctx.fail(400, "bad_image", "invalid image reference");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "tag", body.source, body.target }, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .target = body.target });
}

pub fn remove(ctx: *context.Context) anyerror!void {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing image id");
        return;
    };
    if (!validate.isImageRef(id)) {
        ctx.fail(400, "bad_id", "invalid image reference");
        return;
    }
    const force = if (try ctx.query("force")) |value|
        std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")
    else
        false;
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "rmi" });
    if (force) try argv.append("-f");
    try argv.append(id);
    const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute container engine");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: removed image={s}", .{id});
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .id = id });
}

pub fn prune(ctx: *context.Context) anyerror!void {
    const all = if (try ctx.query("all")) |value|
        std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")
    else
        false;
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "image", "prune" });
    if (all) try argv.append("-a");
    try argv.append("-f");
    return startJob(ctx, engine, socket, "image-prune", "image prune", argv.items, null);
}

pub fn pruneCache(ctx: *context.Context) anyerror!void {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const argv = [_][]const u8{ engine.name, "builder", "prune", "-f" };
    return startJob(ctx, engine, socket, "build-cache-prune", "builder prune", &argv, null);
}

pub fn exportImage(ctx: *context.Context) anyerror!void {
    const Body = struct { reference: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected image reference");
        return;
    };
    if (!validate.isImageRef(body.reference)) {
        ctx.fail(400, "bad_image", "invalid image reference");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const dir = try std.fs.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "docker", "exports" });
    compat.cwd().makePath(dir) catch {};
    const safe = try sanitize(ctx.arena, body.reference);
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}-{d}.tar", .{ dir, safe, compat.timestamp() });
    const argv = [_][]const u8{ engine.name, "save", "-o", path, body.reference };
    return startJob(ctx, engine, socket, "image-export", body.reference, &argv, path);
}

pub fn importImage(ctx: *context.Context) anyerror!void {
    if (ctx.req.body.len == 0) {
        ctx.fail(400, "bad_request", "empty image archive");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const path = try tempFile(ctx, "import", "tar", ctx.req.body);
    const argv = [_][]const u8{ engine.name, "load", "-i", path };
    return startJob(ctx, engine, socket, "image-import", "image import", &argv, null);
}

pub fn build(ctx: *context.Context) anyerror!void {
    const Body = struct {
        tag: []const u8,
        context_path: []const u8,
        dockerfile: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected tag and context_path");
        return;
    };
    if (!validBuildBody(ctx, body.tag, body.dockerfile)) return;
    if (!std.fs.path.isAbsolute(body.context_path) or std.mem.indexOfScalar(u8, body.context_path, 0) != null) {
        ctx.fail(400, "bad_context", "context_path must be absolute");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "build", "-t", body.tag });
    if (body.dockerfile.len > 0) {
        try argv.appendSlice(&.{ "-f", body.dockerfile });
    }
    try argv.append(body.context_path);
    return startJob(ctx, engine, socket, "image-build", body.tag, argv.items, null);
}

pub fn buildGit(ctx: *context.Context) anyerror!void {
    const Body = struct {
        tag: []const u8,
        url: []const u8,
        git_ref: []const u8 = "",
        subdir: []const u8 = "",
        dockerfile: []const u8 = "",
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected tag and git url");
        return;
    };
    if (!validBuildBody(ctx, body.tag, body.dockerfile)) return;
    if (!validGitUrl(body.url)) {
        ctx.fail(400, "bad_url", "invalid git url");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var context_ref = std.array_list.Managed(u8).init(ctx.arena);
    try context_ref.appendSlice(body.url);
    if (body.git_ref.len > 0 or body.subdir.len > 0) {
        try context_ref.append('#');
        if (body.git_ref.len > 0) try context_ref.appendSlice(body.git_ref);
        if (body.subdir.len > 0) {
            try context_ref.append(':');
            try context_ref.appendSlice(body.subdir);
        }
    }
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "build", "-t", body.tag });
    if (body.dockerfile.len > 0) {
        try argv.appendSlice(&.{ "-f", body.dockerfile });
    }
    try argv.append(context_ref.items);
    return startJob(ctx, engine, socket, "image-build", body.tag, argv.items, null);
}

pub fn buildUpload(ctx: *context.Context) anyerror!void {
    const tag_value = (try ctx.query("tag")) orelse {
        ctx.fail(400, "bad_tag", "missing tag");
        return;
    };
    const name = (try ctx.query("name")) orelse "build";
    const dockerfile = (try ctx.query("dockerfile")) orelse "";
    if (!validBuildBody(ctx, tag_value, dockerfile)) return;
    if (!validate.isComposeName(name)) {
        ctx.fail(400, "bad_name", "invalid build name");
        return;
    }
    if (ctx.req.body.len == 0) {
        ctx.fail(400, "bad_request", "empty build context");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const archive = try tempFile(ctx, "build", "tar", ctx.req.body);
    defer compat.deleteFileAbsolute(archive) catch {};
    var random: [4]u8 = undefined;
    compat.randomBytes(&random);
    const dir = try std.fmt.allocPrint(ctx.arena, "{s}/docker/build/{s}-{s}", .{
        ctx.app.config.data_dir,
        name,
        std.fmt.bytesToHex(random, .lower),
    });
    compat.cwd().makePath(dir) catch {
        ctx.fail(500, "fs_failed", "unable to create build directory");
        return;
    };
    const extract = exec.run(ctx.arena, &.{ "tar", "-xf", archive, "-C", dir }, max_output) catch {
        ctx.fail(502, "tar_failed", "unable to extract build context");
        return;
    };
    if (!extract.ok()) {
        ctx.fail(400, "tar_failed", textOf(extract));
        return;
    }
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{ engine.name, "build", "-t", tag_value });
    if (dockerfile.len > 0) {
        try argv.appendSlice(&.{ "-f", dockerfile });
    }
    try argv.append(dir);
    return startJob(ctx, engine, socket, "image-build", tag_value, argv.items, null);
}

pub fn search(ctx: *context.Context) anyerror!void {
    const term = (try ctx.query("term")) orelse "";
    if (term.len == 0 or term.len > 128) {
        ctx.fail(400, "bad_term", "invalid search term");
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var registry_host: []const u8 = "";
    var registry_record: ?registries.Registry = null;
    if (try ctx.query("registry_id")) |id| {
        const record = (registries.find(ctx, id) catch null) orelse {
            ctx.fail(404, "not_found", "registry not found");
            return;
        };
        registry_record = record;
        registry_host = record.host;
    }

    if (registry_host.len == 0 or
        std.mem.eql(u8, registry_host, "docker.io") or
        std.mem.eql(u8, registry_host, "index.docker.io") or
        std.mem.eql(u8, registry_host, "registry-1.docker.io"))
    {
        const result = engine_mod.run(ctx.arena, engine, socket, &.{
            engine.name, "search", term, "--limit", "50", "--format", "{{json .}}",
        }, .{ .max_output = max_output }) catch {
            ctx.fail(502, "docker_unavailable", "unable to execute container engine");
            return;
        };
        if (!result.ok()) {
            ctx.fail(502, "docker_failed", textOf(result));
            return;
        }
        const Result = struct {
            name: []const u8,
            description: []const u8,
            stars: []const u8,
            official: bool,
        };
        var results = std.array_list.Managed(Result).init(ctx.arena);
        for (try engine_mod.parseJsonObjects(ctx.arena, result.stdout)) |value| {
            if (value != .object) continue;
            try results.append(.{
                .name = string(value, "Name"),
                .description = string(value, "Description"),
                .stars = string(value, "StarCount"),
                .official = boolean(value, "IsOfficial"),
            });
        }
        try ctx.json(.{ .results = results.items, .source = "docker.io" });
        return;
    }

    const record = registry_record.?;
    // Never follow registry-controlled redirects or Link URLs with credentials.
    // Catalog pagination stays on the configured origin using an encoded cursor.
    const credentials = try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ record.username, record.secret });
    const encoded = try ctx.arena.alloc(u8, std.base64.standard.Encoder.calcSize(credentials.len));
    _ = std.base64.standard.Encoder.encode(encoded, credentials);
    const config = try std.fmt.allocPrint(ctx.arena, "header = \"Authorization: Basic {s}\"\n", .{encoded});
    var results = std.array_list.Managed([]const u8).init(ctx.arena);
    var last: []const u8 = "";
    var page: usize = 0;
    while (page < 100) : (page += 1) {
        const cursor = try encodeCursor(ctx.arena, last);
        const url = try std.fmt.allocPrint(ctx.arena, "{s}://{s}/v2/_catalog?n=100&last={s}", .{ record.protocol, record.host, cursor });
        const result = try exec.runWith(ctx.arena, &.{ "curl", "-q", "-fsS", "--max-time", "30", "--proto", "=http,https", "--config", "-", url }, .{
            .stdin = config,
            .max_output = max_output,
        });
        if (!result.ok()) {
            ctx.fail(502, "registry_failed", "unable to query registry catalog");
            return;
        }
        const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result.stdout, .{}) catch {
            ctx.fail(502, "registry_failed", "invalid registry response");
            return;
        };
        const repos = if (value == .object) value.object.get("repositories") else null;
        if (repos == null or repos.? != .array) {
            ctx.fail(502, "registry_failed", "invalid catalog");
            return;
        }
        if (repos.?.array.items.len == 0) break;
        const previous = last;
        for (repos.?.array.items) |repo| {
            if (repo != .string or !validate.isImageRef(repo.string)) {
                ctx.fail(502, "registry_failed", "invalid repository");
                return;
            }
            last = repo.string;
            if (std.mem.indexOf(u8, repo.string, term) != null) try results.append(repo.string);
        }
        if (std.mem.eql(u8, previous, last)) {
            ctx.fail(502, "registry_failed", "catalog pagination did not advance");
            return;
        }
    }
    if (page == 100) {
        ctx.fail(502, "registry_failed", "catalog pagination limit exceeded");
        return;
    }
    try ctx.json(.{ .repositories = results.items, .source = record.host });
}

fn validBuildBody(ctx: *context.Context, tag_value: []const u8, dockerfile: []const u8) bool {
    if (!validate.isImageRef(tag_value)) {
        ctx.fail(400, "bad_tag", "invalid image tag");
        return false;
    }
    if (dockerfile.len > 512 or std.mem.indexOfScalar(u8, dockerfile, 0) != null) {
        ctx.fail(400, "bad_dockerfile", "invalid dockerfile path");
        return false;
    }
    return true;
}

fn validGitUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > 2048) return false;
    for (url) |ch| {
        if (ch < 0x20 or ch == ' ') return false;
    }
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "ssh://") or
        std.mem.startsWith(u8, url, "git@");
}

fn startJob(
    ctx: *context.Context,
    engine: engine_mod.Engine,
    socket: []const u8,
    kind: []const u8,
    label: []const u8,
    argv: []const []const u8,
    result_path: ?[]const u8,
) !void {
    const job_id = jobs_mod.start(.{
        .kind = kind,
        .label = label,
        .argv = argv,
        .engine = engine,
        .socket = socket,
        .result_path = result_path,
    }) catch {
        ctx.fail(503, "job_failed", "unable to start image job");
        return;
    };
    try ctx.jsonStatus(202, .{ .job_id = job_id });
}

fn tempFile(ctx: *context.Context, prefix: []const u8, extension: []const u8, body: []const u8) ![]const u8 {
    const dir = try std.fs.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "tmp" });
    compat.cwd().makePath(dir) catch {};
    var random: [6]u8 = undefined;
    compat.randomBytes(&random);
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}-{s}.{s}", .{
        dir,
        prefix,
        std.fmt.bytesToHex(random, .lower),
        extension,
    });
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(body);
    return path;
}

fn sanitize(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, value.len);
    for (value, 0..) |ch, index| {
        out[index] = switch (ch) {
            '/', ':', '@' => '_',
            else => ch,
        };
    }
    return out;
}

fn string(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const entry = value.object.get(key) orelse return "";
    return if (entry == .string) entry.string else "";
}

fn boolean(value: std.json.Value, key: []const u8) bool {
    if (value != .object) return false;
    const entry = value.object.get(key) orelse return false;
    return switch (entry) {
        .bool => |flag| flag,
        .string => |text| std.mem.eql(u8, text, "true"),
        else => false,
    };
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}

fn encodeCursor(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    const hex = "0123456789ABCDEF";
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(ch);
        } else {
            try out.appendSlice(&.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    return out.toOwnedSlice();
}

test "catalog cursor cannot change origin or inject query parameters" {
    const cursor = try encodeCursor(std.testing.allocator, "a/b&last=//evil%20");
    defer std.testing.allocator.free(cursor);
    try std.testing.expectEqualStrings("a%2Fb%26last%3D%2F%2Fevil%2520", cursor);
}

test "build context platform absolute paths" {
    try std.testing.expect(std.fs.path.isAbsoluteWindows("C:\\work"));
    try std.testing.expect(!std.fs.path.isAbsoluteWindows("C:work"));
    try std.testing.expect(std.fs.path.isAbsolutePosix("/work"));
    try std.testing.expect(!std.fs.path.isAbsolutePosix("work"));
}
