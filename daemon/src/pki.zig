const std = @import("std");
const os = @import("openssl.zig");
const c = os.c;
const log = @import("log.zig");
const timeutil = @import("util/time.zig");
const files = @import("platform/mod.zig").files;

pub const Meta = struct {
    created_at: []const u8,
    endpoint: []const u8,
    ca_fingerprint: []const u8,
    server_fingerprint: []const u8,
    client_cn: []const u8,
};

pub const Paths = struct {
    dir: []const u8,
    ca_cert: []const u8,
    ca_key: []const u8,
    server_cert: []const u8,
    server_key: []const u8,
    client_cert: []const u8,
    client_key: []const u8,
    meta: []const u8,
};

pub const Issued = struct {
    cert: *c.X509,
    key: *c.EVP_PKEY,
    cert_pem: []u8,
    key_pem: []u8,
    fingerprint: [64]u8,

    pub fn deinit(self: *Issued, allocator: std.mem.Allocator) void {
        c.X509_free(self.cert);
        c.EVP_PKEY_free(self.key);
        allocator.free(self.cert_pem);
        allocator.free(self.key_pem);
    }
};

fn join(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ dir, name });
}

pub fn paths(allocator: std.mem.Allocator, dir: []const u8) !Paths {
    return .{
        .dir = dir,
        .ca_cert = try join(allocator, dir, "ca.crt.pem"),
        .ca_key = try join(allocator, dir, "ca.key.pem"),
        .server_cert = try join(allocator, dir, "server.crt.pem"),
        .server_key = try join(allocator, dir, "server.key.pem"),
        .client_cert = try join(allocator, dir, "client.crt.pem"),
        .client_key = try join(allocator, dir, "client.key.pem"),
        .meta = try join(allocator, dir, "pki.json"),
    };
}

pub fn exists(allocator: std.mem.Allocator, dir: []const u8) bool {
    const p = paths(allocator, dir) catch return false;
    const required = [_][]const u8{
        p.ca_cert, p.ca_key, p.server_cert, p.server_key, p.client_cert, p.client_key, p.meta,
    };
    for (required) |path| {
        std.fs.cwd().access(path, .{}) catch return false;
    }
    return true;
}

pub fn loadMeta(allocator: std.mem.Allocator, paths_in: Paths) !Meta {
    const raw = try std.fs.cwd().readFileAlloc(allocator, paths_in.meta, 1024 * 1024);
    return std.json.parseFromSliceLeaky(Meta, allocator, raw, .{ .allocate = .alloc_always });
}

fn randomClientCn(allocator: std.mem.Allocator) ![]const u8 {
    var raw: [6]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(allocator, "hampanel-client-{s}", .{hex});
}

pub fn initialize(
    allocator: std.mem.Allocator,
    dir: []const u8,
    endpoint: []const u8,
    sans: []const []const u8,
    force: bool,
) !Meta {
    const p = try paths(allocator, dir);

    if (!force and exists(allocator, dir)) {
        log.info("reusing existing PKI in {s}", .{dir});
        return loadMeta(allocator, p);
    }

    try std.fs.cwd().makePath(dir);
    try files.secureDir(dir);

    var ca = try issueAuthority(allocator);
    defer ca.deinit(allocator);

    var server = try issueLeaf(allocator, ca.cert, ca.key, "hampanel-server", sans, true);
    defer server.deinit(allocator);

    const client_cn = try randomClientCn(allocator);
    var client = try issueLeaf(allocator, ca.cert, ca.key, client_cn, &.{}, false);
    defer client.deinit(allocator);

    try writeFile(p.ca_key, ca.key_pem, 0o600);
    try writeFile(p.ca_cert, ca.cert_pem, 0o644);
    try writeFile(p.server_key, server.key_pem, 0o600);
    try writeFile(p.server_cert, server.cert_pem, 0o644);
    try writeFile(p.client_key, client.key_pem, 0o600);
    try writeFile(p.client_cert, client.cert_pem, 0o644);

    var ts_buf: [32]u8 = undefined;
    const meta = Meta{
        .created_at = try allocator.dupe(u8, timeutil.nowIso(&ts_buf)),
        .endpoint = try allocator.dupe(u8, endpoint),
        .ca_fingerprint = try allocator.dupe(u8, &ca.fingerprint),
        .server_fingerprint = try allocator.dupe(u8, &server.fingerprint),
        .client_cn = try allocator.dupe(u8, client_cn),
    };

    const meta_json = try std.json.stringifyAlloc(allocator, meta, .{ .whitespace = .indent_2 });
    try writeFile(p.meta, meta_json, 0o600);

    log.info("PKI ready: CA {s}", .{meta.ca_fingerprint});
    return meta;
}

fn writeFile(path: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    var file = try std.fs.cwd().createFile(path, .{ .mode = mode, .truncate = true });
    defer file.close();
    try files.secureFile(file, mode);
    try file.writeAll(data);
}

fn newEcKey() !*c.EVP_PKEY {
    const key_ctx = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_EC, null) orelse return error.Keygen;
    defer c.EVP_PKEY_CTX_free(key_ctx);
    if (c.EVP_PKEY_keygen_init(key_ctx) <= 0) return error.Keygen;
    if (c.EVP_PKEY_CTX_set_ec_paramgen_curve_nid(key_ctx, c.NID_X9_62_prime256v1) <= 0) return error.Keygen;
    var key: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_keygen(key_ctx, &key) <= 0) return error.Keygen;
    return key orelse error.Keygen;
}

fn newCert(subject_cn: []const u8, issuer: *c.X509, pubkey: *c.EVP_PKEY) !*c.X509 {
    const cert = c.X509_new() orelse return error.CertAlloc;
    errdefer c.X509_free(cert);

    if (c.X509_set_version(cert, 2) != 1) return error.CertInit;

    var raw_serial: [8]u8 = undefined;
    std.crypto.random.bytes(&raw_serial);
    const serial: c_long = @intCast(std.mem.readInt(u64, &raw_serial, .little) & 0x7fff_ffff_ffff_ffff);
    if (c.ASN1_INTEGER_set(c.X509_get_serialNumber(cert), serial) != 1) return error.CertInit;

    const name = c.X509_get_subject_name(cert);
    if (c.X509_NAME_add_entry_by_txt(name, "O", c.MBSTRING_UTF8, "Hampanel".ptr, "Hampanel".len, -1, 0) != 1) return error.CertInit;
    if (c.X509_NAME_add_entry_by_txt(name, "CN", c.MBSTRING_UTF8, subject_cn.ptr, @intCast(subject_cn.len), -1, 0) != 1) return error.CertInit;
    if (c.X509_set_issuer_name(cert, c.X509_get_subject_name(issuer)) != 1) return error.CertInit;
    if (c.X509_set_pubkey(cert, pubkey) != 1) return error.CertInit;
    if (c.X509_gmtime_adj(@constCast(c.X509_get0_notBefore(cert)), 0) == null) return error.CertInit;

    return cert;
}

fn addExtension(cert: *c.X509, issuer: *c.X509, nid: c_int, value: [:0]const u8) !void {
    var ctx: c.X509V3_CTX = undefined;
    ctx.db = null;
    c.X509V3_set_ctx(&ctx, issuer, cert, null, null, 0);
    const ext = c.X509V3_EXT_conf_nid(null, &ctx, nid, value.ptr) orelse {
        var err_buf: [256]u8 = undefined;
        log.err("extension [nid {d}] failed: {s}", .{ nid, os.lastError(&err_buf) });
        return error.Extension;
    };
    defer c.X509_EXTENSION_free(ext);
    if (c.X509_add_ext(cert, ext, -1) != 1) return error.Extension;
}

fn setValidity(cert: *c.X509, days: c_long) !void {
    if (c.X509_gmtime_adj(@constCast(c.X509_get0_notBefore(cert)), 0) == null) return error.Validity;
    if (c.X509_gmtime_adj(@constCast(c.X509_get0_notAfter(cert)), days * 86400) == null) return error.Validity;
}

fn sign(cert: *c.X509, key: *c.EVP_PKEY) !void {
    if (c.X509_sign(cert, key, c.EVP_sha256()) <= 0) {
        var err_buf: [256]u8 = undefined;
        log.err("certificate signing failed: {s}", .{os.lastError(&err_buf)});
        return error.Sign;
    }
}

fn issueAuthority(allocator: std.mem.Allocator) !Issued {
    return issueAuthorityExport(allocator);
}

pub fn issueLeaf(
    allocator: std.mem.Allocator,
    ca_cert: *c.X509,
    ca_key: *c.EVP_PKEY,
    common_name: []const u8,
    sans: []const []const u8,
    server_cert: bool,
) !Issued {
    const key = try newEcKey();
    errdefer c.EVP_PKEY_free(key);

    const cert = try newCert(common_name, ca_cert, key);
    errdefer c.X509_free(cert);

    try addExtension(cert, ca_cert, c.NID_basic_constraints, "critical,CA:FALSE");
    try addExtension(cert, ca_cert, c.NID_key_usage, "critical,digitalSignature");
    try addExtension(cert, ca_cert, c.NID_authority_key_identifier, "keyid:always");
    try addExtension(cert, ca_cert, c.NID_subject_key_identifier, "hash");

    if (server_cert) {
        try addExtension(cert, ca_cert, c.NID_ext_key_usage, "serverAuth");
        const san = try buildSan(allocator, sans);
        defer allocator.free(san);
        try addExtension(cert, ca_cert, c.NID_subject_alt_name, san);
        try setValidity(cert, 825);
    } else {
        try addExtension(cert, ca_cert, c.NID_ext_key_usage, "clientAuth");
        try setValidity(cert, 825);
    }

    try sign(cert, ca_key);

    return .{
        .cert = cert,
        .key = key,
        .cert_pem = try certToPem(allocator, cert),
        .key_pem = try keyToPem(allocator, key),
        .fingerprint = fingerprint(cert),
    };
}

pub fn issueAuthorityExport(allocator: std.mem.Allocator) !Issued {
    const key = try newEcKey();
    errdefer c.EVP_PKEY_free(key);

    const cert = c.X509_new() orelse return error.CertAlloc;
    errdefer c.X509_free(cert);
    if (c.X509_set_version(cert, 2) != 1) return error.CertInit;

    var raw_serial: [8]u8 = undefined;
    std.crypto.random.bytes(&raw_serial);
    const serial: c_long = @intCast(std.mem.readInt(u64, &raw_serial, .little) & 0x7fff_ffff_ffff_ffff);
    if (c.ASN1_INTEGER_set(c.X509_get_serialNumber(cert), serial) != 1) return error.CertInit;

    const name = c.X509_get_subject_name(cert);
    if (c.X509_NAME_add_entry_by_txt(name, "O", c.MBSTRING_UTF8, "Hampanel".ptr, "Hampanel".len, -1, 0) != 1) return error.CertInit;
    if (c.X509_NAME_add_entry_by_txt(name, "CN", c.MBSTRING_UTF8, "Hampanel Local CA".ptr, "Hampanel Local CA".len, -1, 0) != 1) return error.CertInit;
    if (c.X509_set_issuer_name(cert, name) != 1) return error.CertInit;
    if (c.X509_set_pubkey(cert, key) != 1) return error.CertInit;

    try addExtension(cert, cert, c.NID_basic_constraints, "critical,CA:TRUE");
    try addExtension(cert, cert, c.NID_key_usage, "critical,keyCertSign,cRLSign");
    try addExtension(cert, cert, c.NID_subject_key_identifier, "hash");
    try setValidity(cert, 3650);
    try sign(cert, key);

    return .{
        .cert = cert,
        .key = key,
        .cert_pem = try certToPem(allocator, cert),
        .key_pem = try keyToPem(allocator, key),
        .fingerprint = fingerprint(cert),
    };
}

fn buildSan(allocator: std.mem.Allocator, sans: []const []const u8) ![:0]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    var seen = std.ArrayList([]const u8).init(allocator);
    defer seen.deinit();

    const defaults = [_][]const u8{ "localhost", "127.0.0.1" };
    for (defaults) |entry| try appendSan(&list, &seen, entry);
    for (sans) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        try appendSan(&list, &seen, trimmed);
    }
    return try list.toOwnedSliceSentinel(0);
}

fn appendSan(list: *std.ArrayList(u8), seen: *std.ArrayList([]const u8), entry: []const u8) !void {
    for (seen.items) |existing| {
        if (std.mem.eql(u8, existing, entry)) return;
    }
    try seen.append(entry);

    const is_ip = std.net.Address.parseIp(entry, 0) catch null;
    if (list.items.len > 0) try list.append(',');
    if (is_ip != null) {
        try list.writer().print("IP:{s}", .{entry});
    } else {
        try list.writer().print("DNS:{s}", .{entry});
    }
}

fn certToPem(allocator: std.mem.Allocator, cert: *c.X509) ![]u8 {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.Pem;
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_X509(bio, cert) != 1) return error.Pem;
    return bioSlice(allocator, bio);
}

fn keyToPem(allocator: std.mem.Allocator, key: *c.EVP_PKEY) ![]u8 {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.Pem;
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_PKCS8PrivateKey(bio, key, null, null, 0, null, null) != 1) return error.Pem;
    return bioSlice(allocator, bio);
}

fn bioSlice(allocator: std.mem.Allocator, bio: *c.BIO) ![]u8 {
    var mem: ?*c.BUF_MEM = null;
    if (c.BIO_get_mem_ptr(bio, &mem) != 1) return error.Pem;
    const buffer = mem orelse return error.Pem;
    return allocator.dupe(u8, buffer.data[0..buffer.length]);
}

fn fingerprint(cert: *c.X509) [64]u8 {
    var digest: [32]u8 = undefined;
    var len: c_uint = 0;
    if (c.X509_digest(cert, c.EVP_sha256(), &digest, &len) != 1) {
        return [_]u8{'0'} ** 64;
    }
    return std.fmt.bytesToHex(digest, .lower);
}
