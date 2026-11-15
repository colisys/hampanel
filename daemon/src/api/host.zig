const std = @import("std");
const context = @import("context.zig");
const platform = @import("../platform/mod.zig");
const log = @import("../log.zig");

pub fn settings(ctx: *context.Context) anyerror!void {
    const status = platform.host_settings.status(ctx.arena) catch |err| {
        fail(ctx, err);
        return;
    };
    try ctx.json(status);
}

pub fn swap(ctx: *context.Context) anyerror!void {
    const Body = struct { size_mb: u32 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected size_mb (0 disables the swap file)");
        return;
    };
    const outcome = platform.host_settings.setSwap(ctx.arena, body.size_mb) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("host: swap size_mb={d} ok={}", .{ body.size_mb, outcome.ok });
    try ctx.json(outcome);
}

pub fn swapDevice(ctx: *context.Context) anyerror!void {
    const Body = struct { device: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected device path");
        return;
    };
    const outcome = platform.host_settings.enableSwapDevice(ctx.arena, body.device) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("host: swap device={s} ok={}", .{ body.device, outcome.ok });
    try ctx.json(outcome);
}

pub fn ntp(ctx: *context.Context) anyerror!void {
    const Body = struct { enabled: bool };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected enabled boolean");
        return;
    };
    const outcome = platform.host_settings.setNtp(ctx.arena, body.enabled) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("host: ntp enabled={} ok={}", .{ body.enabled, outcome.ok });
    try ctx.json(outcome);
}

pub fn hosts(ctx: *context.Context) anyerror!void {
    const Body = struct { content: []const u8 };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected content");
        return;
    };
    const outcome = platform.host_settings.saveHosts(ctx.arena, body.content) catch |err| {
        fail(ctx, err);
        return;
    };
    log.info("host: /etc/hosts saved bytes={d}", .{body.content.len});
    try ctx.json(outcome);
}

pub fn grub(ctx: *context.Context) anyerror!void {
    const Body = struct { index: usize };
    const body = ctx.requireJson(Body) catch {
        ctx.fail(400, "bad_request", "expected index");
        return;
    };
    const outcome = platform.host_settings.setGrubDefault(ctx.arena, body.index) catch |err| {
        fail(ctx, err);
        return;
    };
    if (!outcome.ok) ctx.response.status = 502;
    log.info("host: grub default index={d} ok={}", .{ body.index, outcome.ok });
    try ctx.json(outcome);
}

fn fail(ctx: *context.Context, err: anyerror) void {
    switch (err) {
        error.Unsupported => ctx.fail(501, "unsupported", "该功能在当前平台不可用"),
        error.InvalidSize => ctx.fail(400, "bad_size", "交换文件大小需在 64 MiB 到 64 GiB 之间"),
        error.InvalidDevice => ctx.fail(400, "bad_device", "设备路径必须是 /dev/ 下的块设备"),
        error.InvalidEntry => ctx.fail(400, "bad_entry", "启动项索引超出范围"),
        error.ContentTooLarge => ctx.fail(400, "too_large", "hosts 内容过大"),
        error.InvalidContent => ctx.fail(400, "bad_content", "hosts 内容包含非法字符"),
        error.GrubUnavailable => ctx.fail(409, "grub_unavailable", "未找到 GRUB 配置"),
        error.TimeSyncUnavailable => ctx.fail(501, "timedatectl_unavailable", "timedatectl 不可用"),
        error.ToolMissing => ctx.fail(501, "tool_missing", "缺少 mkfs/swap 等系统工具"),
        else => ctx.fail(500, "host_failed", @errorName(err)),
    }
}
