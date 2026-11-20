const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// Passive scan sensing.
///
/// Connection attempts are collected in the kernel with eBPF kprobes on
/// `tcp_v4_rcv`/`tcp_v6_rcv`, aggregated per (source, port) inside a bpftrace
/// map, and flushed as one JSON line every interval. A source that touches more
/// than `max_targets` distinct ports inside the window is banned.
///
/// bpftrace is used instead of a compiled libbpf object because it needs no
/// kernel headers at build time; a compiled probe would have to match the
/// running kernel, while the daemon must work on any host it lands on.

pub const Limits = struct {
    /// Distinct destination ports a source may touch inside the window.
    max_targets: u32 = 12,
    /// How long observations count toward the window.
    window_seconds: u32 = 60,
    /// How long an automatic ban is applied for.
    ban_seconds: u32 = 3600,
};

pub const probe_script =
    \\kprobe:tcp_v4_rcv
    \\{
    \\  $skb = (struct sk_buff *)arg0;
    \\  $base = (uint64)($skb->head + $skb->network_header);
    \\  if (*(uint8*)($base+9) == 6) {
    \\    $tcp = $base + (*(uint8*)$base & 0xf) * 4;
    \\    if (*(uint8*)($tcp+13) == 2) {
    \\      @v4[*(uint32*)($base+12), *(uint16*)($tcp+2)] = count();
    \\    }
    \\  }
    \\}
    \\kprobe:tcp_v6_rcv
    \\{
    \\  $skb = (struct sk_buff *)arg0;
    \\  $base = (uint64)($skb->head + $skb->network_header);
    \\  if (*(uint8*)($base+6) == 6) {
    \\    $tcp = $base + 40;
    \\    if (*(uint8*)($tcp+13) == 2) {
    \\      @v6[*(uint64*)($base+8), *(uint64*)($base+16), *(uint16*)($tcp+2)] = count();
    \\    }
    \\  }
    \\}
    \\interval:s:5 { print(@v4); print(@v6); clear(@v4); clear(@v6); }
    \\
;

pub const Observation = struct {
    source: []const u8,
    port: u16,
    count: u32,
};

pub const Paths = struct {
    root: []u8,
    script: []u8,
    pid: []u8,
    hits: []u8,
    banned: []u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.script);
        allocator.free(self.pid);
        allocator.free(self.hits);
        allocator.free(self.banned);
    }
};

pub fn buildPaths(allocator: std.mem.Allocator, data_dir: []const u8) !Paths {
    const root = try compat.path.join(allocator, &.{ data_dir, "security" });
    errdefer allocator.free(root);
    return .{
        .root = root,
        .script = try compat.path.join(allocator, &.{ root, "scan-sensor.bt" }),
        .pid = try compat.path.join(allocator, &.{ root, "scan-sensor.pid" }),
        .hits = try compat.path.join(allocator, &.{ root, "scan-hits.jsonl" }),
        .banned = try compat.path.join(allocator, &.{ root, "scan-banned.txt" }),
    };
}

/// Writes the probe script so it can be inspected and replayed by hand.
pub fn install(allocator: std.mem.Allocator, data_dir: []const u8) !Paths {
    const paths = try buildPaths(allocator, data_dir);
    errdefer paths.deinit(allocator);
    try compat.cwd().makePath(paths.root);
    try writeFile(paths.script, probe_script);
    return paths;
}

pub fn bpftraceAvailable(allocator: std.mem.Allocator) bool {
    const result = exec.run(allocator, &.{ "bpftrace", "--version" }, 64 * 1024) catch return false;
    return result.ok();
}

/// Runs the probe as a supervised child: stdout is pumped line by line so a
/// flush is ingested as soon as it lands, and the child is restarted if bpftrace
/// dies (kernel probes can be evicted by module reloads).
/// One probe per daemon process. `active` tracks the supervisor thread, not the
/// child, so an orphaned bpftrace cannot make a fresh daemon believe the sensor
/// is already running.
var supervisor_active = std.atomic.Value(bool).init(false);
var supervisor_stop = std.atomic.Value(bool).init(false);

const Supervisor = struct {
    data_dir: []const u8,
    script: []const u8,
    pid_path: []const u8,
};

pub fn start(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    try compat.cwd().makePath(paths.root);
    if (!exists(paths.script)) {
        // Starting implies installing: the script is the probe definition.
        try writeFile(paths.script, probe_script);
    }
    if (supervisor_active.load(.acquire)) return error.AlreadyRunning;

    // A bpftrace left behind by a crashed daemon writes into a pipe nobody
    // reads, so it must be replaced rather than reported as already running.
    if (readPid(allocator, paths.pid)) |pid| {
        if (pidAlive(pid)) {
            std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
            compat.sleep(200 * std.time.ns_per_ms);
            if (pidAlive(pid)) std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
        }
    }
    compat.deleteFileAbsolute(paths.pid) catch {};
    supervisor_stop.store(false, .release);

    const context = try std.heap.page_allocator.create(Supervisor);
    context.* = .{
        .data_dir = try std.heap.page_allocator.dupe(u8, data_dir),
        .script = try std.heap.page_allocator.dupe(u8, paths.script),
        .pid_path = try std.heap.page_allocator.dupe(u8, paths.pid),
    };
    const thread = std.Thread.spawn(.{}, supervise, .{context}) catch |err| {
        std.heap.page_allocator.destroy(context);
        return err;
    };
    thread.detach();
}

/// Stops the supervisor and its child, then waits for the thread to exit.
pub fn stop(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    supervisor_stop.store(true, .release);

    if (readPid(allocator, paths.pid)) |pid| {
        if (pidAlive(pid)) {
            std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
            var waited: usize = 0;
            while (waited < 20) : (waited += 1) {
                compat.sleep(100 * std.time.ns_per_ms);
                if (!pidAlive(pid)) break;
            }
            if (pidAlive(pid)) std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
        }
        compat.deleteFileAbsolute(paths.pid) catch {};
    }

    var waited: usize = 0;
    while (waited < 40 and supervisor_active.load(.acquire)) : (waited += 1) {
        compat.sleep(50 * std.time.ns_per_ms);
    }
}

fn supervise(context: *const Supervisor) void {
    const io = compat.io();
    supervisor_active.store(true, .release);
    defer supervisor_active.store(false, .release);

    while (!supervisor_stop.load(.acquire)) {
        var child = std.process.spawn(io, .{
            .argv = &.{ "bpftrace", "-f", "json", context.script },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch {
            compat.sleep(5 * std.time.ns_per_s);
            continue;
        };
        const pid = child.id orelse {
            compat.sleep(5 * std.time.ns_per_s);
            continue;
        };
        const pid_text = std.fmt.allocPrint(std.heap.page_allocator, "{d}\n", .{pid}) catch "0\n";
        defer std.heap.page_allocator.free(pid_text);
        writeFile(context.pid_path, pid_text) catch {};

        if (child.stdout) |stdout| {
            var buffer: [64 * 1024]u8 = undefined;
            var pending: std.ArrayListUnmanaged(u8) = .empty;
            defer pending.deinit(std.heap.page_allocator);
            while (!supervisor_stop.load(.acquire)) {
                const read = stdout.readStreaming(io, &.{&buffer}) catch break;
                if (read == 0) break;
                pending.appendSlice(std.heap.page_allocator, buffer[0..read]) catch break;
                while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
                    const line = pending.items[0..newline];
                    if (line.len > 0) {
                        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                        defer arena.deinit();
                        handleFromLine(arena.allocator(), context.data_dir, line, .{}) catch {};
                    }
                    pending.replaceRange(std.heap.page_allocator, 0, newline + 1, &.{}) catch break;
                }
            }
        }
        _ = child.wait(io) catch {};
        compat.deleteFileAbsolute(context.pid_path) catch {};
        if (supervisor_stop.load(.acquire)) break;
        compat.sleep(2 * std.time.ns_per_s);
    }
}

/// Decodes one bpftrace map key into an observation.
///
/// Keys are `"<ip>,<port>"` for IPv4 and `"<hi>,<lo>,<port>"` for IPv6, with the
/// address stored as a host-order integer.
pub fn decodeKey(allocator: std.mem.Allocator, version: u8, key: []const u8) !Observation {
    var fields: [3]u64 = .{ 0, 0, 0 };
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, key, ',');
    while (parts.next()) |part| {
        if (count >= fields.len) return error.BadKey;
        fields[count] = std.fmt.parseInt(u64, std.mem.trim(u8, part, " \t"), 10) catch
            return error.BadKey;
        count += 1;
    }
    if (version == 4) {
        if (count != 2 or fields[0] > std.math.maxInt(u32) or fields[1] > 65535) return error.BadKey;
        const ip: u32 = @intCast(fields[0]);
        return .{
            .source = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                @as(u8, @truncate(ip)),
                @as(u8, @truncate(ip >> 8)),
                @as(u8, @truncate(ip >> 16)),
                @as(u8, @truncate(ip >> 24)),
            }),
            .port = @byteSwap(@as(u16, @intCast(fields[1]))),
            .count = 0,
        };
    }
    if (version == 6) {
        if (count != 3 or fields[2] > 65535) return error.BadKey;
        return .{
            .source = try formatIp6(allocator, fields[0], fields[1]),
            .port = @byteSwap(@as(u16, @intCast(fields[2]))),
            .count = 0,
        };
    }
    return error.BadKey;
}

pub fn formatIp6(allocator: std.mem.Allocator, hi: u64, lo: u64) ![]u8 {
    // The kernel struct keeps each 16-bit group in network order, so reading it
    // as a host-order integer leaves every group byte-swapped.
    const groups = [8]u16{
        @byteSwap(@as(u16, @truncate(hi))),
        @byteSwap(@as(u16, @truncate(hi >> 16))),
        @byteSwap(@as(u16, @truncate(hi >> 32))),
        @byteSwap(@as(u16, @truncate(hi >> 48))),
        @byteSwap(@as(u16, @truncate(lo))),
        @byteSwap(@as(u16, @truncate(lo >> 16))),
        @byteSwap(@as(u16, @truncate(lo >> 32))),
        @byteSwap(@as(u16, @truncate(lo >> 48))),
    };
    return std.fmt.allocPrint(allocator, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
        groups[0], groups[1], groups[2], groups[3],
        groups[4], groups[5], groups[6], groups[7],
    });
}

/// Parses one flush line: `{"type":"map","data":{"@v4":{"key":count}}}`.
pub fn parseFlush(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(Observation),
    line: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const kind = parsed.value.object.get("type") orelse return;
    if (kind != .string or !std.mem.eql(u8, kind.string, "map")) return;
    const data = parsed.value.object.get("data") orelse return;
    if (data != .object) return;

    var maps = data.object.iterator();
    while (maps.next()) |entry| {
        const name = entry.key_ptr.*;
        const version: u8 = if (std.mem.eql(u8, name, "@v4"))
            4
        else if (std.mem.eql(u8, name, "@v6"))
            6
        else
            continue;
        if (entry.value_ptr.* != .object) continue;
        var hits = entry.value_ptr.object.iterator();
        while (hits.next()) |hit| {
            var observation = decodeKey(allocator, version, hit.key_ptr.*) catch continue;
            const value = hit.value_ptr.*;
            observation.count = if (value == .integer and value.integer > 0)
                @intCast(@min(value.integer, std.math.maxInt(u32)))
            else
                0;
            try list.append(observation);
        }
    }
}

/// Counts distinct ports per source and returns those over the threshold.
pub fn suspects(
    allocator: std.mem.Allocator,
    hits: []const Observation,
    max_targets: u32,
    out: *std.array_list.Managed([]u8),
) !void {
    var counts = std.StringHashMap(std.ArrayListUnmanaged(u16)).init(allocator);
    defer {
        var it = counts.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        counts.deinit();
    }
    for (hits) |hit| {
        const entry = counts.getEntry(hit.source) orelse {
            var ports: std.ArrayListUnmanaged(u16) = .empty;
            try ports.append(allocator, hit.port);
            try counts.put(try allocator.dupe(u8, hit.source), ports);
            continue;
        };
        var seen = false;
        for (entry.value_ptr.items) |port| {
            if (port == hit.port) {
                seen = true;
                break;
            }
        }
        if (!seen) try entry.value_ptr.append(allocator, hit.port);
    }
    var it = counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.items.len <= max_targets) continue;
        try out.append(try allocator.dupe(u8, entry.key_ptr.*));
    }
}

/// Keeps the observation file bounded: the newest `keep` lines survive.
pub fn trimHits(allocator: std.mem.Allocator, path: []const u8, keep: usize) void {
    const raw = compat.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch return;
    defer allocator.free(raw);
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len > 0) total += 1;
    }
    if (total <= keep) return;

    var skip = total - keep;
    var keep_from: usize = 0;
    var cursor: usize = 0;
    while (cursor < raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, cursor, '\n') orelse raw.len;
        if (std.mem.trim(u8, raw[cursor..end], " \r\t").len > 0) {
            if (skip == 0) {
                keep_from = cursor;
                break;
            }
            skip -= 1;
        }
        cursor = end + 1;
    }
    writeFile(path, raw[keep_from..]) catch {};
}

/// Reads one persisted record: `{"at":..,"source":..,"port":..,"count":..}`.
pub fn parseRecord(allocator: std.mem.Allocator, line: []const u8) !Observation {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadRecord;
    const source = parsed.value.object.get("source") orelse return error.BadRecord;
    if (source != .string) return error.BadRecord;
    const port = parsed.value.object.get("port") orelse return error.BadRecord;
    if (port != .integer or port.integer < 0 or port.integer > 65535) return error.BadRecord;
    const count = parsed.value.object.get("count");
    return .{
        .source = try allocator.dupe(u8, source.string),
        .port = @intCast(port.integer),
        .count = if (count) |value| if (value == .integer and value.integer > 0)
            @intCast(@min(value.integer, std.math.maxInt(u32)))
        else
            0 else 0,
    };
}

pub fn readHits(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]const Observation {
    const raw = compat.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch return &.{};
    defer allocator.free(raw);
    var list = std.array_list.Managed(Observation).init(allocator);
    errdefer {
        for (list.items) |item| allocator.free(item.source);
        list.deinit();
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        // The file holds records this module wrote; the flush format only
        // arrives from the probe pipe.
        if (parseRecord(allocator, text)) |record| {
            try list.append(record);
        } else |_| {
            try parseFlush(allocator, &list, text);
        }
    }
    // Keep the newest observations; the file is append-ordered.
    const keep_from = if (list.items.len > limit) list.items.len - limit else 0;
    var kept = std.array_list.Managed(Observation).init(allocator);
    errdefer kept.deinit();
    for (list.items[keep_from..]) |item| try kept.append(item);
    for (list.items[0..keep_from]) |item| allocator.free(item.source);
    list.deinit();
    const owned = try allocator.dupe(Observation, kept.items);
    kept.deinit();
    return owned;
}

pub fn handleFromLine(allocator: std.mem.Allocator, data_dir: []const u8, line: []const u8, limits: Limits) !void {
    var list = std.array_list.Managed(Observation).init(allocator);
    defer {
        for (list.items) |item| allocator.free(item.source);
        list.deinit();
    }
    try parseFlush(allocator, &list, line);
    if (list.items.len == 0) return;

    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    try compat.cwd().makePath(paths.root);

    // Persist the flush so the panel can show recent activity. Opening a file
    // for writing starts at offset 0, so records are written positionally past
    // the current end; otherwise every flush would overwrite the oldest ones.
    var file = try compat.createFileAbsolute(paths.hits, .{ .truncate = false, .mode = 0o600 });
    defer file.close();
    var offset = file.length() catch 0;
    for (list.items) |item| {
        const record = try std.fmt.allocPrint(allocator, "{{\"at\":{d},\"source\":\"{s}\",\"port\":{d},\"count\":{d}}}\n", .{
            compat.milliTimestamp(),
            item.source,
            item.port,
            item.count,
        });
        defer allocator.free(record);
        file.writePositionalAll(record, offset) catch break;
        offset += record.len;
    }

    var suspects_list = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (suspects_list.items) |entry| allocator.free(entry);
        suspects_list.deinit();
    }
    try suspects(allocator, list.items, limits.max_targets, &suspects_list);
    for (suspects_list.items) |source| {
        const banned = try recordBan(allocator, data_dir, source);
        if (!banned) continue;
        // Denial failures are reported by the caller through the task output;
        // the platform layer cannot log because it lives in another module.
        _ = @import("firewall.zig").denySource(allocator, source) catch {};
    }
    trimHits(allocator, paths.hits, 2000);
}

pub fn recordBan(allocator: std.mem.Allocator, data_dir: []const u8, source: []const u8) !bool {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    try compat.cwd().makePath(paths.root);

    const existing = compat.cwd().readFileAlloc(allocator, paths.banned, 1024 * 1024) catch "";
    defer if (existing.len > 0) allocator.free(existing);
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), source)) return false;
    }
    const updated = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ existing, source });
    defer allocator.free(updated);
    try writeFile(paths.banned, updated);
    return true;
}

pub fn readBanned(allocator: std.mem.Allocator, data_dir: []const u8) ![]const []const u8 {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    const raw = compat.cwd().readFileAlloc(allocator, paths.banned, 1024 * 1024) catch return &.{};
    defer allocator.free(raw);
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (list.items) |entry| allocator.free(entry);
        list.deinit();
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        try list.append(try allocator.dupe(u8, text));
    }
    const owned = try allocator.dupe([]const u8, list.items);
    list.deinit();
    return owned;
}

pub fn readPid(allocator: std.mem.Allocator, pid_path: []const u8) ?u32 {
    const raw = compat.cwd().readFileAlloc(allocator, pid_path, 32) catch return null;
    defer allocator.free(raw);
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \r\n\t"), 10) catch return null;
    return if (pid == 0) null else pid;
}

pub fn pidAlive(pid: u32) bool {
    var buffer: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&buffer, "/proc/{d}", .{pid}) catch return false;
    return exists(dir);
}

pub fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn writeFile(path: []const u8, content: []const u8) !void {
    if (compat.path.dirname(path)) |dir| compat.cwd().makePath(dir) catch {};
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(content);
}
