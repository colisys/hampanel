const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const engine_mod = @import("../runtime/engine.zig");
const jobs_mod = @import("../jobs.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const log = @import("../log.zig");

const max_output = 8 * 1024 * 1024;
const max_compose = 1024 * 1024;

const Project = struct {
    name: []const u8,
    dir: []const u8,
    source_dir: []const u8,
    files: []const []const u8,
    adopted: bool,
    managed: bool,
    status: []const u8 = "",
};

const External = struct {
    name: []const u8,
    status: []const u8,
    config_files: []const []const u8,
};

pub fn index(ctx: *context.Context) anyerror!void {
    var projects = std.array_list.Managed(Project).init(ctx.arena);
    try appendManaged(ctx, &projects);
    try appendStoreApps(ctx, &projects);
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        try ctx.json(.{ .projects = projects.items });
        return;
    };
    const externals = loadExternal(ctx, engine, socket) catch &[_]External{};
    for (externals) |external| {
        var found = false;
        for (projects.items) |project| {
            if (std.mem.eql(u8, project.name, external.name)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        try projects.append(.{
            .name = external.name,
            .dir = "",
            .source_dir = "",
            .files = external.config_files,
            .adopted = false,
            .managed = false,
            .status = external.status,
        });
    }
    try ctx.json(.{ .projects = projects.items });
}

pub fn detail(ctx: *context.Context) anyerror!void {
    const name = requireName(ctx) orelse return;
    if (try managed(ctx, name)) |project| {
        const content = try readMain(ctx, project);
        try ctx.json(.{
            .name = project.name,
            .dir = project.dir,
            .source_dir = project.source_dir,
            .files = project.files,
            .adopted = project.adopted,
            .managed = true,
            .content = content,
        });
        return;
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    const externals = loadExternal(ctx, engine, socket) catch &[_]External{};
    for (externals) |external| {
        if (!std.mem.eql(u8, external.name, name)) continue;
        const content = if (external.config_files.len > 0)
            readAbsolute(ctx, external.config_files[0]) catch ""
        else
            "";
        try ctx.json(.{
            .name = external.name,
            .dir = "",
            .source_dir = if (external.config_files.len > 0)
                (std.fs.path.dirname(external.config_files[0]) orelse "")
            else
                "",
            .files = external.config_files,
            .adopted = false,
            .managed = false,
            .status = external.status,
            .content = content,
        });
        return;
    }
    ctx.fail(404, "not_found", "compose 项目不存在");
}

pub fn create(ctx: *context.Context) anyerror!void {
    const Body = struct {
        name: []const u8,
        content: []const u8,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected name and content");
        return;
    };
    if (!validate.isComposeName(body.name)) {
        ctx.fail(400, "bad_name", "invalid compose project name");
        return;
    }
    if (!validYaml(body.content)) {
        ctx.fail(400, "bad_content", "invalid compose content");
        return;
    }
    if (try managed(ctx, body.name) != null) {
        ctx.fail(409, "exists", "compose 项目已存在");
        return;
    }
    const dir = try projectDir(ctx, body.name);
    compat.deleteTreeAbsolute(dir) catch {};
    compat.cwd().makePath(dir) catch {
        ctx.fail(500, "fs_failed", "unable to create project directory");
        return;
    };
    try writeMain(ctx, dir, body.content);
    if (!(try validateProject(ctx, dir, &.{"compose.yml"}))) {
        compat.deleteTreeAbsolute(dir) catch {};
        ctx.fail(400, "invalid_compose", "compose 校验失败");
        return;
    }
    try insertProject(ctx, .{
        .name = body.name,
        .dir = dir,
        .source_dir = "",
        .files = &.{"compose.yml"},
        .adopted = false,
        .managed = true,
    });
    log.info("docker: compose project created name={s}", .{body.name});
    try ctx.jsonStatus(201, .{
        .name = body.name,
        .dir = dir,
        .source_dir = "",
        .files = &.{"compose.yml"},
        .adopted = false,
        .managed = true,
        .content = body.content,
    });
}

pub fn update(ctx: *context.Context) anyerror!void {
    const name = requireName(ctx) orelse return;
    const project = (try managed(ctx, name)) orelse {
        ctx.fail(409, "unmanaged", "外部 compose 项目需先接管");
        return;
    };
    const Body = struct { content: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected content");
        return;
    };
    if (!validYaml(body.content)) {
        ctx.fail(400, "bad_content", "invalid compose content");
        return;
    }
    if (project.files.len == 0) return error.InvalidComposeFiles;
    const previous = try readMain(ctx, project);
    try writeFile(ctx, project.dir, project.files[0], body.content);
    if (!(try validateProject(ctx, project.dir, project.files))) {
        writeFile(ctx, project.dir, project.files[0], previous) catch {};
        ctx.fail(400, "invalid_compose", "compose 校验失败");
        return;
    }
    try ctx.app.db.execute(
        "UPDATE compose_projects SET updated_at = ?1 WHERE name = ?2",
        &.{ .{ .int = compat.timestamp() }, .{ .text = project.name } },
    );
    try ctx.json(.{ .ok = true });
}

pub fn adopt(ctx: *context.Context) anyerror!void {
    const Body = struct {
        name: []const u8,
        config_files: []const []const u8,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected name and config_files");
        return;
    };
    if (!validate.isComposeName(body.name)) {
        ctx.fail(400, "bad_name", "invalid compose project name");
        return;
    }
    if (body.config_files.len == 0) {
        ctx.fail(400, "bad_request", "config_files is empty");
        return;
    }
    if (try managed(ctx, body.name) != null) {
        ctx.fail(409, "exists", "compose 项目已存在");
        return;
    }
    const dir = try projectDir(ctx, body.name);
    compat.deleteTreeAbsolute(dir) catch {};
    compat.cwd().makePath(dir) catch {
        ctx.fail(500, "fs_failed", "unable to create project directory");
        return;
    };

    var copied = std.array_list.Managed([]const u8).init(ctx.arena);
    for (body.config_files, 0..) |source, file_index| {
        const raw = readAbsolute(ctx, source) catch {
            compat.deleteTreeAbsolute(dir) catch {};
            ctx.fail(400, "read_failed", "unable to read compose file");
            return;
        };
        var base = std.fs.path.basename(source);
        if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
            base = try std.fmt.allocPrint(ctx.arena, "compose-{d}.yml", .{file_index});
        }
        for (copied.items) |existing| {
            if (std.mem.eql(u8, existing, base)) {
                base = try std.fmt.allocPrint(ctx.arena, "{d}-{s}", .{ file_index, base });
                break;
            }
        }
        try writeFile(ctx, dir, base, raw);
        try copied.append(base);
    }
    if (!(try validateProject(ctx, dir, copied.items))) {
        compat.deleteTreeAbsolute(dir) catch {};
        ctx.fail(400, "invalid_compose", "compose 校验失败");
        return;
    }
    const source_dir = std.fs.path.dirname(body.config_files[0]) orelse "";
    try insertProject(ctx, .{
        .name = body.name,
        .dir = dir,
        .source_dir = source_dir,
        .files = copied.items,
        .adopted = true,
        .managed = true,
    });
    log.info("docker: compose project adopted name={s}", .{body.name});
    try ctx.jsonStatus(201, .{
        .ok = true,
        .name = body.name,
        .dir = dir,
        .source_dir = source_dir,
        .files = copied.items,
        .adopted = true,
        .managed = true,
    });
}

pub fn destroy(ctx: *context.Context) anyerror!void {
    const name = requireName(ctx) orelse return;
    const project = (try managed(ctx, name)) orelse {
        ctx.fail(409, "unmanaged", "外部 compose 项目不支持删除");
        return;
    };
    var down = false;
    if (try ctx.query("down")) |value| {
        down = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
    }
    var volumes = false;
    if (try ctx.query("volumes")) |value| {
        volumes = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
    }
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    if (down) {
        var extra = std.array_list.Managed([]const u8).init(ctx.arena);
        try extra.append("down");
        if (volumes) try extra.append("-v");
        const argv = try composeArgv(ctx, engine, socket, project, extra.items);
        const result = engine_mod.run(ctx.arena, engine, socket, argv, .{ .max_output = max_output }) catch {
            ctx.fail(502, "docker_unavailable", "unable to execute compose");
            return;
        };
        if (!result.ok()) {
            ctx.fail(502, "compose_failed", textOf(result));
            return;
        }
    }
    compat.deleteTreeAbsolute(project.dir) catch {};
    try ctx.app.db.execute(
        "DELETE FROM compose_projects WHERE name = ?1",
        &.{.{ .text = project.name }},
    );
    log.info("docker: compose project deleted name={s}", .{project.name});
    try ctx.json(.{ .ok = true, .name = project.name });
}

pub fn action(ctx: *context.Context) anyerror!void {
    const name = requireName(ctx) orelse return;
    const action_name = ctx.param("action") orelse {
        ctx.fail(400, "bad_action", "missing action");
        return;
    };
    if (!std.mem.eql(u8, action_name, "up") and
        !std.mem.eql(u8, action_name, "down") and
        !std.mem.eql(u8, action_name, "restart") and
        !std.mem.eql(u8, action_name, "pull"))
    {
        ctx.fail(400, "bad_action", "unsupported compose action");
        return;
    }
    const project = (try managed(ctx, name)) orelse {
        ctx.fail(409, "unmanaged", "外部 compose 项目需先接管");
        return;
    };
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var extra = std.array_list.Managed([]const u8).init(ctx.arena);
    try extra.append(action_name);
    if (std.mem.eql(u8, action_name, "up")) {
        try extra.append("-d");
        try extra.append("--remove-orphans");
    }
    if (std.mem.eql(u8, action_name, "down")) {
        if (try ctx.query("volumes")) |value| {
            if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) {
                try extra.append("-v");
            }
        }
    }
    const argv = try composeArgv(ctx, engine, socket, project, extra.items);

    if (std.mem.eql(u8, action_name, "up") or std.mem.eql(u8, action_name, "pull")) {
        const job_id = jobs_mod.start(.{
            .kind = "compose",
            .label = try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ project.name, action_name }),
            .argv = argv,
            .engine = engine,
            .socket = socket,
        }) catch {
            ctx.fail(503, "job_failed", "unable to start compose job");
            return;
        };
        try ctx.jsonStatus(202, .{ .job_id = job_id, .name = project.name });
        return;
    }

    const result = engine_mod.run(ctx.arena, engine, socket, argv, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute compose");
        return;
    };
    if (!result.ok()) ctx.response.status = 502;
    log.info("docker: compose {s} name={s}", .{ action_name, project.name });
    try ctx.json(.{ .ok = result.ok(), .output = textOf(result), .name = project.name });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const name = requireName(ctx) orelse return;
    const project = (try managed(ctx, name)) orelse {
        ctx.fail(409, "unmanaged", "外部 compose 项目需先接管");
        return;
    };
    const lines = (try ctx.query("lines")) orelse "300";
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch {
        ctx.fail(503, "engine_unavailable", "engine unavailable");
        return;
    };
    var extra = std.array_list.Managed([]const u8).init(ctx.arena);
    try extra.appendSlice(&.{ "logs", "--no-color", "--tail" });
    try extra.append(lines);
    const argv = try composeArgv(ctx, engine, socket, project, extra.items);
    const result = engine_mod.run(ctx.arena, engine, socket, argv, .{ .max_output = max_output }) catch {
        ctx.fail(502, "docker_unavailable", "unable to execute compose");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "compose_failed", textOf(result));
        return;
    }
    try ctx.json(.{ .name = project.name, .output = result.stdout });
}

fn appendManaged(ctx: *context.Context, projects: *std.array_list.Managed(Project)) !void {
    const database = ctx.app.db;
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked(
        "SELECT name, dir, source_dir, files, adopted FROM compose_projects ORDER BY name",
    );
    defer statement.deinit();
    while (try statement.step()) {
        const files_json = try statement.dupeColumnText(ctx.arena, 3);
        try projects.append(.{
            .name = try statement.dupeColumnText(ctx.arena, 0),
            .dir = try statement.dupeColumnText(ctx.arena, 1),
            .source_dir = try statement.dupeColumnText(ctx.arena, 2),
            .files = parseFiles(ctx.arena, files_json),
            .adopted = statement.columnInt(4) != 0,
            .managed = true,
        });
    }
}

fn managed(ctx: *context.Context, name: []const u8) !?Project {
    const database = ctx.app.db;
    database.lock();
    defer database.unlock();
    var statement = try database.prepareUnlocked(
        "SELECT name, dir, source_dir, files, adopted FROM compose_projects WHERE name = ?1",
    );
    defer statement.deinit();
    try statement.bind(&.{.{ .text = name }});
    if (!(try statement.step())) return storeAppProject(ctx, name);
    const files_json = try statement.dupeColumnText(ctx.arena, 3);
    return .{
        .name = try statement.dupeColumnText(ctx.arena, 0),
        .dir = try statement.dupeColumnText(ctx.arena, 1),
        .source_dir = try statement.dupeColumnText(ctx.arena, 2),
        .files = parseFiles(ctx.arena, files_json),
        .adopted = statement.columnInt(4) != 0,
        .managed = true,
    };
}

/// Store-installed compose apps live at `<data_dir>/apps/<slug>/compose.yml`
/// under project name `hampanel-<slug>`. They were invisible to the compose
/// page before, so the container detail page told users to edit a project that
/// was not listed anywhere. Treating them like managed projects makes them
/// editable and operable from the same page.
fn storeAppProject(ctx: *context.Context, name: []const u8) ?Project {
    const slug = storeSlug(name) orelse return null;
    const path = std.fs.path.join(ctx.arena, &.{
        ctx.app.config.data_dir, "apps", slug, "compose.yml",
    }) catch return null;
    compat.cwd().access(path, .{}) catch return null;
    const files = ctx.arena.alloc([]const u8, 1) catch return null;
    files[0] = "compose.yml";
    return .{
        .name = name,
        .dir = std.fs.path.dirname(path) orelse "",
        .source_dir = "",
        .files = files,
        .adopted = false,
        .managed = true,
    };
}

fn storeSlug(project_name: []const u8) ?[]const u8 {
    const prefix = "hampanel-";
    if (!std.mem.startsWith(u8, project_name, prefix)) return null;
    const slug = project_name[prefix.len..];
    return if (slug.len == 0) null else slug;
}

fn appendStoreApps(ctx: *context.Context, projects: *std.array_list.Managed(Project)) !void {
    const apps_dir = try std.fs.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "apps" });
    var dir = compat.openDirAny(apps_dir, true) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const project_name = std.fmt.allocPrint(ctx.arena, "hampanel-{s}", .{entry.name}) catch continue;
        const project = storeAppProject(ctx, project_name) orelse continue;
        // A project already registered in the table wins; skip the duplicate.
        var duplicate = false;
        for (projects.items) |existing| {
            if (std.mem.eql(u8, existing.name, project.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try projects.append(project);
    }
}

fn insertProject(ctx: *context.Context, project: Project) !void {
    const files_json = try std.json.Stringify.valueAlloc(ctx.arena, project.files, .{});
    try ctx.app.db.execute(
        "INSERT INTO compose_projects(name, dir, source_dir, files, adopted, created_at, updated_at) " ++
            "VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        &.{
            .{ .text = project.name },
            .{ .text = project.dir },
            .{ .text = project.source_dir },
            .{ .text = files_json },
            .{ .int = if (project.adopted) 1 else 0 },
            .{ .int = compat.timestamp() },
            .{ .int = compat.timestamp() },
        },
    );
}

fn parseFiles(allocator: std.mem.Allocator, raw: []const u8) []const []const u8 {
    var files = std.array_list.Managed([]const u8).init(allocator);
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{}) catch return files.items;
    if (value == .array) {
        for (value.array.items) |item| {
            if (item == .string) files.append(item.string) catch {};
        }
    }
    return files.items;
}

fn loadExternal(ctx: *context.Context, engine: engine_mod.Engine, socket: []const u8) ![]const External {
    var projects = std.array_list.Managed(External).init(ctx.arena);
    try projects.appendSlice(try composeListing(ctx, engine, socket));
    // Some providers (notably podman-compose) do not implement compose ls.
    // Labels identify projects, but must never authorize reading host paths.
    const result = engine_mod.run(ctx.arena, engine, socket, &.{ engine.name, "ps", "-a", "--format", "{{.Label \"com.docker.compose.project\"}}" }, .{ .max_output = max_output }) catch return projects.items;
    if (result.ok()) {
        var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
        while (lines.next()) |line| {
            const name = std.mem.trim(u8, line, " \t");
            if (!validate.isComposeName(name)) continue;
            for (projects.items) |project| {
                if (std.mem.eql(u8, name, project.name)) break;
            } else try projects.append(.{ .name = name, .status = "", .config_files = &.{} });
        }
    }
    return projects.items;
}

fn composeListing(ctx: *context.Context, engine: engine_mod.Engine, socket: []const u8) ![]const External {
    const base = engine_mod.composeCommand(ctx.arena, engine, socket) catch return &.{};
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(base);
    try argv.appendSlice(&.{ "ls", "--all", "--format", "json" });
    const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = max_output }) catch return &.{};
    if (!result.ok()) return &.{};
    const rows = try engine_mod.parseJsonObjects(ctx.arena, result.stdout);
    var projects = std.array_list.Managed(External).init(ctx.arena);
    for (rows) |item| {
        if (item != .object) continue;
        const name = field(item, "Name");
        if (name.len == 0) continue;
        const config_raw = field(item, "ConfigFiles");
        var config_files = std.array_list.Managed([]const u8).init(ctx.arena);
        var iter = std.mem.splitScalar(u8, config_raw, ',');
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len > 0) try config_files.append(trimmed);
        }
        try projects.append(.{
            .name = name,
            .status = field(item, "Status"),
            .config_files = config_files.items,
        });
    }
    return projects.items;
}

fn composeArgv(
    ctx: *context.Context,
    engine: engine_mod.Engine,
    socket: []const u8,
    project: Project,
    extra: []const []const u8,
) ![]const []const u8 {
    const base = engine_mod.composeCommand(ctx.arena, engine, socket) catch {
        return error.ComposeUnavailable;
    };
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(base);
    try argv.append("-p");
    try argv.append(project.name);
    for (project.files) |file| {
        try argv.append("-f");
        try argv.append(try std.fs.path.join(ctx.arena, &.{ project.dir, file }));
    }
    if (project.source_dir.len > 0) {
        try argv.append("--project-directory");
        try argv.append(project.source_dir);
    }
    try argv.appendSlice(extra);
    return argv.items;
}

fn projectDir(ctx: *context.Context, name: []const u8) ![]const u8 {
    return std.fs.path.join(ctx.arena, &.{ ctx.app.config.data_dir, "compose", name });
}

fn readMain(ctx: *context.Context, project: Project) ![]const u8 {
    if (project.files.len == 0) return "";
    const path = try std.fs.path.join(ctx.arena, &.{ project.dir, project.files[0] });
    return readAbsolute(ctx, path);
}

fn readAbsolute(ctx: *context.Context, path: []const u8) ![]const u8 {
    var file = try compat.openFileAny(path, .{});
    defer file.close();
    return file.readToEndAlloc(ctx.arena, max_compose);
}

fn writeMain(ctx: *context.Context, dir: []const u8, content: []const u8) !void {
    try writeFile(ctx, dir, "compose.yml", content);
}

fn writeFile(ctx: *context.Context, dir: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(ctx.arena, &.{ dir, name });
    var file = try compat.createFileAny(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(content);
}

fn validateProject(ctx: *context.Context, dir: []const u8, files: []const []const u8) !bool {
    const socket = engine_mod.socketFromDb(ctx.arena, ctx.app.db);
    const engine = engine_mod.detect(ctx.arena, socket) catch return false;
    const base = engine_mod.composeCommand(ctx.arena, engine, socket) catch return false;
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(base);
    for (files) |file| {
        try argv.append("-f");
        try argv.append(try std.fs.path.join(ctx.arena, &.{ dir, file }));
    }
    try argv.appendSlice(&.{ "config", "-q" });
    const result = engine_mod.run(ctx.arena, engine, socket, argv.items, .{ .max_output = 1024 * 1024 }) catch return false;
    return result.ok();
}

fn validYaml(content: []const u8) bool {
    if (content.len == 0 or content.len > max_compose) return false;
    return std.mem.indexOfScalar(u8, content, 0) == null;
}

fn requireName(ctx: *context.Context) ?[]const u8 {
    const name = ctx.param("name") orelse {
        ctx.fail(400, "bad_name", "missing compose project name");
        return null;
    };
    if (!validate.isComposeName(name)) {
        ctx.fail(400, "bad_name", "invalid compose project name");
        return null;
    }
    return name;
}

fn field(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const entry = value.object.get(key) orelse return "";
    return if (entry == .string) entry.string else "";
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}

test "store app projects are addressed as hampanel-<slug>" {
    // The compose page addresses a project by the label the container carries,
    // which store installs set to `hampanel-<slug>`; the slug is the directory
    // under apps/.
    try std.testing.expectEqualStrings("nginx", storeSlug("hampanel-nginx").?);
    try std.testing.expectEqualStrings("pure-ftpd", storeSlug("hampanel-pure-ftpd").?);
    // Anything else is a managed or external project, not a store app.
    try std.testing.expect(storeSlug("nginx") == null);
    try std.testing.expect(storeSlug("hampanel-") == null);
    try std.testing.expect(storeSlug("my-hampanel-nginx") == null);
}
