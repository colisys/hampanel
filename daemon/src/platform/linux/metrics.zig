const std = @import("std");
const procfs = @import("shared").procfs;

pub const State = procfs.Sampler;

pub fn sample(allocator: std.mem.Allocator, state: *State) !procfs.Metrics {
    return procfs.sample(allocator, state);
}
