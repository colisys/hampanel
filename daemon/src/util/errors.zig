const std = @import("std");

const is_windows = @import("builtin").os.tag == .windows;

pub fn named(err: anyerror, name: []const u8) bool {
    return std.mem.eql(u8, @errorName(err), name);
}

pub fn isUnsupported(err: anyerror) bool {
    return named(err, "Unsupported");
}

pub fn isSiteNotFound(err: anyerror) bool {
    return named(err, "SiteNotFound");
}

pub fn isJobNotFound(err: anyerror) bool {
    return named(err, "JobNotFound");
}

pub fn isInvalidRuleId(err: anyerror) bool {
    return named(err, "InvalidRuleId");
}

pub fn platformName() []const u8 {
    return if (is_windows) "windows" else "linux";
}
