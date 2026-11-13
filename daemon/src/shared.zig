const builtin = @import("builtin");

pub const types = @import("platform/types.zig");
pub const exec = @import("sys/exec.zig");
pub const validate = @import("util/validate.zig");
pub const procfs = if (builtin.os.tag == .linux) @import("sys/procfs.zig") else struct {};
