const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

const begin_marker = "# BEGIN HAMPANEL MANAGED";
const end_marker = "# END HAMPANEL MANAGED";
const id_marker = " # hampanel:";
/// Panel-owned jobs are tagged so the UI can list them separately and the
/// daemon can refuse to install an arbitrary command under that kind.
const panel_marker = " # hampanel-panel:";

pub const Entry = struct {
    id: []const u8,
    schedule: []const u8,
    command: []const u8,
    line: []const u8,
    /// "panel" for the curated jobs, "user" for free-form crontab entries.
    kind: []const u8,
};

pub const PanelJob = struct {
    id: []const u8,
    label: []const u8,
    group: []const u8,
    command: []const u8,
};

fn fixed(comptime id: []const u8, comptime group: []const u8, comptime label: []const u8, comptime argv: []const []const u8) PanelJob {
    comptime var command: []const u8 = "";
    inline for (argv, 0..) |arg, i| command = command ++ (if (i == 0) "" else " ") ++ arg;
    return .{ .id = id, .group = group, .label = label, .command = command };
}

pub const panel_jobs = [_]PanelJob{
    fixed("cert-renew", "Certbot 证书续签", "全部 Certbot 证书", &.{ "certbot", "renew", "--quiet" }),
    fixed("restart-nginx", "软件重启", "Nginx", &.{ "systemctl", "restart", "nginx.service" }),
    fixed("restart-caddy", "软件重启", "Caddy", &.{ "systemctl", "restart", "caddy.service" }),
    fixed("restart-mariadb", "软件重启", "MariaDB", &.{ "systemctl", "restart", "mariadb.service" }),
    fixed("supervisord-restart", "软件重启", "Supervisor", &.{ "systemctl", "restart", "supervisor" }),
    fixed("nginx-check", "维护检查", "检查 Nginx 配置", &.{ "nginx", "-t" }),
    fixed("disk-usage", "维护检查", "报告文件系统使用量", &.{ "df", "-hP" }),
};

// Cron stores a shell command, not argv. Only accept lineage names that
// remain exactly one literal argument in both cron and the shell.
fn certificateJob(a: std.mem.Allocator, name: []const u8) !?PanelJob {
    if (name.len == 0 or name.len > 253 or !std.ascii.isAlphanumeric(name[0])) return null;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return null;
    return .{ .id = try std.mem.concat(a, u8, &.{ "cert-renew:", name }), .group = panel_jobs[0].group, .label = try a.dupe(u8, name), .command = try std.mem.join(a, " ", &.{ "certbot", "renew", "--quiet", "--cert-name", name }) };
}

pub fn catalog(a: std.mem.Allocator) ![]const PanelJob {
    var dir = compat.openDirAbsolute("/etc/letsencrypt/renewal", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &panel_jobs,
        else => return err,
    };
    defer dir.close();
    var jobs = std.array_list.Managed(PanelJob).init(a);
    try jobs.appendSlice(&panel_jobs);
    var it = dir.iterate();
    while (try it.next()) |item| {
        if (item.kind != .file or !std.mem.endsWith(u8, item.name, ".conf")) continue;
        if (try certificateJob(a, item.name[0 .. item.name.len - 5])) |job| try jobs.append(job);
    }
    return jobs.items;
}

pub fn panelJobFor(command: []const u8) ?PanelJob {
    for (panel_jobs) |job| if (std.mem.eql(u8, job.command, command)) return job;
    return null;
}

test "restart commands are exact allowlisted argv" {
    try std.testing.expectEqualStrings("restart-nginx", panelJobFor("systemctl restart nginx.service").?.id);
    try std.testing.expect(panelJobFor("systemctl restart other.service") == null);
    try std.testing.expect(panelJobFor("systemctl restart nginx.service; true") == null);
}

test "certificate lineage becomes one literal argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const job = (try certificateJob(a, "example.org-0001")).?;
    try std.testing.expectEqualStrings("certbot renew --quiet --cert-name example.org-0001", job.command);
    for ([_][]const u8{ "", "--flag", "other site", "a;b", "a%b", "a/b", "a\nb" }) |name| try std.testing.expect((try certificateJob(a, name)) == null);
}

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn list(allocator: std.mem.Allocator) ![]Entry {
    const current = try readCrontab(allocator);
    return parseEntries(allocator, current);
}

pub fn add(
    allocator: std.mem.Allocator,
    schedule: []const u8,
    command: []const u8,
    kind: []const u8,
) !Outcome {
    const is_panel = std.mem.eql(u8, kind, "panel");
    if (is_panel) {
        for (try catalog(allocator)) |job| {
            if (std.mem.eql(u8, command, job.command)) break;
        } else return error.UnknownPanelJob;
    }
    const current = try readCrontab(allocator);
    var entries = std.array_list.Managed(Entry).init(allocator);
    for (try parseEntries(allocator, current)) |entry| try entries.append(entry);

    var random: [4]u8 = undefined;
    compat.randomBytes(&random);
    const id = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(random, .lower)});
    const marker = if (is_panel) panel_marker else id_marker;
    const line = try std.fmt.allocPrint(allocator, "{s} {s}{s}{s}", .{ schedule, command, marker, id });
    try entries.append(.{
        .id = id,
        .schedule = schedule,
        .command = command,
        .line = line,
        .kind = if (is_panel) "panel" else "user",
    });

    const rewritten = try rewrite(allocator, current, entries.items);
    const result = installCrontab(allocator, rewritten) catch return error.CrontabUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn remove(allocator: std.mem.Allocator, id: []const u8) !Outcome {
    const current = try readCrontab(allocator);
    var kept = std.array_list.Managed(Entry).init(allocator);
    var found = false;
    for (try parseEntries(allocator, current)) |entry| {
        if (std.mem.eql(u8, entry.id, id)) {
            found = true;
        } else {
            try kept.append(entry);
        }
    }
    if (!found) return error.JobNotFound;

    const rewritten = try rewrite(allocator, current, kept.items);
    const result = installCrontab(allocator, rewritten) catch return error.CrontabUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

fn readCrontab(allocator: std.mem.Allocator) ![]const u8 {
    const result = exec.run(allocator, &.{ "crontab", "-l" }, 1024 * 1024) catch return "";
    if (!result.ok()) return "";
    return result.stdout;
}

fn installCrontab(allocator: std.mem.Allocator, text: []const u8) !exec.Result {
    var random: [6]u8 = undefined;
    compat.randomBytes(&random);
    const path = try std.fmt.allocPrint(allocator, "/tmp/hampanel-cron-{s}", .{std.fmt.bytesToHex(random, .lower)});
    errdefer compat.deleteFileAbsolute(path) catch {};

    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    try file.writeAll(text);
    file.close();

    const result = try exec.run(allocator, &.{ "crontab", path }, 1024 * 1024);
    compat.deleteFileAbsolute(path) catch {};
    return result;
}

fn parseEntries(allocator: std.mem.Allocator, contents: []const u8) ![]Entry {
    var entries = std.array_list.Managed(Entry).init(allocator);
    var in_block = false;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, begin_marker)) {
            in_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, end_marker)) {
            in_block = false;
            continue;
        }
        if (!in_block or line.len == 0 or line[0] == '#') continue;

        const is_panel = std.mem.indexOf(u8, line, panel_marker) != null;
        const marker_at = std.mem.lastIndexOf(u8, line, if (is_panel) panel_marker else id_marker) orelse continue;
        const id = std.mem.trim(
            u8,
            line[marker_at + (if (is_panel) panel_marker.len else id_marker.len) ..],
            " \t",
        );
        if (id.len == 0) continue;
        const body = std.mem.trim(u8, line[0..marker_at], " \t");

        var tokens = std.array_list.Managed([]const u8).init(allocator);
        var it = std.mem.tokenizeAny(u8, body, " \t");
        while (it.next()) |token| try tokens.append(token);
        if (tokens.items.len < 2) continue;

        var schedule_end: usize = 0;
        if (tokens.items[0].len > 0 and tokens.items[0][0] == '@') {
            schedule_end = 1;
        } else {
            if (tokens.items.len < 6) continue;
            schedule_end = 5;
        }

        const schedule = try std.mem.join(allocator, " ", tokens.items[0..schedule_end]);
        // Preserve whitespace inside quoted shell arguments.
        const first = tokens.items[schedule_end];
        const command = body[@intFromPtr(first.ptr) - @intFromPtr(body.ptr) ..];
        if (command.len == 0) continue;

        try entries.append(.{
            .id = id,
            .schedule = schedule,
            .command = command,
            .line = line,
            .kind = if (is_panel) "panel" else "user",
        });
    }

    return entries.items;
}

fn rewrite(allocator: std.mem.Allocator, contents: []const u8, entries: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    var in_block = false;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, begin_marker)) {
            in_block = true;
            continue;
        }
        if (std.mem.eql(u8, line, end_marker)) {
            in_block = false;
            continue;
        }
        if (in_block) continue;
        try writer.writeAll(raw_line);
        try writer.writeAll("\n");
    }

    if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try writer.writeAll("\n");

    if (entries.len > 0) {
        try writer.writeAll(begin_marker);
        try writer.writeAll("\n");
        for (entries) |entry| {
            const marker = if (std.mem.eql(u8, entry.kind, "panel")) panel_marker else id_marker;
            try writer.print("{s} {s}{s}{s}\n", .{ entry.schedule, entry.command, marker, entry.id });
        }
        try writer.writeAll(end_marker);
        try writer.writeAll("\n");
    }

    return out.toOwnedSlice();
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
