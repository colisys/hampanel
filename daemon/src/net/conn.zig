const std = @import("std");
const tls = @import("../tls.zig");
const os = @import("../openssl.zig");

pub const Conn = struct {
    ssl: *os.c.SSL,
    buf: [16384]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn init(ssl: *os.c.SSL) Conn {
        return .{ .ssl = ssl };
    }

    pub fn close(self: *Conn) void {
        tls.close(self.ssl);
    }

    fn available(self: *const Conn) usize {
        return self.end - self.start;
    }

    fn fill(self: *Conn) !usize {
        self.start = 0;
        self.end = 0;
        const n = try tls.read(self.ssl, &self.buf);
        self.end = n;
        return n;
    }

    pub fn read(self: *Conn, out: []u8) !usize {
        if (out.len == 0) return 0;
        if (self.available() == 0) {
            const n = try self.fill();
            if (n == 0) return 0;
        }
        const count = @min(out.len, self.available());
        @memcpy(out[0..count], self.buf[self.start .. self.start + count]);
        self.start += count;
        return count;
    }

    pub fn readFull(self: *Conn, out: []u8) !void {
        var offset: usize = 0;
        while (offset < out.len) {
            const n = try self.read(out[offset..]);
            if (n == 0) return error.EndOfStream;
            offset += n;
        }
    }

    pub fn readLine(self: *Conn, allocator: std.mem.Allocator, max: usize) ![]u8 {
        var line = std.ArrayList(u8).init(allocator);
        errdefer line.deinit();

        while (true) {
            if (self.available() == 0) {
                const n = try self.fill();
                if (n == 0) {
                    if (line.items.len == 0) return error.EndOfStream;
                    return error.UnexpectedEof;
                }
            }
            const slice = self.buf[self.start..self.end];
            if (std.mem.indexOfScalar(u8, slice, '\n')) |idx| {
                var chunk = slice[0..idx];
                if (chunk.len > 0 and chunk[chunk.len - 1] == '\r') chunk = chunk[0 .. chunk.len - 1];
                try line.appendSlice(chunk);
                self.start += idx + 1;
                if (line.items.len > max) return error.LineTooLong;
                return line.toOwnedSlice();
            }
            try line.appendSlice(slice);
            self.start = self.end;
            if (line.items.len > max) return error.LineTooLong;
        }
    }

    pub fn writeAll(self: *Conn, bytes: []const u8) !void {
        try tls.writeAll(self.ssl, bytes);
    }
};
