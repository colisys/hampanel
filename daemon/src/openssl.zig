const std = @import("std");

pub const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/x509v3.h");
    @cInclude("openssl/buffer.h");
    @cInclude("openssl/rand.h");
});

pub fn lastError(buf: []u8) []const u8 {
    const code = c.ERR_get_error();
    if (code == 0) return "no OpenSSL error queued";
    c.ERR_error_string_n(code, buf.ptr, buf.len);
    return std.mem.sliceTo(buf, 0);
}
