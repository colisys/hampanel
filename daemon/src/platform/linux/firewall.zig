const std = @import("std");
const exec = @import("shared").exec;

pub const Rule = struct {
    id: []const u8,
    to: []const u8,
    action: []const u8,
    from: []const u8,
    raw: []const u8,
};

pub const Status = struct {
    available: bool,
    active: bool,
    rules: []const Rule,
    output: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn status(allocator: std.mem.Allocator) !Status {
    const result = exec.run(allocator, &.{ "ufw", "status", "numbered" }, 1024 * 1024) catch {
        return .{ .available = false, .active = false, .rules = &.{}, .output = "ufw not installed" };
    };

    if (!result.ok()) {
        return .{ .available = false, .active = false, .rules = &.{}, .output = textOf(result) };
    }

    const active = std.mem.indexOf(u8, result.stdout, "Status: active") != null;
    var rules = std.array_list.Managed(Rule).init(allocator);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "[")) continue;
        const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const number = std.fmt.parseInt(u32, std.mem.trim(u8, line[1..close], " "), 10) catch continue;
        line = std.mem.trimStart(u8, line[close + 1 ..], " ");
        if (line.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const to = tokens.next() orelse continue;
        var action: []const u8 = "";
        var from: []const u8 = "";
        while (tokens.next()) |token| {
            if (action.len == 0 and (std.mem.eql(u8, token, "ALLOW") or
                std.mem.eql(u8, token, "DENY") or
                std.mem.eql(u8, token, "REJECT") or
                std.mem.eql(u8, token, "LIMIT")))
            {
                action = token;
                continue;
            }
            if (action.len > 0 and std.mem.eql(u8, token, "IN")) continue;
            if (action.len > 0 and from.len == 0) {
                from = token;
                break;
            }
        }
        if (from.len == 0) from = "Anywhere";

        try rules.append(.{
            .id = try std.fmt.allocPrint(allocator, "{d}", .{number}),
            .to = to,
            .action = action,
            .from = from,
            .raw = line,
        });
    }

    return .{
        .available = true,
        .active = active,
        .rules = rules.items,
        .output = result.stdout,
    };
}

pub fn add(
    allocator: std.mem.Allocator,
    action: []const u8,
    port: []const u8,
    from: []const u8,
    comment: []const u8,
) !Outcome {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append("ufw");
    if (comment.len > 0) {
        try argv.append("comment");
        try argv.append(comment);
    }
    try argv.append(action);

    if (from.len > 0) {
        try argv.append("from");
        try argv.append(from);
        try argv.append("to");
        try argv.append("any");
        try argv.append("port");

        var parts = std.mem.splitScalar(u8, port, '/');
        try argv.append(parts.next().?);
        if (parts.next()) |proto| {
            try argv.append("proto");
            try argv.append(proto);
        }
    } else {
        try argv.append(port);
    }

    const result = exec.run(allocator, argv.items, 1024 * 1024) catch
        return error.UfwUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn remove(allocator: std.mem.Allocator, id: []const u8) !Outcome {
    const number = std.fmt.parseInt(u32, id, 10) catch return error.InvalidRuleId;
    if (number == 0 or number > 100000) return error.InvalidRuleId;
    const number_raw = try std.fmt.allocPrint(allocator, "{d}", .{number});

    const result = exec.run(allocator, &.{ "ufw", "--force", "delete", number_raw }, 1024 * 1024) catch
        return error.UfwUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
