const std = @import("std");
const exec = @import("shared").exec;

const max_output = 4 * 1024 * 1024;

pub const Service = struct {
    unit: []const u8,
    load: []const u8,
    active: []const u8,
    sub: []const u8,
    description: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub fn list(allocator: std.mem.Allocator) ![]Service {
    const result = exec.run(allocator, &.{
        "systemctl", "list-units", "--type=service", "--all", "--no-pager", "--no-legend", "--output=json",
    }, max_output) catch return error.ServiceManagerUnavailable;

    if (!result.ok()) return error.ServiceManagerFailed;

    return std.json.parseFromSliceLeaky([]Service, allocator, result.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.ServiceManagerOutput;
}

pub fn action(allocator: std.mem.Allocator, unit: []const u8, action_name: []const u8) !Outcome {
    const result = exec.run(allocator, &.{ "systemctl", action_name, unit }, 1024 * 1024) catch
        return error.ServiceManagerUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn logs(allocator: std.mem.Allocator, unit: []const u8, lines: usize) ![]const u8 {
    const lines_raw = try std.fmt.allocPrint(allocator, "{d}", .{lines});
    const result = exec.run(allocator, &.{
        "journalctl", "-u", unit, "-n", lines_raw, "--no-pager", "-o", "short-iso", "--utc",
    }, max_output) catch return error.JournalUnavailable;
    return result.stdout;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
