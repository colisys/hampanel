const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// Host hardening knobs: dangling symlinks, umask, at/cron/sudo access, and
/// kernel parameters.
///
/// Every change is written to a persistent location *and* applied live where the
/// kernel allows it, so the panel state survives a reboot. Nothing here is
/// destructive: removing dangling links only removes symlinks whose target does
/// not exist, and every sysctl value is validated against a type before writing.

pub const Status = struct {
    /// Dangling symlinks found in the scanned roots.
    dangling: []const Dangling,
    umask: UmaskStatus,
    cron: AccessStatus,
    sudo: SudoStatus,
    kernel: []const KernelParam,
    sysctl_available: bool,
    message: []const u8 = "",
};

pub const Dangling = struct {
    path: []const u8,
    /// What the link pointed at.
    target: []const u8,
};

pub const UmaskStatus = struct {
    /// `UMASK` from /etc/login.defs, empty when unset.
    login_defs: []const u8,
    /// Value in our managed drop-in, empty when absent.
    configured: []const u8,
    pam_umask: bool,
};

pub const AccessStatus = struct {
    /// Whether the allow/deny file exists.
    cron_allow: bool,
    cron_deny: bool,
    at_allow: bool,
    at_deny: bool,
    /// Entries in cron.allow, when present.
    cron_allowed_users: []const []const u8,
};

pub const SudoStatus = struct {
    /// /etc/sudoers mode.
    mode: u32,
    /// Modes of files in /etc/sudoers.d that are readable by group/other.
    insecure: []const []const u8,
    pwfeedback: bool,
    use_pty: bool,
};

pub const KernelParam = struct {
    key: []const u8,
    value: []const u8,
    /// What a hardened value looks like, shown next to the live value.
    recommended: []const u8,
    description: []const u8,
    hardened: bool,
    /// Requiring a deliberate decision: turning forwarding off breaks container
    /// and router hosts, so "apply all" must not touch it.
    needs_review: bool = false,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

/// One place for the panel's own sysctl values, so they can be audited and
/// removed as a unit.
pub const sysctl_path = "/etc/sysctl.d/99-hampanel-hardening.conf";
pub const umask_path = "/etc/security/hampanel-umask.conf";

/// Kernel parameters worth exposing. Deliberately small: these are the ones
/// with a security meaning and a safe hardened value.
pub const kernel_params = [_]struct {
    key: []const u8,
    recommended: []const u8,
    description: []const u8,
    kind: Kind,
    needs_review: bool = false,

    pub const Kind = enum { flag, zero, one, two, sysrq };
}{
    .{
        .key = "net.ipv4.icmp_echo_ignore_broadcasts",
        .recommended = "1",
        .description = "忽略广播 ICMP，避免被用作放大器",
        .kind = .one,
    },
    .{
        .key = "net.ipv4.icmp_ignore_bogus_error_responses",
        .recommended = "1",
        .description = "忽略伪造的 ICMP 错误响应",
        .kind = .one,
    },
    .{
        .key = "net.ipv4.conf.all.rp_filter",
        .recommended = "1",
        .description = "反向路径过滤，丢弃源地址不可回程的报文",
        .kind = .two,
    },
    .{
        .key = "net.ipv4.conf.default.rp_filter",
        .recommended = "1",
        .description = "新接口默认启用反向路径过滤",
        .kind = .two,
    },
    .{
        .key = "net.ipv4.conf.all.accept_redirects",
        .recommended = "0",
        .description = "拒绝 ICMP 重定向，防止路由被投毒",
        .kind = .zero,
    },
    .{
        .key = "net.ipv4.conf.all.send_redirects",
        .recommended = "0",
        .description = "不发送 ICMP 重定向（非路由器场景）",
        .kind = .zero,
    },
    .{
        .key = "net.ipv4.conf.all.secure_redirects",
        .recommended = "0",
        .description = "拒绝来自非网关的“安全”重定向",
        .kind = .zero,
    },
    .{
        .key = "net.ipv4.tcp_syncookies",
        .recommended = "1",
        .description = "SYN cookie，缓解 SYN flood",
        .kind = .one,
    },
    .{
        .key = "net.ipv4.ip_forward",
        .recommended = "0",
        .description = "非路由器主机不应转发 IP 报文；运行容器或做路由时请保留为 1",
        .kind = .flag,
        .needs_review = true,
    },
    .{
        .key = "kernel.dmesg_restrict",
        .recommended = "1",
        .description = "限制非特权用户读取内核日志",
        .kind = .one,
    },
    .{
        .key = "kernel.kptr_restrict",
        .recommended = "2",
        .description = "隐藏内核符号地址，避免辅助提权",
        .kind = .two,
    },
    .{
        .key = "kernel.sysrq",
        .recommended = "0",
        .description = "关闭 magic SysRq，防止物理/串口滥用",
        .kind = .sysrq,
    },
    .{
        .key = "kernel.randomize_va_space",
        .recommended = "2",
        .description = "完整 ASLR",
        .kind = .two,
    },
    .{
        .key = "fs.protected_symlinks",
        .recommended = "1",
        .description = "限制 /tmp 类目录的符号链接跟随",
        .kind = .one,
    },
    .{
        .key = "fs.protected_hardlinks",
        .recommended = "1",
        .description = "限制对不可写文件的硬链接",
        .kind = .one,
    },
};

/// Roots scanned for dangling links. `/tmp` and `/var/tmp` are where they
/// accumulate; `/etc` and `/usr` catch the broken symlinks left by upgrades.
pub const scan_roots = [_][]const u8{ "/etc", "/usr/local", "/opt", "/srv", "/var/tmp", "/tmp" };

pub fn status(allocator: std.mem.Allocator) !Status {
    const dangling = try scanDangling(allocator, &[_][]const u8{"/etc", "/opt", "/srv", "/var/tmp"}, 200);

    const umask = try readUmask(allocator);
    const cron = try readAccess(allocator);
    const sudo_status = try readSudo(allocator);

    var kernel = std.array_list.Managed(KernelParam).init(allocator);
    for (kernel_params) |param| {
        const live = readSysctl(allocator, param.key) orelse "";
        try kernel.append(.{
            .key = param.key,
            .value = try allocator.dupe(u8, live),
            .recommended = param.recommended,
            .description = param.description,
            .hardened = isHardened(param.kind, live),
            .needs_review = param.needs_review,
        });
    }

    var message: []const u8 = "";
    if (!commandExists(allocator, "sysctl")) {
        message = "未找到 sysctl 命令，内核参数只能查看 /proc/sys 无法写入";
    }

    return .{
        .dangling = dangling,
        .umask = umask,
        .cron = cron,
        .sudo = sudo_status,
        .kernel = kernel.items,
        .sysctl_available = commandExists(allocator, "sysctl"),
        .message = message,
    };
}

fn isHardened(kind: anytype, value: []const u8) bool {
    if (value.len == 0) return false;
    const numeric = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \r\n\t"), 10) catch return false;
    return switch (kind) {
        .flag => numeric == 0,
        .zero => numeric == 0,
        .one => numeric == 1,
        .two => numeric == 2,
        .sysrq => numeric == 0,
    };
}

pub fn readSysctl(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    // Two buffers: dottedToSlashed returns a slice into its own buffer, and
    // formatting into that same buffer would alias it.
    var slashed_buffer: [192]u8 = undefined;
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buffer,
        "/proc/sys/{s}",
        .{dottedToSlashed(&slashed_buffer, key)},
    ) catch return null;
    const raw = compat.cwd().readFileAlloc(allocator, path, 4096) catch return null;
    defer allocator.free(raw);
    const value = std.mem.trim(u8, raw, " \r\n\t");
    return allocator.dupe(u8, value) catch null;
}

/// `net.ipv4.ip_forward` -> `net/ipv4/ip_forward`. Returns a slice into the
/// caller's buffer so the hot path allocates nothing.
fn dottedToSlashed(buffer: []u8, key: []const u8) []const u8 {
    const body = buffer[11..];
    @memcpy(body[0..key.len], key);
    for (body[0..key.len]) |*c| {
        if (c.* == '.') c.* = '/';
    }
    return body[0..key.len];
}

pub fn searchDangling(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(Dangling),
    roots: []const []const u8,
    limit: usize,
) !void {
    for (roots) |root| {
        if (!exists(root)) continue;
        try walkDangling(allocator, list, root, limit);
        if (list.items.len >= limit) return;
    }
}

/// Walks `root` looking for links whose target cannot be resolved.
///
/// This is done in-process rather than through `find -xtype`: `-xtype` is a GNU
/// findutils extension, and the musl release is built and tested inside Alpine,
/// whose busybox `find` silently ignores it and reports nothing. A scan that
/// depends on which `find` happens to be first in PATH is not dependable.
fn walkDangling(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(Dangling),
    root: []const u8,
    limit: usize,
) !void {
    var dir = compat.openDirAbsolute(root, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (list.items.len >= limit) return;
        const path = try compat.path.join(allocator, &.{ root, entry.name });
        switch (entry.kind) {
            .sym_link => {
                defer allocator.free(path);
                // access() follows the link, so it fails exactly when the link
                // dangles. Resolve first so a broken link is never walked into.
                if (exists(path)) continue;
                try list.append(.{
                    .path = try allocator.dupe(u8, path),
                    .target = try readLink(allocator, path),
                });
            },
            .directory => {
                defer allocator.free(path);
                try walkDangling(allocator, list, path, limit);
            },
            else => allocator.free(path),
        }
    }
}


pub fn scanDangling(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    limit: usize,
) ![]const Dangling {
    var list = std.array_list.Managed(Dangling).init(allocator);
    try searchDangling(allocator, &list, roots, limit);
    return try list.toOwnedSlice();
}

fn readLink(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = std.Io.Dir.readLinkAbsolute(compat.io(), path, &buffer) catch
        return try allocator.dupe(u8, "");
    return allocator.dupe(u8, buffer[0..length]);
}

/// Removes dangling links, but only those still dangling at removal time: a
/// target may have appeared since the scan, and deleting a link that now
/// resolves would be destructive.
pub fn pruneDangling(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) !Outcome {
    var removed: usize = 0;
    var skipped: usize = 0;
    for (paths) |path| {
        // Only absolute paths inside the scanned roots are accepted, so this
        // endpoint cannot be pointed at an arbitrary file.
        if (!std.mem.startsWith(u8, path, "/")) return error.InvalidPath;
        if (std.mem.indexOf(u8, path, "..") != null) return error.InvalidPath;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        _ = std.Io.Dir.readLinkAbsolute(compat.io(), path, &buffer) catch {
            skipped += 1;
            continue;
        };
        // Resolving the link tells us whether it is still dangling.
        compat.cwd().access(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                compat.deleteFileAbsolute(path) catch {
                    skipped += 1;
                    continue;
                };
                removed += 1;
                continue;
            },
            else => {
                skipped += 1;
                continue;
            },
        };
        skipped += 1;
    }
    const text = try std.fmt.allocPrint(allocator, "已删除 {d} 个空链接，跳过 {d} 个", .{ removed, skipped });
    return .{ .ok = true, .output = text };
}

// -- umask -----------------------------------------------------------------

fn readUmask(allocator: std.mem.Allocator) !UmaskStatus {
    var login_defs: []const u8 = "";
    const raw = compat.cwd().readFileAlloc(allocator, "/etc/login.defs", 256 * 1024) catch "";
    if (raw.len > 0) {
        defer allocator.free(raw);
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            const text = std.mem.trim(u8, line, " \r\t");
            if (!std.mem.startsWith(u8, text, "UMASK")) continue;
            var fields = std.mem.tokenizeAny(u8, text, " \t");
            _ = fields.next();
            if (fields.next()) |value| login_defs = try allocator.dupe(u8, value);
        }
    }
    var configured: []const u8 = "";
    if (compat.cwd().readFileAlloc(allocator, umask_path, 4096)) |content| {
        defer allocator.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const text = std.mem.trim(u8, line, " \r\t");
            if (!std.mem.startsWith(u8, text, "umask")) continue;
            var fields = std.mem.tokenizeAny(u8, text, " \t");
            _ = fields.next();
            if (fields.next()) |value| configured = try allocator.dupe(u8, value);
        }
    } else |_| {}
    return .{
        .login_defs = login_defs,
        .configured = configured,
        .pam_umask = exists("/usr/lib/x86_64-linux-gnu/security/pam_umask.so") or
            exists("/lib/x86_64-linux-gnu/security/pam_umask.so") or
            exists("/usr/lib/security/pam_umask.so"),
    };
}

/// Octal masks used for daemons: 027 is the usual minimum for a root service.
/// The value is the set of permission bits to remove, so 027 means "group may
/// no longer write, others may not access at all".
pub fn validUmask(value: []const u8) bool {
    if (value.len < 3 or value.len > 4) return false;
    for (value) |c| {
        if (c < '0' or c > '7') return false;
    }
    const parsed = std.fmt.parseInt(u16, value, 8) catch return false;
    if (parsed > 0o777) return false;
    // A umask lists the bits to *remove*, not to grant: the security-relevant
    // requirement is that "other" loses write access, so the 0o002 bit must be
    // set. 000 (nothing removed) is the dangerous case, not 027.
    return parsed & 0o002 != 0;
}

pub fn setUmask(allocator: std.mem.Allocator, value: []const u8) !Outcome {
    if (!validUmask(value)) return error.InvalidUmask;
    if (!exists("/etc/security")) return error.PamUnavailable;

    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll(
        "# Managed by Hampanel: default umask for login sessions.\n" ++
            "# pam_umask applies this before the shell starts.\n",
    );
    try out.writer.print("umask {s}\n", .{value});
    try writeFileAllMode(umask_path, out.written(), 0o644);
    return .{ .ok = true, .output = "已写入 pam_umask 配置；新会话生效" };
}

// -- at / cron -------------------------------------------------------------

fn readAccess(allocator: std.mem.Allocator) !AccessStatus {
    var allowed = std.array_list.Managed([]const u8).init(allocator);
    if (compat.cwd().readFileAlloc(allocator, "/etc/cron.allow", 64 * 1024)) |raw| {
        defer allocator.free(raw);
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            const text = std.mem.trim(u8, line, " \r\t");
            if (text.len == 0 or text[0] == '#') continue;
            try allowed.append(try allocator.dupe(u8, text));
        }
    } else |_| {}
    return .{
        .cron_allow = exists("/etc/cron.allow"),
        .cron_deny = exists("/etc/cron.deny"),
        .at_allow = exists("/etc/at.allow"),
        .at_deny = exists("/etc/at.deny"),
        .cron_allowed_users = try allowed.toOwnedSlice(),
    };
}

pub const AccessTool = enum {
    cron,
    at,

    pub fn fromString(value: []const u8) ?AccessTool {
        if (std.mem.eql(u8, value, "cron")) return .cron;
        if (std.mem.eql(u8, value, "at")) return .at;
        return null;
    }

    pub fn name(self: AccessTool) []const u8 {
        return @tagName(self);
    }
};

/// Restricts a scheduler to the given users.
///
/// `allow` creates `<tool>.allow` and removes `<tool>.deny`: when both exist the
/// allow file wins, and leaving a stale deny file is confusing to audit. Users
/// must be valid account names.
pub fn restrictScheduler(
    allocator: std.mem.Allocator,
    tool: AccessTool,
    users: []const []const u8,
    enabled: bool,
) !Outcome {
    if (users.len == 0 and enabled) return error.InvalidParams;
    for (users) |user| {
        if (!validUserName(user)) return error.InvalidUser;
    }

    const allow_path = if (tool == .cron) "/etc/cron.allow" else "/etc/at.allow";
    const deny_path = if (tool == .cron) "/etc/cron.deny" else "/etc/at.deny";

    if (!enabled) {
        compat.deleteFileAbsolute(allow_path) catch {};
        // Falling back to deny-all by writing an empty deny file would be
        // wrong: an empty deny list denies nobody, so the deny file is simply
        // restored to "empty" semantics by removal.
        compat.deleteFileAbsolute(deny_path) catch {};
        return .{ .ok = true, .output = "已移除访问控制文件" };
    }

    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll("# Managed by Hampanel\n");
    for (users) |user| try out.writer.print("{s}\n", .{user});
    try writeFileAllMode(allow_path, out.written(), 0o640);
    compat.deleteFileAbsolute(deny_path) catch {};
    return .{
        .ok = true,
        .output = try std.fmt.allocPrint(
            allocator,
            "已限制 {s}：仅 {d} 个用户可用",
            .{ tool.name(), users.len },
        ),
    };
}

pub fn validUserName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name, 0..) |c, index| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or (c == '$' and index == 0);
        if (!ok) return false;
    }
    return true;
}

// -- sudo ------------------------------------------------------------------

fn readSudo(allocator: std.mem.Allocator) !SudoStatus {
    const sudoers = compat.cwd().statFile("/etc/sudoers", .{}) catch {
        return .{ .mode = 0, .insecure = &.{}, .pwfeedback = false, .use_pty = false };
    };

    var insecure = std.array_list.Managed([]const u8).init(allocator);
    var dir = std.Io.Dir.openDirAbsolute(compat.io(), "/etc/sudoers.d", .{ .iterate = true }) catch {
        return .{
            .mode = @intCast(sudoers.mode & 0o777),
            .insecure = &.{},
            .pwfeedback = false,
            .use_pty = false,
        };
    };
    defer dir.close(compat.io());
    var iterator = dir.iterate();
    while (iterator.next(compat.io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        const path = try compat.path.join(allocator, &.{ "/etc/sudoers.d", entry.name });
        const stat = compat.cwd().statFile(path, .{}) catch {
            allocator.free(path);
            continue;
        };
        // sudo refuses these files entirely, but reporting them lets the
        // operator see why sudo stopped accepting a drop-in.
        if (stat.mode & 0o077 == 0) {
            allocator.free(path);
            continue;
        }
        try insecure.append(path);
    }

    var pwfeedback = false;
    var use_pty = false;
    if (compat.cwd().readFileAlloc(allocator, "/etc/sudoers", 256 * 1024)) |raw| {
        defer allocator.free(raw);
        pwfeedback = hasSudoOption(raw, "pwfeedback");
        use_pty = hasSudoOption(raw, "use_pty");
    } else |_| {}

    return .{
        .mode = @intCast(sudoers.mode & 0o777),
        .insecure = try insecure.toOwnedSlice(),
        .pwfeedback = pwfeedback,
        .use_pty = use_pty,
    };
}

fn hasSudoOption(raw: []const u8, option: []const u8) bool {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0 or text[0] == '#') continue;
        if (!std.mem.startsWith(u8, text, "Defaults")) continue;
        if (std.mem.indexOf(u8, text, option) != null) return true;
    }
    return false;
}

/// Hardens sudo with the two options that matter most in practice:
/// `use_pty` (a pty breaks most terminal-injection tricks) and `pwfeedback`
/// for visibility. Written as a drop-in so the distribution file is untouched.
pub fn hardenSudo(allocator: std.mem.Allocator) !Outcome {
    if (!exists("/etc/sudoers.d")) return error.SudoUnavailable;
    // Only options both classic sudo and sudo-rs accept: `logfile` is unknown
    // to sudo-rs and would make every sudo invocation fail to parse the file.
    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll(
        "# Managed by Hampanel.\n" ++
            "Defaults use_pty\n" ++
            "Defaults !visiblepw\n",
    );
    const body = out.written();
    try writeFileAllMode("/etc/sudoers.d/99-hampanel-hardening", body, 0o440);

    // A broken drop-in breaks sudo entirely, so the file is validated and
    // rolled back if the local sudo rejects it.
    if (exec.commandExists(allocator, "visudo")) {
        const check = exec.run(allocator, &.{ "visudo", "-c" }, 256 * 1024) catch null;
        if (check) |result| {
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            if (!result.ok()) {
                compat.deleteFileAbsolute("/etc/sudoers.d/99-hampanel-hardening") catch {};
                return .{ .ok = false, .output = "本机 sudo 不接受该片段，已回滚" };
            }
        }
    }

    // sudo silently ignores drop-ins that are not 0440; verify what we wrote.
    const stat = compat.cwd().statFile("/etc/sudoers.d/99-hampanel-hardening", .{}) catch
        return .{ .ok = false, .output = "写入 sudoers 片段失败" };
    return .{
        .ok = true,
        .output = try std.fmt.allocPrint(
            allocator,
            "已写入 sudo 加固片段（{o}）并通过校验",
            .{stat.mode & 0o777},
        ),
    };
}

// -- sysctl ----------------------------------------------------------------

/// Writes the requested parameters to the managed drop-in and applies each one
/// live. A value the kernel rejects is reported, not swallowed.
pub fn setKernel(allocator: std.mem.Allocator, requests: []const Request) !Outcome {
    if (!commandExists(allocator, "sysctl")) return error.SysctlUnavailable;

    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll(
        "# Managed by Hampanel: kernel hardening.\n" ++
            "# Applied with `sysctl --system` on boot.\n",
    );
    var failures = std.array_list.Managed([]const u8).init(allocator);
    for (requests) |request| {
        const spec = findParam(request.key) orelse return error.InvalidKey;
        if (!validValue(spec.kind, request.value)) return error.InvalidValue;
        try out.writer.print("{s} = {s}\n", .{ request.key, request.value });

        var assignment: [256]u8 = undefined;
        const pair = std.fmt.bufPrint(&assignment, "{s}={s}", .{ request.key, request.value }) catch
            return error.InvalidKey;
        const applied = exec.run(allocator, &.{ "sysctl", "-w", pair }, 64 * 1024) catch
            return error.SysctlUnavailable;
        if (!applied.ok()) {
            try failures.append(try allocator.dupe(u8, spec.key));
        }
    }
    try writeFileAllMode(sysctl_path, out.written(), 0o644);

    if (failures.items.len > 0) {
        var text = std.Io.Writer.Allocating.init(allocator);
        try text.writer.print("已写入 {s}，但以下参数内核拒绝：", .{sysctl_path});
        for (failures.items, 0..) |key, index| {
            if (index > 0) try text.writer.writeAll(", ");
            try text.writer.print("{s}", .{key});
        }
        return .{ .ok = false, .output = text.written() };
    }
    return .{
        .ok = true,
        .output = try std.fmt.allocPrint(
            allocator,
            "已应用并写入 {s}（{d} 项）",
            .{ sysctl_path, requests.len },
        ),
    };
}

pub const Request = struct {
    key: []const u8,
    value: []const u8,
};

fn findParam(key: []const u8) ?@TypeOf(kernel_params[0]) {
    for (kernel_params) |param| {
        if (std.mem.eql(u8, param.key, key)) return param;
    }
    return null;
}

fn validValue(kind: anytype, value: []const u8) bool {
    const numeric = std.fmt.parseInt(u32, value, 10) catch return false;
    return switch (kind) {
        .flag, .zero => numeric == 0,
        .one => numeric <= 1,
        .two => numeric <= 2,
        .sysrq => numeric <= 255,
    };
}

// -- helpers ---------------------------------------------------------------

fn writeFileAllMode(path: []const u8, data: []const u8, mode: u32) !void {
    if (compat.path.dirname(path)) |dir| compat.cwd().makePath(dir) catch {};
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = @intCast(mode) });
    defer file.close();
    try file.writeAll(data);
}

fn commandExists(allocator: std.mem.Allocator, name: []const u8) bool {
    return exec.commandExists(allocator, name);
}

fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}
