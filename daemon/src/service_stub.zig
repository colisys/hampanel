pub const ServeFn = *const fn () anyerror!void;

pub fn run(serve: ServeFn) !void {
    _ = serve;
    return error.Unsupported;
}
