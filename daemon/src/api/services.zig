const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const notify = @import("../notify.zig");
const platform = @import("../platform/mod.zig");
const validate = @import("shared").validate;
const exec = @import("shared").exec;
const versions = @import("../versions.zig");
const log = @import("../log.zig");
const redact = @import("../util/redact.zig");

const max_output = 4 * 1024 * 1024;
const max_config = 1024 * 1024;

pub fn index(ctx: *context.Context) anyerror!void {
    const services = platform.services.list(ctx.arena) catch |err| {
        ctx.fail(502, "services_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .services = services, .count = services.len });
}

pub fn action(ctx: *context.Context) anyerror!void {
    const unit = ctx.param("name") orelse {
        ctx.fail(400, "bad_unit", "missing unit name");
        return;
    };
    const action_name = ctx.param("action") orelse {
        ctx.fail(400, "bad_action", "missing action");
        return;
    };

    if (!validate.isUnitName(unit)) {
        ctx.fail(400, "bad_unit", "invalid unit name");
        return;
    }

    const allowed = [_][]const u8{ "start", "stop", "restart", "reload", "enable", "disable" };
    var valid = false;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, action_name, candidate)) valid = true;
    }
    if (!valid) {
        ctx.fail(400, "bad_action", "unsupported action");
        return;
    }

    const outcome = platform.services.action(ctx.arena, unit, action_name) catch |err| {
        ctx.fail(502, "services_failed", @errorName(err));
        return;
    };

    if (!outcome.ok) ctx.response.status = 502;
    var unit_buf: [96]u8 = undefined;
    if (outcome.ok) {
        log.info("services: {s} unit={s}", .{ action_name, redact.text(&unit_buf, unit) });
    } else {
        log.warn("services: {s} failed unit={s}", .{ action_name, redact.text(&unit_buf, unit) });
    }
    if (std.mem.eql(u8, action_name, "restart") and outcome.ok) {
        const body = std.fmt.allocPrint(ctx.arena, "服务 {s} 已重启", .{unit}) catch "服务已重启";
        notify.emit(ctx.app.db, .service_restart, "服务重启", body);
    }
    try ctx.json(.{
        .unit = unit,
        .action = action_name,
        .ok = outcome.ok,
        .output = outcome.output,
    });
}

pub fn logs(ctx: *context.Context) anyerror!void {
    const unit = ctx.param("name") orelse {
        ctx.fail(400, "bad_unit", "missing unit name");
        return;
    };
    if (!validate.isUnitName(unit)) {
        ctx.fail(400, "bad_unit", "invalid unit name");
        return;
    }

    var lines: usize = 200;
    if (try ctx.query("lines")) |raw| {
        lines = std.fmt.parseInt(usize, raw, 10) catch 200;
        lines = std.math.clamp(lines, 1, 2000);
    }

    const text = platform.services.logs(ctx.arena, unit, lines) catch |err| {
        ctx.fail(502, "logs_failed", @errorName(err));
        return;
    };
    try ctx.json(.{ .unit = unit, .lines = text });
}

const ConfigFile = struct {
    path: []const u8,
    content: []const u8,
    editable: bool,
    source: []const u8,
};

pub fn config(ctx: *context.Context) anyerror!void {
    const unit = ctx.param("name") orelse {
        ctx.fail(400, "bad_unit", "missing unit name");
        return;
    };
    if (!validate.isUnitName(unit)) {
        ctx.fail(400, "bad_unit", "invalid unit name");
        return;
    }
    if (platform.is_windows) {
        ctx.fail(501, "unsupported", "service unit editing is only available on Linux");
        return;
    }

    const result = exec.run(ctx.arena, &.{ "systemctl", "cat", unit }, max_output) catch |err| {
        ctx.fail(502, "services_failed", @errorName(err));
        return;
    };
    if (!result.ok()) {
        ctx.fail(404, "not_found", "service unit not found");
        return;
    }

    var files = std.array_list.Managed(ConfigFile).init(ctx.arena);
    var current_path: ?[]const u8 = null;
    var content = std.array_list.Managed(u8).init(ctx.arena);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# /")) {
            if (current_path) |path| {
                try appendConfigFile(ctx.arena, &files, path, content.items);
            }
            current_path = try ctx.arena.dupe(u8, line[2..]);
            content.clearRetainingCapacity();
            continue;
        }
        if (current_path == null) continue;
        try content.appendSlice(line);
        try content.append('\n');
    }
    if (current_path) |path| {
        try appendConfigFile(ctx.arena, &files, path, content.items);
    }
    if (files.items.len == 0) {
        ctx.fail(404, "not_found", "service unit has no readable files");
        return;
    }

    const dropin_path = try std.fmt.allocPrint(
        ctx.arena,
        "/etc/systemd/system/{s}.d/hampanel.conf",
        .{unit},
    );
    try ctx.json(.{
        .unit = unit,
        .files = files.items,
        .dropin_path = dropin_path,
        .daemon_reload_required = true,
    });
}

pub fn saveConfig(ctx: *context.Context) anyerror!void {
    const unit = ctx.param("name") orelse {
        ctx.fail(400, "bad_unit", "missing unit name");
        return;
    };
    if (!validate.isUnitName(unit)) {
        ctx.fail(400, "bad_unit", "invalid unit name");
        return;
    }
    if (platform.is_windows) {
        ctx.fail(501, "unsupported", "service unit editing is only available on Linux");
        return;
    }

    const Body = struct {
        path: []const u8,
        content: []const u8,
        restart: bool = false,
    };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected path and content");
        return;
    };
    if (body.content.len > max_config) {
        ctx.fail(400, "too_large", "service configuration is too large");
        return;
    }
    if (!try isSafeServicePath(ctx.arena, unit, body.path)) {
        ctx.fail(400, "bad_path", "only /etc/systemd/system unit files and drop-ins can be edited");
        return;
    }

    const original = readConfigFile(ctx.arena, body.path) catch |err| switch (err) {
        error.FileTooLarge => {
            ctx.fail(400, "too_large", "service configuration is too large");
            return;
        },
        error.FileNotFound => null,
        else => {
            ctx.fail(500, "read_failed", @errorName(err));
            return;
        },
    };

    _ = versions.snapshot(ctx.arena, ctx.app.config.data_dir, body.path) catch {
        // A new drop-in file has no previous version; continue.
    };

    const parent = std.fs.path.dirname(body.path) orelse {
        ctx.fail(400, "bad_path", "path has no parent directory");
        return;
    };
    compat.cwd().makePath(parent) catch |err| {
        ctx.fail(400, "mkdir_failed", @errorName(err));
        return;
    };

    var file = compat.createFileAbsolute(body.path, .{ .truncate = true, .mode = 0o644 }) catch |err| {
        ctx.fail(400, "write_failed", @errorName(err));
        return;
    };
    file.writeAll(body.content) catch |err| {
        file.close();
        try rollbackFile(body.path, original);
        ctx.fail(500, "write_failed", @errorName(err));
        return;
    };
    file.close();

    var output = std.array_list.Managed(u8).init(ctx.arena);
    const reload = exec.run(ctx.arena, &.{ "systemctl", "daemon-reload" }, 1024 * 1024) catch |err| {
        try rollbackFile(body.path, original);
        ctx.fail(502, "reload_failed", @errorName(err));
        return;
    };
    try appendOutput(&output, reload.stdout);
    try appendOutput(&output, reload.stderr);
    if (!reload.ok()) {
        try rollbackFile(body.path, original);
        ctx.response.status = 502;
        try ctx.json(.{
            .unit = unit,
            .path = body.path,
            .ok = false,
            .output = output.items,
        });
        return;
    }

    const cat = exec.run(ctx.arena, &.{ "systemctl", "cat", unit }, max_output) catch {
        try rollbackFile(body.path, original);
        ctx.fail(502, "validate_failed", "cannot validate unit");
        return;
    };
    if (!cat.ok()) {
        try rollbackFile(body.path, original);
        ctx.response.status = 502;
        try ctx.json(.{
            .unit = unit,
            .path = body.path,
            .ok = false,
            .output = "systemctl cat failed after reload",
        });
        return;
    }

    var ok = true;
    if (body.restart) {
        const restart = exec.run(ctx.arena, &.{ "systemctl", "restart", unit }, max_output) catch |err| {
            try appendOutput(&output, @errorName(err));
            ok = false;
            ctx.response.status = 502;
            try ctx.json(.{
                .unit = unit,
                .path = body.path,
                .ok = false,
                .output = output.items,
            });
            return;
        };
        try appendOutput(&output, restart.stdout);
        try appendOutput(&output, restart.stderr);
        if (!restart.ok()) {
            ok = false;
            ctx.response.status = 502;
        }
    }

    var path_buf: [96]u8 = undefined;
    log.info("services: config saved unit={s} path={s}", .{
        redact.text(&path_buf, unit),
        body.path,
    });
    try ctx.json(.{
        .unit = unit,
        .path = body.path,
        .ok = ok,
        .output = output.items,
    });
}

fn appendConfigFile(
    allocator: std.mem.Allocator,
    files: *std.array_list.Managed(ConfigFile),
    path: []const u8,
    raw_content: []const u8,
) !void {
    const content = std.mem.trimEnd(u8, raw_content, "\n");
    const editable = std.mem.startsWith(u8, path, "/etc/systemd/system/");
    try files.append(.{
        .path = try allocator.dupe(u8, path),
        .content = try allocator.dupe(u8, content),
        .editable = editable,
        .source = if (editable) "admin" else "vendor",
    });
}

fn isSafeServicePath(allocator: std.mem.Allocator, unit: []const u8, path: []const u8) !bool {
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    const unit_path = try std.fmt.allocPrint(allocator, "/etc/systemd/system/{s}", .{unit});
    if (std.mem.eql(u8, path, unit_path)) return true;
    const prefix = try std.fmt.allocPrint(allocator, "/etc/systemd/system/{s}.d/", .{unit});
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const tail = path[prefix.len..];
    if (tail.len == 0 or std.mem.indexOfScalar(u8, tail, '/') != null) return false;
    return std.mem.endsWith(u8, tail, ".conf");
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var file = compat.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    if (stat.size > max_config) return error.FileTooLarge;
    const buffer = try allocator.alloc(u8, @intCast(stat.size));
    const read = try file.readAll(buffer);
    return buffer[0..read];
}

fn rollbackFile(path: []const u8, original: ?[]const u8) !void {
    if (original) |content| {
        var file = compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 }) catch return;
        defer file.close();
        file.writeAll(content) catch {};
    } else {
        compat.deleteFileAbsolute(path) catch {};
    }
}

fn appendOutput(output: *std.array_list.Managed(u8), text: []const u8) !void {
    if (text.len == 0) return;
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
        try output.append('\n');
    }
    try output.appendSlice(text);
}
