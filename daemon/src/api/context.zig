const std = @import("std");
const app_mod = @import("../app.zig");
const request = @import("../http/request.zig");
const response = @import("../http/response.zig");
const Conn = @import("../net/conn.zig").Conn;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Context = struct {
    app: *app_mod.App,
    conn: *Conn,
    req: request.Request,
    params: []const Param,
    arena: std.mem.Allocator,
    peer_cn: []const u8,
    response: response.Response = .{},
    hijacked: bool = false,
    sent: bool = false,

    pub fn param(self: *Context, name: []const u8) ?[]const u8 {
        for (self.params) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn query(self: *Context, name: []const u8) !?[]u8 {
        return self.req.queryValue(self.arena, name);
    }

    pub fn json(self: *Context, value: anytype) !void {
        try self.jsonStatus(200, value);
    }

    pub fn jsonStatus(self: *Context, status: u16, value: anytype) !void {
        self.response.status = status;
        self.response.content_type = "application/json";
        self.response.body = try std.json.Stringify.valueAlloc(self.arena, value, .{});
    }

    pub fn empty(self: *Context, status: u16) void {
        self.response.status = status;
        self.response.body = "";
        self.response.content_type = "application/json";
    }

    pub fn fail(self: *Context, status: u16, code: []const u8, message: []const u8) void {
        const Body = struct { code: []const u8, message: []const u8 };
        const body = std.json.Stringify.valueAlloc(self.arena, Body{ .code = code, .message = message }, .{}) catch
            "{\"code\":\"internal\",\"message\":\"out of memory\"}";
        self.response = .{
            .status = status,
            .content_type = "application/json",
            .body = body,
        };
    }

    pub fn requireJson(self: *Context, comptime T: type) !T {
        if (self.req.body.len == 0) return error.MissingBody;
        return std.json.parseFromSliceLeaky(T, self.arena, self.req.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};
