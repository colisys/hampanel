const std = @import("std");

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Status = struct {
    swap_total_bytes: u64,
    swap_used_bytes: u64,
    swapfile_path: []const u8,
    swapfile_bytes: u64,
    swapfile_active: bool,
    ntp_enabled: bool,
    ntp_synchronized: bool,
    timezone: []const u8,
    hosts_content: []const u8,
    grub_default: []const u8,
    grub_entries: []const []const u8,
};

pub fn status(_: std.mem.Allocator) !Status {
    return error.Unsupported;
}

pub fn setSwap(_: std.mem.Allocator, _: u32) !Outcome {
    return error.Unsupported;
}

pub fn setNtp(_: std.mem.Allocator, _: bool) !Outcome {
    return error.Unsupported;
}

pub fn saveHosts(_: std.mem.Allocator, _: []const u8) !Outcome {
    return error.Unsupported;
}

pub fn setGrubDefault(_: std.mem.Allocator, _: usize) !Outcome {
    return error.Unsupported;
}
