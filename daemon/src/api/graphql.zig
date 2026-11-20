const std = @import("std");
const Context = @import("context.zig").Context;
const platform = @import("../platform/mod.zig");

const Field = enum { __typename, hostname, arch, cores, os, kernel, cpu_model, uptime_seconds };
const Selection = struct {
    typename: bool = false,
    system: bool = false,
    fields: std.EnumSet(Field) = .{},
};

const Parser = struct {
    rest: []const u8,

    fn skip(p: *Parser) void {
        p.rest = std.mem.trimStart(u8, p.rest, " \t\r\n,");
    }

    fn eat(p: *Parser, c: u8) bool {
        p.skip();
        if (p.rest.len == 0 or p.rest[0] != c) return false;
        p.rest = p.rest[1..];
        return true;
    }

    fn name(p: *Parser) ![]const u8 {
        p.skip();
        if (p.rest.len == 0 or !(std.ascii.isAlphabetic(p.rest[0]) or p.rest[0] == '_')) return error.ExpectedName;
        var n: usize = 1;
        while (n < p.rest.len and (std.ascii.isAlphanumeric(p.rest[n]) or p.rest[n] == '_')) n += 1;
        const result = p.rest[0..n];
        p.rest = p.rest[n..];
        return result;
    }
};

fn parse(query: []const u8) !Selection {
    if (query.len > 4096) return error.QueryTooLong;
    var p = Parser{ .rest = query };
    if (!p.eat('{')) {
        if (!std.mem.eql(u8, try p.name(), "query")) return error.OnlyQueriesSupported;
        if (!p.eat('{')) {
            _ = try p.name();
            if (!p.eat('{')) return error.ExpectedSelection;
        }
    }
    var result = Selection{};
    while (!p.eat('}')) {
        const root = try p.name();
        if (std.mem.eql(u8, root, "__typename")) {
            if (result.typename) return error.DuplicateField;
            result.typename = true;
        } else if (std.mem.eql(u8, root, "system")) {
            if (result.system) return error.DuplicateField;
            result.system = true;
            if (!p.eat('{')) return error.ExpectedSelection;
            while (!p.eat('}')) {
                const field = std.meta.stringToEnum(Field, try p.name()) orelse return error.UnknownSystemField;
                if (result.fields.contains(field)) return error.DuplicateField;
                result.fields.insert(field);
            }
            if (result.fields.count() == 0) return error.EmptySelection;
        } else return error.UnknownQueryField;
    }
    if (!result.typename and result.fields.count() == 0) return error.EmptySelection;
    p.skip();
    if (p.rest.len != 0) return error.TrailingInput;
    return result;
}

fn failure(ctx: *Context, status: u16, message: []const u8) !void {
    try ctx.jsonStatus(status, .{ .errors = .{.{ .message = message }} });
}

pub fn index(ctx: *Context) !void {
    if (ctx.req.body.len > 16384) return failure(ctx, 413, "Request too large");
    const body = std.json.parseFromSliceLeaky(struct { query: std.json.Value }, ctx.arena, ctx.req.body, .{}) catch return failure(ctx, 400, "Expected a JSON object containing only query");
    if (body.query != .string) return failure(ctx, 400, "Expected a query string");
    const plan = parse(body.query.string) catch |err| return failure(ctx, 400, @errorName(err));
    var data = std.json.Value{ .object = .empty };
    if (plan.typename) try data.object.put(ctx.arena, "__typename", .{ .string = "Query" });
    if (plan.fields.count() != 0) {
        var system = std.json.Value{ .object = .empty };
        if (plan.fields.contains(.__typename)) try system.object.put(ctx.arena, "__typename", .{ .string = "System" });
        if (plan.fields.count() > @as(usize, @intFromBool(plan.fields.contains(.__typename)))) {
            const info = platform.system.info(ctx.arena) catch return failure(ctx, 500, "System information unavailable");
            inline for (comptime std.meta.tags(Field)) |f| {
                if (f != .__typename and plan.fields.contains(f)) {
                    const value = @field(info, @tagName(f));
                    try system.object.put(ctx.arena, @tagName(f), switch (f) {
                        .cores, .uptime_seconds => .{ .integer = @intCast(value) },
                        else => .{ .string = value },
                    });
                }
            }
        }
        try data.object.put(ctx.arena, "system", system);
    }
    try ctx.json(.{ .data = data });
}

test "bounded system selection" {
    const plan = try parse("query Snapshot {system { hostname, arch\ncores } __typename}");
    try std.testing.expect(plan.typename and plan.fields.count() == 3 and plan.fields.contains(.cores));
    var long_query: [4097]u8 = undefined;
    @memset(&long_query, ' ');
    try std.testing.expectError(error.QueryTooLong, parse(&long_query));
}

test "unsupported documents are rejected in full" {
    for ([_][]const u8{ "{}", "{system}", "{system{}}", "{system{__typename} system{cores}}", "{system{hostname2}}", "{system{cores}", "{system{cores{a}}}", "{system{cores cores}}", "mutation {system{cores}}", "{alias:system{cores}}", "query X($a:Int){__typename}", "{system(arg:1){cores}}", "{__typename @skip}", "{...F}", "{__schema}", "{__typename}{__typename}", "{__typename}!" }) |query| {
        if (parse(query)) |_| return error.ExpectedRejection else |_| {}
    }
}
