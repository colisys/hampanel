const std = @import("std");
const compat = @import("compat");
const common = @import("common.zig");
const exec = @import("shared").exec;

pub const Rule = struct {
    id: []const u8,
    to: []const u8,
    action: []const u8,
    from: []const u8,
    raw: []const u8,
};

pub const Status = struct {
    available: bool,
    active: bool,
    rules: []const Rule,
    output: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const status_script =
    "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" ++
    "$rules=@(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction SilentlyContinue | " ++
    "Where-Object { $_.Enabled -eq 'True' } | ForEach-Object { " ++
    "$pf = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue; " ++
    "[pscustomobject]@{ id=$_.DisplayName; to=$(if ($pf.LocalPort) { $pf.LocalPort -join ',' } else { 'any' }); " ++
    "action=$_.Action.ToString(); from=$(if ($_.RemoteAddress) { $_.RemoteAddress -join ',' } else { 'any' }); " ++
    "raw=$_.DisplayName } });" ++
    "$profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue | " ++
    "Where-Object { $_.Enabled -eq 'True' });" ++
    "[pscustomobject]@{ active=($profiles.Count -gt 0); rules=$rules } | ConvertTo-Json -Compress -Depth 5";

pub fn status(allocator: std.mem.Allocator) !Status {
    const result = common.powershell(allocator, status_script, 8 * 1024 * 1024) catch {
        return .{ .available = false, .active = false, .rules = &.{}, .output = "PowerShell unavailable" };
    };

    if (!result.ok()) {
        return .{ .available = false, .active = false, .rules = &.{}, .output = textOf(result) };
    }

    const Parsed = struct {
        active: bool = false,
        rules: []const Rule = &.{},
    };
    const parsed = std.json.parseFromSliceLeaky(Parsed, allocator, std.mem.trim(u8, result.stdout, " \t\r\n\xEF\xBB\xBF"), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return .{ .available = true, .active = false, .rules = &.{}, .output = result.stdout };
    };

    return .{
        .available = true,
        .active = parsed.active,
        .rules = parsed.rules,
        .output = "",
    };
}

pub fn add(
    allocator: std.mem.Allocator,
    action_name: []const u8,
    port: []const u8,
    from: []const u8,
    comment: []const u8,
) !Outcome {
    var port_parts = std.mem.splitScalar(u8, port, '/');
    const port_number = port_parts.next() orelse return error.InvalidRule;
    const protocol = port_parts.next() orelse "tcp";

    var random: [2]u8 = undefined;
    compat.randomBytes(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);

    _ = comment;
    const display_name = try std.fmt.allocPrint(allocator, "Hampanel {s} {s} {s}", .{ action_name, port, suffix });

    var quoted_name_buf: [512]u8 = undefined;
    const quoted_name = common.quotePowerShell(display_name, &quoted_name_buf);

    const action = if (std.mem.eql(u8, action_name, "deny")) "Block" else "Allow";
    const proto = if (std.ascii.eqlIgnoreCase(protocol, "udp")) "UDP" else "TCP";

    var script: []const u8 = undefined;
    if (from.len > 0) {
        var quoted_from_buf: [256]u8 = undefined;
        const quoted_from = common.quotePowerShell(from, &quoted_from_buf);
        script = try std.fmt.allocPrint(
            allocator,
            "$ErrorActionPreference='Stop';" ++
                "New-NetFirewallRule -DisplayName {s} -Direction Inbound -Action {s} " ++
                "-Protocol {s} -LocalPort {s} -RemoteAddress {s} -Profile Any | Out-Null;'rule added'",
            .{ quoted_name, action, proto, port_number, quoted_from },
        );
    } else {
        script = try std.fmt.allocPrint(
            allocator,
            "$ErrorActionPreference='Stop';" ++
                "New-NetFirewallRule -DisplayName {s} -Direction Inbound -Action {s} " ++
                "-Protocol {s} -LocalPort {s} -Profile Any | Out-Null;'rule added'",
            .{ quoted_name, action, proto, port_number },
        );
    }

    const result = common.powershell(allocator, script, 1024 * 1024) catch
        return error.FirewallUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

pub fn remove(allocator: std.mem.Allocator, id: []const u8) !Outcome {
    var quoted_buf: [512]u8 = undefined;
    const quoted = common.quotePowerShell(id, &quoted_buf);
    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop';Remove-NetFirewallRule -DisplayName {s};'rule removed'",
        .{quoted},
    );

    const result = common.powershell(allocator, script, 1024 * 1024) catch
        return error.FirewallUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
