const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

const begin_marker = "# BEGIN HAMPANEL MANAGED";
const end_marker = "# END HAMPANEL MANAGED";
const id_marker = " # hampanel:";

pub const Entry = struct {
    id: []const u8,
    schedule: []const u8,
    command: []const u8,
    line: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn list(allocator: std.mem.Allocator) ![]Entry {
    const current = try readCrontab(allocator);
    return parseEntries(allocator, current);
}

pub fn add(allocator: std.mem.Allocator, schedule: []const u8, command: []const u8) !Outcome {
    const current = try readCrontab(allocator);
    var entries = std.array_list.Managed(Entry).init(allocator);
    for (try parseEntries(allocator, current)) |entry| try entries.append(entry);

    var random: [4]u8 = undefined;
    compat.randomBytes(&random);
    const id = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(random, .lower)});
    const line = try std.fmt.allocPrint(allocator, "{s} {s}{s}{s}", .{ schedule, command, id_marker, id });
    try entries.append(.{
        .id = id,
        .schedule = schedule,
        .command = command,
        .line = line,
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

        const marker_at = std.mem.lastIndexOf(u8, line, id_marker) orelse continue;
        const id = std.mem.trim(u8, line[marker_at + id_marker.len ..], " \t");
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
        const command = try std.mem.join(allocator, " ", tokens.items[schedule_end..]);
        if (command.len == 0) continue;

        try entries.append(.{
            .id = id,
            .schedule = schedule,
            .command = command,
            .line = line,
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
            try writer.print("{s} {s}{s}{s}\n", .{ entry.schedule, entry.command, id_marker, entry.id });
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
