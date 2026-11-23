const std = @import("std");
const compat = @import("compat");
const common = @import("common.zig");
const exec = @import("shared").exec;

pub const Entry = struct {
    id: []const u8,
    schedule: []const u8,
    command: []const u8,
    line: []const u8,
    kind: []const u8 = "user",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const PanelJob = struct {
    id: []const u8,
    label: []const u8,
    command: []const u8,
};

/// Windows has no panel-scheduled jobs; the curated commands only exist for the
/// Linux systemd timer. The list stays empty so the API reports the same shape.
pub const panel_jobs = [_]PanelJob{};

pub fn panelJobFor(command: []const u8) ?PanelJob {
    for (panel_jobs) |job| {
        if (std.mem.eql(u8, job.command, command)) return job;
    }
    return null;
}

pub fn catalog(_: std.mem.Allocator) ![]const PanelJob {
    return &panel_jobs;
}

const task_path = "\\Hampanel\\";

pub fn list(allocator: std.mem.Allocator) ![]Entry {
    const script =
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" ++
        "$items=@(Get-ScheduledTask -TaskPath '\\Hampanel\\*' -ErrorAction SilentlyContinue | ForEach-Object { " ++
        "$a=$_.Actions | Select-Object -First 1; " ++
        "[pscustomobject]@{ id=$_.TaskName; schedule=($_.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','; " ++
        "command=((\"{0} {1}\" -f $a.Execute, $a.Arguments).Trim()); line=$_.TaskName } });" ++
        "ConvertTo-Json -InputObject $items -Compress";

    const result = common.powershell(allocator, script, 4 * 1024 * 1024) catch
        return error.SchedulerUnavailable;
    if (!result.ok()) return error.SchedulerFailed;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n\xEF\xBB\xBF");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return &.{};
    if (trimmed[0] == '[') {
        return std.json.parseFromSliceLeaky([]Entry, allocator, trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch error.SchedulerOutput;
    }

    const single = std.json.parseFromSliceLeaky(Entry, allocator, trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.SchedulerOutput;
    const items = try allocator.alloc(Entry, 1);
    items[0] = single;
    return items;
}

pub fn add(
    allocator: std.mem.Allocator,
    schedule: []const u8,
    command: []const u8,
    kind: []const u8,
) !Outcome {
    if (std.mem.eql(u8, kind, "panel")) return error.UnknownPanelJob;
    const parsed = translateSchedule(allocator, schedule) catch return error.Unsupported;

    var random: [4]u8 = undefined;
    compat.randomBytes(&random);
    const id = std.fmt.bytesToHex(random, .lower);
    const task_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ task_path, id });
    const task_run = try std.fmt.allocPrint(allocator, "cmd.exe /c {s}", .{command});

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ "schtasks.exe", "/Create", "/F", "/TN", task_name, "/TR", task_run });
    try argv.appendSlice(parsed.args);

    const result = exec.run(allocator, argv.items, 1024 * 1024) catch
        return error.SchedulerUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn remove(allocator: std.mem.Allocator, id: []const u8) !Outcome {
    const task_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ task_path, id });
    const result = exec.run(allocator, &.{ "schtasks.exe", "/Delete", "/F", "/TN", task_name }, 1024 * 1024) catch
        return error.SchedulerUnavailable;
    if (!result.ok()) return error.JobNotFound;
    return .{ .ok = true, .output = textOf(result) };
}

const ScheduleArgs = struct {
    args: []const []const u8,
};

fn translateSchedule(allocator: std.mem.Allocator, schedule: []const u8) !ScheduleArgs {
    if (std.mem.eql(u8, schedule, "@daily") or std.mem.eql(u8, schedule, "@midnight")) {
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "DAILY", "/ST", "00:00" }) };
    }
    if (std.mem.eql(u8, schedule, "@hourly")) {
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "HOURLY", "/MO", "1" }) };
    }
    if (std.mem.eql(u8, schedule, "@weekly")) {
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "WEEKLY", "/D", "SUN", "/ST", "00:00" }) };
    }
    if (std.mem.eql(u8, schedule, "@monthly")) {
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "MONTHLY", "/D", "1", "/ST", "00:00" }) };
    }

    var fields: [5][]const u8 = undefined;
    var it = std.mem.tokenizeAny(u8, schedule, " \t");
    var count: usize = 0;
    while (it.next()) |token| {
        if (count >= 5) return error.Unsupported;
        fields[count] = token;
        count += 1;
    }
    if (count != 5) return error.Unsupported;

    const minute = fields[0];
    const hour = fields[1];
    const dom = fields[2];
    const month = fields[3];
    const dow = fields[4];

    if (minute.len > 2 and std.mem.startsWith(u8, minute, "*/") and std.mem.eql(u8, hour, "*")) {
        const step = std.fmt.parseInt(u16, minute[2..], 10) catch return error.Unsupported;
        if (step == 0 or step > 59) return error.Unsupported;
        const step_raw = try std.fmt.allocPrint(allocator, "{d}", .{step});
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "MINUTE", "/MO", step_raw }) };
    }

    if (std.mem.eql(u8, minute, "*") and std.mem.eql(u8, hour, "*")) {
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "MINUTE", "/MO", "1" }) };
    }

    const minute_value = std.fmt.parseInt(u8, minute, 10) catch return error.Unsupported;
    if (minute_value > 59) return error.Unsupported;

    if (std.mem.eql(u8, hour, "*") and std.mem.eql(u8, dom, "*") and std.mem.eql(u8, month, "*") and std.mem.eql(u8, dow, "*")) {
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "HOURLY", "/MO", "1" }) };
    }

    const hour_value = std.fmt.parseInt(u8, hour, 10) catch return error.Unsupported;
    if (hour_value > 23) return error.Unsupported;
    const time = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hour_value, minute_value });

    if (std.mem.eql(u8, dom, "*") and std.mem.eql(u8, month, "*") and std.mem.eql(u8, dow, "*")) {
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "DAILY", "/ST", time }) };
    }

    if (std.mem.eql(u8, dom, "*") and std.mem.eql(u8, month, "*") and !std.mem.eql(u8, dow, "*")) {
        const day = weekdayName(dow) orelse return error.Unsupported;
        return .{ .args = try allocator.dupe([]const u8, &.{ "/SC", "WEEKLY", "/D", day, "/ST", time }) };
    }

    return error.Unsupported;
}

fn weekdayName(raw: []const u8) ?[]const u8 {
    const index = std.fmt.parseInt(u8, raw, 10) catch return null;
    return switch (index % 7) {
        0 => "SUN",
        1 => "MON",
        2 => "TUE",
        3 => "WED",
        4 => "THU",
        5 => "FRI",
        6 => "SAT",
        else => null,
    };
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
