const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const version = @import("../version.zig");
const timeutil = @import("../util/time.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const info = platform.system.info(ctx.arena) catch |err| {
        ctx.fail(500, "system_failed", @errorName(err));
        return;
    };

    var ts_buf: [32]u8 = undefined;
    const Body = struct {
        hostname: []const u8,
        os: []const u8,
        kernel: []const u8,
        arch: []const u8,
        cpu_model: []const u8,
        cores: usize,
        uptime_seconds: u64,
        server_time: []const u8,
        panel_version: []const u8,
        protocol: u32,
        platform: []const u8,
    };

    try ctx.json(Body{
        .hostname = info.hostname,
        .os = info.os,
        .kernel = info.kernel,
        .arch = info.arch,
        .cpu_model = info.cpu_model,
        .cores = info.cores,
        .uptime_seconds = info.uptime_seconds,
        .server_time = timeutil.nowIso(&ts_buf),
        .panel_version = version.version,
        .protocol = version.protocol_version,
        .platform = @tagName(@import("builtin").os.tag),
    });
}
