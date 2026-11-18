const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const site_store = @import("../runtime/site_store.zig");
const exec = @import("shared").exec;
const types = @import("shared").types;

pub fn sources(ctx: *context.Context) anyerror!void {
    const list = collectSources(ctx) catch |err| {
        ctx.fail(500, "logs_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .sources = list });
}

pub fn tail(ctx: *context.Context) anyerror!void {
    const id = (try ctx.query("source")) orelse "audit";
    if (std.mem.eql(u8, id, "audit")) {
        try audit(ctx);
        return;
    }
    const list = collectSources(ctx) catch |err| {
        ctx.fail(500, "logs_failed", @errorName(err));
        return;
    };

    for (list) |source| {
        if (std.mem.eql(u8, source.id, id)) {
            try tailPath(ctx, source.path);
            return;
        }
    }
    ctx.fail(404, "unknown_source", "unknown log source");
}

pub fn audit(ctx: *context.Context) anyerror!void {
    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }
    const entries = ctx.app.audit.recent(ctx.arena, lines) catch |err| {
        ctx.fail(500, "audit_failed", @errorName(err));
        return;
    };
    try ctx.json(.{
        .path = "sqlite:audit_log",
        .lines = lines,
        .truncated = false,
        .entries = entries,
    });
}

fn tailJournal(ctx: *context.Context, path: []const u8, lines: usize) !void {
    const kind = path["journal:".len..];
    const count = try std.fmt.allocPrint(ctx.arena, "{d}", .{lines});
    var argv = std.array_list.Managed([]const u8).init(ctx.arena);
    try argv.appendSlice(&.{
        "journalctl", "-n", count,
        "--no-pager", "-o", "short-iso",
    });
    if (std.mem.eql(u8, kind, "auth")) {
        try argv.appendSlice(&.{ "-t", "sshd", "-t", "sudo", "-t", "su" });
    }
    const result = exec.run(ctx.arena, argv.items, 1024 * 1024) catch {
        ctx.fail(500, "journal_failed", "cannot run journalctl");
        return;
    };
    if (!result.ok()) {
        ctx.fail(502, "journal_failed", "journalctl returned an error");
        return;
    }
    try ctx.json(.{
        .path = path,
        .lines = lines,
        .truncated = false,
        .content = result.stdout,
    });
}

fn collectSources(ctx: *context.Context) ![]types.LogSource {
    var list = std.array_list.Managed(types.LogSource).init(ctx.arena);
    const base = platform.logs.sources(
        ctx.arena,
        ctx.app.config.data_dir,
        webServer(ctx),
    ) catch |err| {
        if (err != error.Unsupported) return err;
        return list.items;
    };
    try list.appendSlice(base);

    const sites = site_store.list(ctx.arena, ctx.app.config.data_dir) catch &.{};
    for (sites) |site| {
        if (site.access_log.len == 0) continue;
        try list.append(.{
            .id = try std.fmt.allocPrint(ctx.arena, "site-{s}", .{site.name}),
            .label = try std.fmt.allocPrint(
                ctx.arena,
                "站点访问日志：{s}",
                .{site.name},
            ),
            .path = site.access_log,
            .available = pathExists(site.access_log),
        });
    }
    return list.items;
}

fn webServer(ctx: *context.Context) []const u8 {
    if (ctx.app.config.web_server.len > 0) return ctx.app.config.web_server;
    if (exec.commandExists(ctx.arena, "nginx")) return "nginx";
    if (exec.commandExists(ctx.arena, "caddy")) return "caddy";
    return "";
}

fn pathExists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn tailPath(ctx: *context.Context, path: []const u8) !void {
    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }

    if (std.mem.startsWith(u8, path, "journal:")) {
        try tailJournal(ctx, path, lines);
        return;
    }

    var file = compat.openFileAbsolute(path, .{}) catch {
        ctx.fail(404, "not_found", "log file not found");
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        ctx.fail(500, "stat_failed", "cannot stat log file");
        return;
    };
    const size: u64 = @intCast(stat.size);
    const window: u64 = @min(size, 512 * 1024);

    var content: []const u8 = "";
    var truncated = size > window;

    if (window > 0) {
        const buffer = try ctx.arena.alloc(u8, @intCast(window));
        const read = file.readPositionalAll(buffer, size - window) catch {
            ctx.fail(500, "read_failed", "cannot read log file");
            return;
        };

        var collected = std.array_list.Managed([]const u8).init(ctx.arena);
        var it = std.mem.splitScalar(u8, buffer[0..read], '\n');
        while (it.next()) |line| try collected.append(line);

        const start = if (collected.items.len > lines) collected.items.len - lines else 0;
        if (start > 0) truncated = true;
        content = try std.mem.join(ctx.arena, "\n", collected.items[start..]);
    }

    try ctx.json(.{
        .path = path,
        .lines = lines,
        .truncated = truncated,
        .content = content,
    });
}
