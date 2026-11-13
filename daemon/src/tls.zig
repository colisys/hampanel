const std = @import("std");
const compat = @import("compat");
const os = @import("openssl.zig");
const c = os.c;
const log = @import("log.zig");

pub const Context = struct {
    ctx: *c.SSL_CTX,

    pub fn init(
        allocator: std.mem.Allocator,
        cert_path: []const u8,
        key_path: []const u8,
        ca_path: []const u8,
    ) !Context {
        const cert_z = try compat.dupeZ(allocator, cert_path);
        defer allocator.free(cert_z);
        const key_z = try compat.dupeZ(allocator, key_path);
        defer allocator.free(key_z);
        const ca_z = try compat.dupeZ(allocator, ca_path);
        defer allocator.free(ca_z);

        const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.TlsContext;
        errdefer c.SSL_CTX_free(ctx);

        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) return error.TlsConfig;
        // Constants from openssl/ssl.h; referenced numerically because cImport
        // cannot translate the SSL_OP_BIT macro in this OpenSSL version.
        const op_no_compression: u64 = 0x00020000;
        const op_no_renegotiation: u64 = 0x40000000;
        const op_cipher_server_preference: u64 = 0x00400000;
        _ = c.SSL_CTX_set_options(ctx, op_no_compression | op_no_renegotiation | op_cipher_server_preference);
        _ = c.SSL_CTX_set_mode(ctx, c.SSL_MODE_RELEASE_BUFFERS);

        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_z.ptr) != 1) return fail("load server certificate");
        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_z.ptr, c.SSL_FILETYPE_PEM) != 1) return fail("load server key");
        if (c.SSL_CTX_check_private_key(ctx) != 1) return fail("server key mismatch");
        if (c.SSL_CTX_load_verify_locations(ctx, ca_z.ptr, null) != 1) return fail("load client CA");

        const client_cas = c.SSL_load_client_CA_file(ca_z.ptr) orelse return fail("load client CA names");
        c.SSL_CTX_set_client_CA_list(ctx, client_cas);

        c.SSL_CTX_set_verify(
            ctx,
            c.SSL_VERIFY_PEER | c.SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
            null,
        );
        c.SSL_CTX_set_verify_depth(ctx, 4);
        _ = c.SSL_CTX_set_session_cache_mode(ctx, c.SSL_SESS_CACHE_SERVER);

        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Context) void {
        c.SSL_CTX_free(self.ctx);
    }

    pub fn accept(self: *Context, fd: std.posix.socket_t) !*c.SSL {
        const ssl = c.SSL_new(self.ctx) orelse return error.SslAlloc;
        errdefer c.SSL_free(ssl);
        if (c.SSL_set_fd(ssl, @intCast(fd)) != 1) return error.TlsSetup;
        c.SSL_set_accept_state(ssl);
        if (c.SSL_accept(ssl) != 1) {
            var err_buf: [256]u8 = undefined;
            log.debug("tls handshake rejected: {s}", .{os.lastError(&err_buf)});
            return error.TlsHandshake;
        }
        return ssl;
    }
};

fn fail(what: []const u8) error{TlsConfig} {
    var err_buf: [256]u8 = undefined;
    log.err("tls setup failed ({s}): {s}", .{ what, os.lastError(&err_buf) });
    return error.TlsConfig;
}

pub fn read(ssl: *c.SSL, buf: []u8) !usize {
    if (buf.len == 0) return 0;
    const n = c.SSL_read(ssl, buf.ptr, @intCast(@min(buf.len, 64 * 1024)));
    if (n > 0) return @intCast(n);
    const ssl_err = c.SSL_get_error(ssl, n);
    return switch (ssl_err) {
        c.SSL_ERROR_ZERO_RETURN => 0,
        c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => error.WouldBlock,
        c.SSL_ERROR_SYSCALL => error.Io,
        else => error.Io,
    };
}

pub fn writeAll(ssl: *c.SSL, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk = @min(bytes.len - offset, 64 * 1024);
        const n = c.SSL_write(ssl, bytes.ptr + offset, @intCast(chunk));
        if (n <= 0) {
            const ssl_err = c.SSL_get_error(ssl, n);
            if (ssl_err == c.SSL_ERROR_WANT_WRITE or ssl_err == c.SSL_ERROR_WANT_READ) continue;
            return error.Io;
        }
        offset += @intCast(n);
    }
}

pub const PeerIdentity = struct {
    cn_buf: [256]u8 = undefined,
    cn_len: usize = 0,

    pub fn cn(self: *const PeerIdentity) []const u8 {
        return self.cn_buf[0..self.cn_len];
    }
};

pub fn peerIdentity(ssl: *c.SSL) !PeerIdentity {
    var identity = PeerIdentity{};
    const cert = c.SSL_get1_peer_certificate(ssl) orelse return error.NoPeerCertificate;
    defer c.X509_free(cert);
    const name = c.X509_get_subject_name(cert);
    const n = c.X509_NAME_get_text_by_NID(
        name,
        c.NID_commonName,
        &identity.cn_buf,
        identity.cn_buf.len,
    );
    if (n <= 0) return error.NoCommonName;
    identity.cn_len = @intCast(n);
    return identity;
}

pub fn close(ssl: *c.SSL) void {
    _ = c.SSL_shutdown(ssl);
    c.SSL_free(ssl);
}
