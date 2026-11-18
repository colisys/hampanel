const std = @import("std");
const compat = @import("compat");

pub const Accounts = struct {
    users: std.AutoHashMap(u32, []const u8),
    groups: std.AutoHashMap(u32, []const u8),

    pub fn init(allocator: std.mem.Allocator) Accounts {
        return .{
            .users = std.AutoHashMap(u32, []const u8).init(allocator),
            .groups = std.AutoHashMap(u32, []const u8).init(allocator),
        };
    }

    pub fn user(self: Accounts, uid: u32) ?[]const u8 {
        return self.users.get(uid);
    }

    pub fn group(self: Accounts, gid: u32) ?[]const u8 {
        return self.groups.get(gid);
    }
};

pub fn load(allocator: std.mem.Allocator) !Accounts {
    var lookup = Accounts.init(allocator);

    const passwd = compat.cwd().readFileAlloc(allocator, "/etc/passwd", 1024 * 1024) catch "";
    var passwd_lines = std.mem.splitScalar(u8, passwd, '\n');
    while (passwd_lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid_raw = fields.next() orelse continue;
        const uid = std.fmt.parseInt(u32, uid_raw, 10) catch continue;
        try lookup.users.put(uid, try allocator.dupe(u8, name));
    }

    const groups = compat.cwd().readFileAlloc(allocator, "/etc/group", 1024 * 1024) catch "";
    var group_lines = std.mem.splitScalar(u8, groups, '\n');
    while (group_lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const gid_raw = fields.next() orelse continue;
        const gid = std.fmt.parseInt(u32, gid_raw, 10) catch continue;
        try lookup.groups.put(gid, try allocator.dupe(u8, name));
    }

    return lookup;
}
