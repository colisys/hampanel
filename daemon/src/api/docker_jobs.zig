const std = @import("std");
const compat = @import("compat");
const context = @import("context.zig");
const jobs = @import("../jobs.zig");
const http_response = @import("../http/response.zig");

pub fn index(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const snapshot = jobs.get(ctx.arena, id) catch |err| {
        ctx.fail(500, "job_failed", @errorName(err));
        return;
    };
    const job = snapshot orelse {
        ctx.fail(404, "not_found", "job not found");
        return;
    };
    try ctx.json(job);
}

pub fn cancel(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const found = jobs.get(ctx.arena, id) catch null;
    if (found == null) {
        ctx.fail(404, "not_found", "job not found");
        return;
    }
    const cancelled = jobs.cancel(id);
    try ctx.json(.{ .ok = true, .cancelled = cancelled });
}

pub fn download(ctx: *context.Context) anyerror!void {
    const id = requireId(ctx) orelse return;
    const snapshot = jobs.get(ctx.arena, id) catch |err| {
        ctx.fail(500, "job_failed", @errorName(err));
        return;
    };
    const job = snapshot orelse {
        ctx.fail(404, "not_found", "job not found");
        return;
    };
    if (!std.mem.eql(u8, job.status, "succeeded")) {
        ctx.fail(409, "job_not_ready", "job has not finished successfully");
        return;
    }
    const path = job.result_path orelse {
        ctx.fail(404, "no_result", "job has no downloadable result");
        return;
    };

    const name = compat.path.basename(path);
    const disposition = try std.fmt.allocPrint(ctx.arena, "attachment; filename=\"{s}\"", .{name});
    const headers = try ctx.arena.alloc(http_response.Header, 1);
    headers[0] = .{ .name = "Content-Disposition", .value = disposition };
    ctx.response = .{
        .status = 200,
        .content_type = "application/octet-stream",
        .file_path = path,
        .extra = headers,
    };
}

fn requireId(ctx: *context.Context) ?[]const u8 {
    const id = ctx.param("id") orelse {
        ctx.fail(400, "bad_id", "missing job id");
        return null;
    };
    if (id.len == 0 or id.len > 64) {
        ctx.fail(400, "bad_id", "invalid job id");
        return null;
    }
    return id;
}
