const std = @import("std");
const common = @import("common.zig");

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
    const script =
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" ++
        "$items=@(Get-Service | ForEach-Object { [pscustomobject]@{ unit=$_.Name; load='loaded'; " ++
        "active=$(if ($_.Status -eq 'Running') {'active'} else {'inactive'}); " ++
        "sub=$_.Status.ToString(); description=$_.DisplayName } });" ++
        "ConvertTo-Json -InputObject $items -Compress";

    const result = common.powershell(allocator, script, 8 * 1024 * 1024) catch
        return error.ServiceManagerUnavailable;
    if (!result.ok()) return error.ServiceManagerFailed;

    return parseServiceList(allocator, result.stdout);
}

fn parseServiceList(allocator: std.mem.Allocator, raw: []const u8) ![]Service {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\xEF\xBB\xBF");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return &.{};

    if (trimmed[0] == '[') {
        return std.json.parseFromSliceLeaky([]Service, allocator, trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch error.ServiceManagerOutput;
    }

    const single = std.json.parseFromSliceLeaky(Service, allocator, trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.ServiceManagerOutput;
    const items = try allocator.alloc(Service, 1);
    items[0] = single;
    return items;
}

pub fn action(allocator: std.mem.Allocator, unit: []const u8, action_name: []const u8) !Outcome {
    var quoted_buf: [512]u8 = undefined;
    const quoted = common.quotePowerShell(unit, &quoted_buf);

    const script = if (std.mem.eql(u8, action_name, "start"))
        try std.fmt.allocPrint(allocator, "$ErrorActionPreference='Stop';Start-Service -Name {s};'started'", .{quoted})
    else if (std.mem.eql(u8, action_name, "stop"))
        try std.fmt.allocPrint(allocator, "$ErrorActionPreference='Stop';Stop-Service -Name {s} -Force;'stopped'", .{quoted})
    else if (std.mem.eql(u8, action_name, "restart"))
        try std.fmt.allocPrint(allocator, "$ErrorActionPreference='Stop';Restart-Service -Name {s} -Force;'restarted'", .{quoted})
    else if (std.mem.eql(u8, action_name, "enable"))
        try std.fmt.allocPrint(allocator, "$ErrorActionPreference='Stop';Set-Service -Name {s} -StartupType Automatic;'enabled'", .{quoted})
    else if (std.mem.eql(u8, action_name, "disable"))
        try std.fmt.allocPrint(allocator, "$ErrorActionPreference='Stop';Set-Service -Name {s} -StartupType Disabled;'disabled'", .{quoted})
    else
        return error.Unsupported;

    const result = common.powershell(allocator, script, 1024 * 1024) catch
        return error.ServiceManagerUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn logs(allocator: std.mem.Allocator, unit: []const u8, lines: usize) ![]const u8 {
    const script = try std.fmt.allocPrint(
        allocator,
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" ++
            "$n={d}; Get-WinEvent -LogName System -MaxEvents 2000 -ErrorAction SilentlyContinue | " ++
            "Where-Object {{ $_.ProviderName -like '*{s}*' -or $_.Message -like '*{s}*' }} | " ++
            "Select-Object -First $n | Format-Table TimeCreated,ProviderName,Message -AutoSize | Out-String -Width 240",
        .{ lines, unit, unit },
    );
    const result = common.powershell(allocator, script, 4 * 1024 * 1024) catch
        return error.JournalUnavailable;
    if (!result.ok()) return error.JournalUnavailable;
    return result.stdout;
}

fn textOf(result: @import("shared").exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
