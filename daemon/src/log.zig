const std = @import("std");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

var current_level: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Level.info));

pub fn setLevelName(name: []const u8) void {
    const parsed: Level = if (std.mem.eql(u8, name, "debug"))
        .debug
    else if (std.mem.eql(u8, name, "warn"))
        .warn
    else if (std.mem.eql(u8, name, "error") or std.mem.eql(u8, name, "err"))
        .err
    else
        .info;
    current_level.store(@intFromEnum(parsed), .release);
}

pub fn enabled(level: Level) bool {
    return @intFromEnum(level) >= current_level.load(.acquire);
}

fn label(level: Level) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .err => "ERROR",
    };
}

fn timestamp(buf: []u8) []const u8 {
    const secs: u64 = @intCast(std.time.timestamp());
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch "0000-00-00T00:00:00Z";
}

pub fn write(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;
    var ts_buf: [32]u8 = undefined;
    const ts = timestamp(&ts_buf);
    std.debug.print("{s} {s} " ++ fmt ++ "\n", .{ ts, label(level) } ++ args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    write(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    write(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    write(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    write(.err, fmt, args);
}
