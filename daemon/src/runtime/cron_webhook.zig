const std = @import("std");
const compat = @import("compat");
const App = @import("../app.zig").App;
const Db = @import("../db.zig").Db;
const store = @import("site_store.zig");
const cron = @import("../platform/mod.zig").cron;
const validate = @import("shared").validate;
const eq = std.mem.eql;
pub const dir = "/run/hampanel-cron-webhook";
pub const socket = dir ++ "/trigger.sock";
pub const port = 19743;
pub var mutation: std.Io.Mutex = .init;
pub var ready = std.atomic.Value(bool).init(false);
var jobs = std.atomic.Value(usize).init(0);

// Caddy 2.6.2 can journal the original URI even with a discard writer.
pub fn supportsProvider(server: []const u8) bool {
    return eq(u8, server, "nginx");
}

pub fn internal(s: store.Site) bool {
    return eq(u8, s.kind, "webhook") and s.webhook != null and eq(u8, s.webhook.?.target, "cron");
}

fn digest(text: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

pub fn command(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    for (try cron.list(a)) |entry| {
        if (!eq(u8, entry.id, id)) continue;
        if (found != null) return error.AmbiguousCronId;
        // Cron treats % as a stdin delimiter (even within shell quotes). Never
        // reinterpret such a job as ordinary shell source.
        if (std.mem.indexOfScalar(u8, entry.command, '%') != null) return error.UnsupportedCronCommand;
        found = entry.command;
    }
    return found orelse error.UnknownCronId;
}

fn schema(db: *Db) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS cron_webhooks(site TEXT PRIMARY KEY, cron TEXT NOT NULL, task TEXT NOT NULL, verifier TEXT NOT NULL)");
}
pub fn revoke(db: *Db, site: []const u8) !void {
    try schema(db);
    try db.execute("DELETE FROM cron_webhooks WHERE site=?", &.{.{ .text = site }});
}
// Legacy verifier rows have no issuing-provider provenance. Never accept
// one after upgrade, including when migrating a Caddy host to nginx.
const verifier_prefix = "nginx-tls-v2:";

pub fn secure(site: store.Site) bool {
    return site.tls.enabled and site.tls.certificate.len != 0 and site.tls.key.len != 0 and site.domains.len != 0;
}

fn clearCredentials(db: *Db) !void {
    try schema(db);
    try db.exec("DELETE FROM cron_webhooks");
}

pub fn issue(db: *Db, site: store.Site, cmd: []const u8) ![64]u8 {
    if (!secure(site)) return error.InsecureWebhookTransport;
    var random: [32]u8 = undefined;
    try compat.io().randomSecure(&random);
    const token = std.fmt.bytesToHex(random, .lower);
    try schema(db);
    try db.execute("INSERT OR REPLACE INTO cron_webhooks(site,cron,task,verifier) VALUES(?,?,?,?)", &.{ .{ .text = site.name }, .{ .text = site.webhook.?.cron_id }, .{ .text = &digest(cmd) }, .{ .text = verifier_prefix ++ digest(&token) } });
    return token;
}

fn verify(db: *Db, a: std.mem.Allocator, site: store.Site, token: []const u8) ![]const u8 {
    if (!secure(site) or !site.enabled or !internal(site) or token.len != 64) return error.Denied;
    db.lock();
    defer db.unlock();
    var q = try db.prepareUnlocked("SELECT verifier,task FROM cron_webhooks WHERE site=? AND cron=?");
    defer q.deinit();
    try q.bind(&.{ .{ .text = site.name }, .{ .text = site.webhook.?.cron_id } });
    if (!try q.step()) return error.Denied;
    const verifier = try q.dupeColumnText(a, 0);
    if (verifier.len != verifier_prefix.len + 64 or !std.mem.startsWith(u8, verifier, verifier_prefix) or !std.crypto.timing_safe.eql([64]u8, verifier[verifier_prefix.len..][0..64].*, digest(token))) return error.Denied;
    return q.dupeColumnText(a, 1);
}

const Path = struct { site: []const u8, token: []const u8 };
fn parse(line: []const u8) !Path {
    var it = std.mem.splitScalar(u8, line, ' ');
    if (!eq(u8, it.next() orelse "", "POST")) return error.Denied;
    var path = std.mem.splitScalar(u8, it.next() orelse "", '/');
    const version = it.next() orelse "";
    if ((!eq(u8, version, "HTTP/1.1") and !eq(u8, version, "HTTP/1.0")) or it.next() != null) return error.Denied;
    if (!eq(u8, path.next() orelse "x", "") or !eq(u8, path.next() orelse "", "hook")) return error.Denied;
    const site = path.next() orelse "";
    const token = path.next() orelse "";
    if (!validate.isSlug(site) or token.len != 64 or path.next() != null) return error.Denied;
    for (token) |c| if (!std.ascii.isHex(c)) return error.Denied;
    return .{ .site = site, .token = token };
}

fn dispatch(app: *App, line: []const u8) !void {
    const path = try parse(line);
    if (!ready.load(.acquire)) return error.Denied;
    if (!mutation.tryLock()) return error.Busy;
    defer mutation.unlock(compat.io());
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!supportsProvider(app.config.web_server)) return error.Denied;
    const s = try store.load(a, app.config.data_dir, path.site);
    if (!eq(u8, s.name, path.site)) return error.Denied;
    const task = try verify(app.db, a, s, path.token);
    const cmd = try command(a, s.webhook.?.cron_id);
    if (!eq(u8, task, &digest(cmd))) return error.Denied;
    if (jobs.fetchAdd(1, .acq_rel) >= 4) {
        _ = jobs.fetchSub(1, .acq_rel);
        return error.Busy;
    }
    errdefer _ = jobs.fetchSub(1, .acq_rel);
    const owned = try std.heap.page_allocator.dupe(u8, cmd);
    errdefer std.heap.page_allocator.free(owned);
    (try std.Thread.spawn(.{}, run, .{owned})).detach();
}
fn run(cmd: []u8) void {
    defer _ = jobs.fetchSub(1, .acq_rel);
    defer std.heap.page_allocator.free(cmd);
    var child = std.process.spawn(compat.io(), .{ .argv = &.{ "/bin/sh", "-c", cmd }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(compat.io()) catch {};
}

fn handle(app: *App, stream: std.Io.net.Stream) void {
    const io = compat.io();
    defer stream.close(io);
    @import("../net/socket_timeout.zig").set(stream.socket.handle, 2000, 2000);
    var buf: [8192]u8 = undefined;
    const fd = stream.socket.handle;
    var pollfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    var used: usize = 0;
    const deadline = compat.milliTimestamp() + 3000;
    var result: []const u8 = "404 Not Found";
    while (used < buf.len) {
        const remaining = deadline - compat.milliTimestamp();
        if (remaining <= 0 or (std.posix.poll(&pollfds, @intCast(@min(remaining, 3000))) catch return) == 0) return;
        const n = std.posix.read(fd, buf[used..]) catch return;
        if (n == 0) return;
        used += n;
        if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") == null) continue;
        const end = std.mem.indexOf(u8, buf[0..used], "\r\n").?;
        if (dispatch(app, buf[0..end])) |_| {
            result = "202 Accepted";
        } else |err| {
            if (err == error.Busy) result = "503 Service Unavailable";
        }
        break;
    }
    var out: [256]u8 = undefined;
    var writer = stream.writer(io, &out);
    writer.interface.print("HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n", .{result}) catch return;
    writer.interface.flush() catch {};
}
var connections = std.atomic.Value(usize).init(0);

fn serveConnection(app: *App, stream: std.Io.net.Stream) void {
    defer _ = connections.fetchSub(1, .acq_rel);
    handle(app, stream);
}

fn loop(app: *App, listeners: [2]std.Io.net.Server) void {
    var servers = listeners;
    var fds: [2]std.posix.pollfd = undefined;
    for (&fds, servers) |*fd, s| fd.* = .{ .fd = s.socket.handle, .events = std.posix.POLL.IN, .revents = 0 };
    while (true) {
        _ = std.posix.poll(&fds, -1) catch {
            compat.sleep(100_000_000);
            continue;
        };
        for (fds, &servers) |fd, *s| {
            if (fd.revents & std.posix.POLL.IN == 0) continue;
            const stream = s.accept(compat.io()) catch continue;
            if (connections.fetchAdd(1, .acq_rel) >= 16) {
                _ = connections.fetchSub(1, .acq_rel);
                stream.close(compat.io());
                continue;
            }
            const worker = std.Thread.spawn(.{}, serveConnection, .{ app, stream }) catch {
                _ = connections.fetchSub(1, .acq_rel);
                stream.close(compat.io());
                continue;
            };
            worker.detach();
        }
    }
}
pub fn start(app: *App) !void {
    if (@import("builtin").os.tag != .linux) return;
    // Auto-detection can change without an observable configuration transition.
    if (!supportsProvider(app.config.web_server)) return clearCredentials(app.db);
    const io = compat.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var tcp = try address.listen(io, .{});
    errdefer tcp.deinit(io);
    try compat.cwd().makePath(dir);
    try compat.setFilePermissions(dir, 0o755);
    compat.deleteFileAbsolute(socket) catch |err| if (err != error.FileNotFound) return err;
    const addr = try std.Io.net.UnixAddress.init(socket);
    var unix = try addr.listen(io, .{});
    errdefer compat.deleteFileAbsolute(socket) catch {};
    errdefer unix.deinit(io);
    try compat.setFilePermissions(socket, 0o666);
    try schema(app.db);
    (try std.Thread.spawn(.{}, loop, .{ app, [2]std.Io.net.Server{ tcp, unix } })).detach();
    ready.store(true, .release);
}

test "credential is scoped to enabled site and cron; rotation and revoke invalidate old tokens" {
    var db = try Db.open(":memory:");
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var site = store.Site{ .name = "test", .kind = "webhook", .webhook = .{ .target = "cron", .cron_id = "00112233" } };
    try std.testing.expectError(error.InsecureWebhookTransport, issue(&db, site, "true"));
    site.domains = &.{"build.example"};
    site.tls = .{ .enabled = true, .certificate = "/cert", .key = "/key" };
    const first = try issue(&db, site, "true");
    try std.testing.expectEqualStrings(&digest("true"), try verify(&db, a, site, &first));
    try db.execute("UPDATE cron_webhooks SET verifier=? WHERE site=?", &.{ .{ .text = &digest(&first) }, .{ .text = site.name } });
    try std.testing.expectError(error.Denied, verify(&db, a, site, &first));
    const second = try issue(&db, site, "false");
    try std.testing.expectError(error.Denied, verify(&db, a, site, &first));
    site.tls.enabled = false;
    try std.testing.expectError(error.Denied, verify(&db, a, site, &second));
    site.tls.enabled = true;
    site.enabled = false;
    try std.testing.expectError(error.Denied, verify(&db, a, site, &second));
    site.enabled = true;
    site.webhook.?.cron_id = "00112234";
    try std.testing.expectError(error.Denied, verify(&db, a, site, &second));
    site.webhook.?.cron_id = "00112233";
    try clearCredentials(&db);
    try std.testing.expectError(error.Denied, verify(&db, a, site, &second));
    const third = try issue(&db, site, "true");
    try revoke(&db, site.name);
    try std.testing.expectError(error.Denied, verify(&db, a, site, &third));
    try std.testing.expectError(error.Denied, verify(&db, a, site, &second));
}
test "public trigger only accepts exact POST path" {
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const path = "/hook/site/" ++ token;
    try std.testing.expectEqualStrings(token, (try parse("POST " ++ path ++ " HTTP/1.1")).token);
    for ([_][]const u8{ "GET " ++ path ++ " HTTP/1.1", "POST " ++ path ++ "?cmd=x HTTP/1.1", "POST /api/v1/cron HTTP/1.1", "POST /hook/../" ++ token ++ " HTTP/1.1" }) |line| try std.testing.expectError(error.Denied, parse(line));
}
