const std = @import("std");

pub const Status = struct {
    available: bool,
    active: bool,
    service: []const u8,
    version: []const u8,
    port: []const u8,
    permit_root_login: []const u8,
    password_authentication: []const u8,
    pubkey_authentication: []const u8,
    drop_in: []const u8,
    current_user: []const u8,
    message: []const u8,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Key = struct {
    index: usize,
    key_type: []const u8,
    comment: []const u8,
    key: []const u8,
};

pub fn status(allocator: std.mem.Allocator) !Status {
    _ = allocator;
    return .{
        .available = false,
        .active = false,
        .service = "",
        .version = "",
        .port = "",
        .permit_root_login = "",
        .password_authentication = "",
        .pubkey_authentication = "",
        .drop_in = "",
        .current_user = "",
        .message = "SSH management is only available on Linux",
    };
}

pub fn apply(
    allocator: std.mem.Allocator,
    port: u16,
    permit_root_login: []const u8,
    password_authentication: bool,
    pubkey_authentication: bool,
) !Outcome {
    _ = allocator;
    _ = port;
    _ = permit_root_login;
    _ = password_authentication;
    _ = pubkey_authentication;
    return error.Unsupported;
}

pub fn listKeys(allocator: std.mem.Allocator, username: []const u8) ![]Key {
    _ = allocator;
    _ = username;
    return error.Unsupported;
}

pub fn addKey(allocator: std.mem.Allocator, username: []const u8, raw_key: []const u8, comment: []const u8) !Outcome {
    _ = allocator;
    _ = username;
    _ = raw_key;
    _ = comment;
    return error.Unsupported;
}

pub fn removeKey(allocator: std.mem.Allocator, username: []const u8, index: usize) !Outcome {
    _ = allocator;
    _ = username;
    _ = index;
    return error.Unsupported;
}

pub const LoggingStatus = struct {
    mode: []const u8,
    file: []const u8,
    rsyslog_available: bool,
    rsyslog_service: []const u8,
    journal_available: bool,
    auth_log_path: []const u8,
    service: []const u8,
    message: []const u8,
};

pub const Logs = struct {
    source: []const u8,
    path: []const u8,
    truncated: bool,
    content: []const u8,
};

pub fn loggingStatus(allocator: std.mem.Allocator) !LoggingStatus {
    _ = allocator;
    return .{
        .mode = "syslog",
        .file = "",
        .rsyslog_available = false,
        .rsyslog_service = "",
        .journal_available = false,
        .auth_log_path = "",
        .service = "",
        .message = "SSH logging management is only available on Linux",
    };
}

pub fn setLogging(allocator: std.mem.Allocator, mode: []const u8) !Outcome {
    _ = allocator;
    _ = mode;
    return error.Unsupported;
}

pub fn logs(allocator: std.mem.Allocator, source: []const u8, lines: usize) !Logs {
    _ = allocator;
    _ = source;
    _ = lines;
    return error.Unsupported;
}
