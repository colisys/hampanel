const std = @import("std");
const db = @import("db.zig");
const compat = @import("compat");
const exec = @import("shared").exec;
const platform = @import("platform_backend");
const log = @import("log.zig");

pub const Event = enum { login, ai_command, service_restart, docker_restart, availability };

pub const Provider = enum { bark, ntfy };

pub const Config = struct {
    bark_enabled: bool = false,
    bark_server: []const u8 = "https://api.day.app",
    bark_key: []const u8 = "",
    bark_group: []const u8 = "Hampanel",
    bark_sound: []const u8 = "",
    bark_level: []const u8 = "active",
    ntfy_enabled: bool = false,
    ntfy_server: []const u8 = "https://ntfy.sh",
    ntfy_topic: []const u8 = "",
    ntfy_token: []const u8 = "",
    ntfy_priority: []const u8 = "default",
    ntfy_tags: []const u8 = "",
    event_login: bool = true,
    event_ai_command: bool = true,
    event_service_restart: bool = true,
    event_docker_restart: bool = true,
    event_availability: bool = true,
    memory_percent: u8 = 90,
    disk_percent: u8 = 90,
    cooldown_minutes: u32 = 30,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

const settings_key = "notifications";
const login_throttle_seconds: i64 = 300;

var last_login_at: i64 = 0;
var cooldowns: std.StringHashMap(i64) = undefined;
var cooldowns_ready = false;

pub fn defaults() Config {
    return .{};
}

pub fn load(allocator: std.mem.Allocator, database: *db.Db) Config {
    const raw = database.getSetting(allocator, settings_key) catch return defaults();
    const text = raw orelse return defaults();
    return std.json.parseFromSliceLeaky(Config, allocator, text, .{
        .ignore_unknown_fields = true,
    }) catch defaults();
}

pub fn save(allocator: std.mem.Allocator, database: *db.Db, config: Config) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2 });
    try database.setSetting(settings_key, body);
}

pub fn enabledFor(config: Config, event: Event) bool {
    return switch (event) {
        .login => config.event_login,
        .ai_command => config.event_ai_command,
        .service_restart => config.event_service_restart,
        .docker_restart => config.event_docker_restart,
        .availability => config.event_availability,
    };
}

pub fn validate(config: Config) ?[]const u8 {
    if (config.memory_percent == 0 or config.memory_percent > 100) return "memory_percent must be 1..100";
    if (config.disk_percent == 0 or config.disk_percent > 100) return "disk_percent must be 1..100";
    if (config.cooldown_minutes == 0 or config.cooldown_minutes > 24 * 60) return "cooldown_minutes must be 1..1440";
    if (config.bark_enabled) {
        if (!validUrl(config.bark_server)) return "bark_server must be an http(s) URL";
        if (!validBarkKey(config.bark_key)) return "bark_key must be non-empty and use [A-Za-z0-9_-]";
    }
    if (config.ntfy_enabled) {
        if (!validUrl(config.ntfy_server)) return "ntfy_server must be an http(s) URL";
        if (!validTopic(config.ntfy_topic)) return "ntfy_topic must be 1..64 chars of [A-Za-z0-9_-]";
        if (tryPriorityName(config.ntfy_priority) == null) return "ntfy_priority must be min/low/default/high/urgent/max or 1..5";
    }
    return null;
}

fn validUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://");
}

fn validBarkKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    }
    return true;
}

fn validTopic(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    }
    return true;
}

/// ntfy accepts a priority name or 1..5. Normalize to the canonical name so an
/// operator typing `3` or `Low` still gets a valid header, and reject anything
/// else instead of sending a request ntfy will answer with HTTP 400.
fn tryPriorityName(value: []const u8) ?[]const u8 {
    const names = [_][]const u8{ "max", "urgent", "high", "default", "low", "min" };
    var lowered_buffer: [8]u8 = undefined;
    if (value.len == 0 or value.len > lowered_buffer.len) return null;
    const lowered = std.ascii.lowerString(&lowered_buffer, value);
    for (names) |name| {
        if (std.mem.eql(u8, lowered, name)) return name;
    }
    if (lowered.len == 1 and lowered[0] >= '1' and lowered[0] <= '5') {
        return switch (lowered[0]) {
            '1' => "min",
            '2' => "low",
            '3' => "default",
            '4' => "high",
            else => "max",
        };
    }
    return null;
}

fn trimSlash(value: []const u8) []const u8 {
    var out = value;
    while (out.len > 0 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
    return out;
}

pub fn barkPayload(
    allocator: std.mem.Allocator,
    config: Config,
    title: []const u8,
    body: []const u8,
) ![]u8 {
    var root: std.json.Value = .{ .object = .empty };
    try root.object.put(allocator, "device_key", .{ .string = config.bark_key });
    try root.object.put(allocator, "title", .{ .string = title });
    try root.object.put(allocator, "body", .{ .string = body });
    try root.object.put(allocator, "group", .{ .string = config.bark_group });
    try root.object.put(allocator, "level", .{ .string = config.bark_level });
    if (config.bark_sound.len > 0) {
        try root.object.put(allocator, "sound", .{ .string = config.bark_sound });
    }
    return std.json.Stringify.valueAlloc(allocator, root, .{});
}

fn outputOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    if (result.stdout.len > 0) return result.stdout;
    return "";
}

fn sendBark(
    allocator: std.mem.Allocator,
    config: Config,
    title: []const u8,
    body: []const u8,
) Outcome {
    if (!config.bark_enabled) return .{ .ok = false, .output = "bark disabled" };
    if (!validUrl(config.bark_server)) return .{ .ok = false, .output = "invalid bark_server" };
    if (!validBarkKey(config.bark_key)) return .{ .ok = false, .output = "invalid bark_key" };
    const payload = barkPayload(allocator, config, title, body) catch {
        return .{ .ok = false, .output = "out of memory" };
    };
    const url = std.fmt.allocPrint(allocator, "{s}/push", .{trimSlash(config.bark_server)}) catch {
        return .{ .ok = false, .output = "out of memory" };
    };
    const result = exec.run(allocator, &.{
        "curl", "-fsS", "--max-time", "8",
        "-H", "Content-Type: application/json",
        "-X", "POST",
        "-d", payload,
        url,
    }, 64 * 1024) catch return .{ .ok = false, .output = "curl unavailable" };
    return .{ .ok = result.ok(), .output = outputOf(result) };
}

/// Sends through the header form documented at https://docs.ntfy.sh/publish/:
/// the topic goes in the URL path and title/priority/tags travel as headers.
///
/// The JSON form was used before and never worked: `POST /` with a body of
/// `{"priority":"default"}` is rejected with HTTP 400 (`priority` must be a
/// number there), and `curl -f` discarded that error, so every send failed with
/// an empty message. The header form accepts names (`default`, `high`, ...) and
/// needs no JSON at all.
fn sendNtfy(
    allocator: std.mem.Allocator,
    config: Config,
    title: []const u8,
    body: []const u8,
) Outcome {
    if (!config.ntfy_enabled) return .{ .ok = false, .output = "ntfy disabled" };
    if (!validUrl(config.ntfy_server)) return .{ .ok = false, .output = "invalid ntfy_server" };
    if (!validTopic(config.ntfy_topic)) return .{ .ok = false, .output = "invalid ntfy_topic" };
    const priority = tryPriorityName(config.ntfy_priority) orelse
        return .{ .ok = false, .output = "invalid ntfy_priority" };

    const url = std.fmt.allocPrint(allocator, "{s}/{s}", .{
        trimSlash(config.ntfy_server),
        config.ntfy_topic,
    }) catch return .{ .ok = false, .output = "out of memory" };
    defer allocator.free(url);

    // `-sS` without `-f`: on a rejection ntfy answers with a JSON error body,
    // and that body is the only useful diagnostic the operator can get.
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    argv.appendSlice(&.{ "curl", "-sS", "--max-time", "8" }) catch
        return .{ .ok = false, .output = "out of memory" };

    const title_header = std.fmt.allocPrint(allocator, "Title: {s}", .{title}) catch null;
    defer if (title_header) |h| allocator.free(h);
    if (title_header) |header| argv.appendSlice(&.{ "-H", header }) catch {};

    const priority_header = std.fmt.allocPrint(allocator, "Priority: {s}", .{priority}) catch null;
    defer if (priority_header) |h| allocator.free(h);
    if (priority_header) |header| argv.appendSlice(&.{ "-H", header }) catch {};

    const tags_header = if (config.ntfy_tags.len > 0)
        std.fmt.allocPrint(allocator, "Tags: {s}", .{config.ntfy_tags}) catch null
    else
        null;
    defer if (tags_header) |h| allocator.free(h);
    if (tags_header) |header| argv.appendSlice(&.{ "-H", header }) catch {};

    const auth = if (config.ntfy_token.len > 0)
        std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{config.ntfy_token}) catch null
    else
        null;
    defer if (auth) |h| allocator.free(h);
    if (auth) |header| argv.appendSlice(&.{ "-H", header }) catch {};

    argv.appendSlice(&.{ "-d", body, url }) catch
        return .{ .ok = false, .output = "out of memory" };

    const result = exec.run(allocator, argv.items, 64 * 1024) catch {
        return .{ .ok = false, .output = "curl unavailable" };
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    // ntfy always answers with a JSON message object; a non-empty `error` means
    // the push did not happen even when curl itself reported success.
    const output = outputOf(result);
    if (std.mem.indexOf(u8, output, "\"error\"") != null and !result.ok()) {
        return .{ .ok = false, .output = output };
    }
    return .{ .ok = result.ok(), .output = output };
}

pub fn sendProvider(
    allocator: std.mem.Allocator,
    config: Config,
    provider: Provider,
    title: []const u8,
    body: []const u8,
) Outcome {
    return switch (provider) {
        .bark => sendBark(allocator, config, title, body),
        .ntfy => sendNtfy(allocator, config, title, body),
    };
}

const Job = struct {
    database: *db.Db,
    title: []const u8,
    body: []const u8,
};

fn worker(job: *Job) void {
    const gpa = std.heap.page_allocator;
    defer {
        gpa.free(job.title);
        gpa.free(job.body);
        gpa.destroy(job);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const config = load(arena.allocator(), job.database);
    if (config.bark_enabled) {
        const outcome = sendBark(arena.allocator(), config, job.title, job.body);
        if (!outcome.ok) std.debug.print("[notify] bark failed: {s}\n", .{outcome.output});
    }
    if (config.ntfy_enabled) {
        const outcome = sendNtfy(arena.allocator(), config, job.title, job.body);
        if (!outcome.ok) std.debug.print("[notify] ntfy failed: {s}\n", .{outcome.output});
    }
}

/// Fire-and-forget notification. Safe to call from request threads: the
/// config is re-read inside the worker, and title/body are copied.
pub fn emit(database: *db.Db, event: Event, title: []const u8, body: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = load(arena.allocator(), database);
    if (!enabledFor(config, event)) return;
    if (!config.bark_enabled and !config.ntfy_enabled) return;
    if (validate(config) != null) return;
    if (event == .login) {
        const now = compat.timestamp();
        if (now - last_login_at < login_throttle_seconds) return;
        last_login_at = now;
    }

    const gpa = std.heap.page_allocator;
    const title_copy = gpa.dupe(u8, title) catch return;
    const body_copy = gpa.dupe(u8, body) catch {
        gpa.free(title_copy);
        return;
    };
    const job = gpa.create(Job) catch {
        gpa.free(title_copy);
        gpa.free(body_copy);
        return;
    };
    job.* = .{ .database = database, .title = title_copy, .body = body_copy };
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        gpa.free(title_copy);
        gpa.free(body_copy);
        gpa.destroy(job);
        return;
    };
    thread.detach();
}

fn cooldownOk(key: []const u8, seconds: i64) bool {
    if (!cooldowns_ready) {
        cooldowns = std.StringHashMap(i64).init(std.heap.page_allocator);
        cooldowns_ready = true;
    }
    const now = compat.timestamp();
    if (cooldowns.get(key)) |last| {
        if (now - last < seconds) return false;
    }
    cooldowns.put(key, now) catch return true;
    return true;
}

pub fn startMonitor(database: *db.Db) void {
    const thread = std.Thread.spawn(.{}, monitorLoop, .{database}) catch return;
    thread.detach();
}

fn monitorLoop(database: *db.Db) void {
    const interval = blk: {
        if (compat.getEnv("HAMPANEL_NOTIFY_INTERVAL_SECONDS")) |raw| {
            const seconds = std.fmt.parseInt(u64, raw, 10) catch 0;
            if (seconds > 0 and seconds <= 3600) break :blk seconds;
        }
        break :blk @as(u64, 60);
    };
    log.info("notification monitor started (interval {d}s)", .{interval});
    var sampler: platform.metrics.State = .{};
    while (true) {
        compat.sleep(interval * std.time.ns_per_s);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const config = load(allocator, database);
        if (!config.event_availability) continue;
        if (!config.bark_enabled and !config.ntfy_enabled) continue;
        if (validate(config) != null) continue;
        const metrics = platform.metrics.sample(allocator, &sampler) catch |err| {
            log.warn("availability metrics failed: {s}", .{@errorName(err)});
            continue;
        };
        const cooldown = @as(i64, @intCast(config.cooldown_minutes)) * 60;

        if (metrics.memory.percent >= @as(f64, @floatFromInt(config.memory_percent))) {
            if (cooldownOk("memory", cooldown)) {
                const body = std.fmt.allocPrint(
                    allocator,
                    "内存使用率 {d:.1}% 超过阈值 {d}%",
                    .{ metrics.memory.percent, config.memory_percent },
                ) catch "内存使用率超过阈值";
                log.info("availability alert: {s}", .{body});
                emit(database, .availability, "可用性下降：内存", body);
            }
        }

        for (metrics.disks) |disk| {
            if (disk.percent < @as(f64, @floatFromInt(config.disk_percent))) continue;
            if (!cooldownOk("disk", cooldown)) break;
            const body = std.fmt.allocPrint(
                allocator,
                "磁盘 {s} 使用率 {d:.1}% 超过阈值 {d}%",
                .{ disk.mount, disk.percent, config.disk_percent },
            ) catch "磁盘使用率超过阈值";
            emit(database, .availability, "可用性下降：磁盘", body);
            break;
        }
    }
}

test "notification config round-trips through sqlite" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fs.path.join(allocator, &.{ dir, "hampanel.db" });
    defer allocator.free(db_path);
    var database = try db.Db.open(db_path);
    defer database.close();
    const migrations = @import("migrations.zig");
    try migrations.migrate(allocator, &database);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var config = defaults();
    config.bark_enabled = true;
    config.bark_key = "testkey";
    config.ntfy_enabled = true;
    config.ntfy_topic = "alerts";
    config.ntfy_token = "tk";
    config.event_login = false;
    config.memory_percent = 80;
    try save(a, &database, config);

    const loaded = load(a, &database);
    try std.testing.expect(loaded.bark_enabled);
    try std.testing.expectEqualStrings("testkey", loaded.bark_key);
    try std.testing.expect(loaded.ntfy_enabled);
    try std.testing.expectEqualStrings("alerts", loaded.ntfy_topic);
    try std.testing.expect(!loaded.event_login);
    try std.testing.expectEqual(@as(u8, 80), loaded.memory_percent);
}

test "payload builders and validation" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var config = defaults();
    config.bark_enabled = true;
    config.bark_key = "abc_123";
    config.ntfy_enabled = true;
    config.ntfy_topic = "hampanel-alerts";
    config.ntfy_tags = "warning,server";
    try std.testing.expect(validate(config) == null);

    const bark = try barkPayload(a, config, "面板登录", "来自 1.2.3.4");
    try std.testing.expect(std.mem.indexOf(u8, bark, "device_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, bark, "abc_123") != null);
    try std.testing.expect(std.mem.indexOf(u8, bark, "面板登录") != null);

    // The header form needs no JSON body, so what must hold is that a typo in
    // the priority is caught here rather than sent and rejected with HTTP 400.
    try std.testing.expect(tryPriorityName("default") != null);
    try std.testing.expect(tryPriorityName("DEFAULT") != null);
    try std.testing.expectEqualStrings("high", tryPriorityName("4").?);
    try std.testing.expectEqualStrings("min", tryPriorityName("1").?);
    try std.testing.expect(tryPriorityName("loud") == null);
    try std.testing.expect(tryPriorityName("") == null);
    try std.testing.expect(tryPriorityName("6") == null);

    var bad_priority = config;
    bad_priority.ntfy_priority = "loud";
    try std.testing.expect(validate(bad_priority) != null);

    var bad = config;
    bad.ntfy_topic = "bad topic!";
    try std.testing.expect(validate(bad) != null);
    bad = config;
    bad.bark_server = "ftp://example";
    try std.testing.expect(validate(bad) != null);

    var events = defaults();
    try std.testing.expect(enabledFor(events, .availability));
    events.event_availability = false;
    try std.testing.expect(!enabledFor(events, .availability));
}
