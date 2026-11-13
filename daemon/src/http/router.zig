const std = @import("std");
const request = @import("request.zig");
const context = @import("../api/context.zig");

pub const Handler = *const fn (*context.Context) anyerror!void;

pub const Route = struct {
    method: request.Method,
    pattern: []const u8,
    handler: Handler,
};

pub const Match = struct {
    handler: Handler,
    params: []const context.Param,
};

pub const Result = union(enum) {
    found: Match,
    method_not_allowed,
    not_found,
};

pub fn match(
    allocator: std.mem.Allocator,
    routes: []const Route,
    method: request.Method,
    raw_path: []const u8,
) !Result {
    const path = raw_path;
    var allowed = false;

    for (routes) |route| {
        const params = try matchPattern(allocator, route.pattern, path) orelse continue;
        if (route.method != method and !(method == .HEAD and route.method == .GET)) {
            allowed = true;
            continue;
        }
        return .{ .found = .{ .handler = route.handler, .params = params } };
    }

    return if (allowed) .method_not_allowed else .not_found;
}

fn matchPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
) !?[]context.Param {
    var pattern_it = std.mem.splitScalar(u8, std.mem.trim(u8, pattern, "/"), '/');
    var path_it = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');

    var params = std.array_list.Managed(context.Param).init(allocator);
    errdefer params.deinit();

    while (true) {
        const pattern_seg = pattern_it.next();
        const path_seg = path_it.next();

        if (pattern_seg == null and path_seg == null) break;
        if (pattern_seg == null or path_seg == null) return null;

        const p = pattern_seg.?;
        const actual = path_seg.?;

        if (p.len > 1 and p[0] == ':') {
            if (actual.len == 0) return null;
            try params.append(.{ .name = p[1..], .value = actual });
        } else if (!std.mem.eql(u8, p, actual)) {
            return null;
        }
    }

    return params.items;
}
