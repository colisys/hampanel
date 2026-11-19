// Type-checks shared modules that contain Windows-specific branches but are not
// part of the platform backend. `zig build check-windows` only compiles the
// backend, so a broken Windows branch in these files would otherwise be caught
// for the first time by CI (a bad SOCKET cast once shipped that way).
const std = @import("std");
const socket_timeout = @import("net/socket_timeout.zig");
const exec = @import("sys/exec.zig");
const url = @import("util/url.zig");
const redact = @import("util/redact.zig");
const errors = @import("util/errors.zig");

comptime {
    _ = &socket_timeout.set;
    _ = &exec.run;
    _ = &exec.commandExists;
    _ = &url.decode;
    _ = &redact.text;
    _ = &errors.named;
}
