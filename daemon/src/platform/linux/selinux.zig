const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;

/// SELinux policy control.
///
/// Everything is probed: a host running AppArmor has no `/sys/fs/selinux`, so
/// the panel must say "not present" rather than show switches that cannot work.
/// The persistent mode lives in `/etc/selinux/config` and only takes effect on
/// reboot; the live mode is switched through `setenforce`.
pub const Status = struct {
    /// `/sys/fs/selinux` exists: the kernel actually has SELinux enabled.
    present: bool,
    /// Live mode from `/sys/fs/selinux/enforce`; null when SELinux is absent.
    enforcing: ?bool,
    /// Mode recorded in `/etc/selinux/config` (enforcing/permissive/disabled).
    configured: []const u8,
    /// Policy name from `SELINUXTYPE=`.
    policy: []const u8,
    /// `setenforce` / `getsebool` / `setsebool` resolved from PATH.
    tooling: bool,
    /// `semanage` resolved from PATH; needed for contexts and ports.
    semanage: bool,
    booleans: []const Boolean,
    /// Local file-context customisations (semanage fcontext -C).
    contexts: []const Context,
    /// Port type assignments (semanage port -l).
    ports: []const PortType,
    /// Policy modules (semodule -l), with version.
    modules: []const Module,
    /// Recent AVC denials from the audit log.
    denials: []const Denial,
    /// Whether the policy store could be read; a fresh host has none.
    policy_store: bool,
    /// Whether the filesystem was relabelled at least once. Enabling SELinux on
    /// a host that never ran restorecon leaves every process in kernel_t, so
    /// switching to enforcing there can make the machine unbootable.
    relabelled: bool,
    /// How many of the panel's own paths already carry a Hampanel context rule.
    managed_paths: u32,
    /// How many paths the panel wants covered, so the UI can show progress
    /// instead of a bare count.
    managed_total: u32,
    /// Reboot/halt are refused while this is false (SELinux present but the
    /// filesystem still needs relabelling).
    reboot_allowed: bool,
    message: []const u8 = "",
};

pub const Context = struct {
    /// Path expression the rule matches.
    path: []const u8,
    /// SELinux type (e.g. httpd_sys_content_t).
    kind: []const u8,
    /// File type class: file, directory, all, symlink...
    file_type: []const u8,
};

pub const PortType = struct {
    port: u16,
    protocol: []const u8,
    kind: []const u8,
};

pub const Module = struct {
    name: []const u8,
    version: []const u8,
};

pub const Denial = struct {
    /// Audit timestamp as printed by ausearch.
    at: []const u8,
    source: []const u8,
    target: []const u8,
    object_type: []const u8,
    tclass: []const u8,
    permission: []const u8,
    path: []const u8,
};

pub const Boolean = struct {
    name: []const u8,
    enabled: bool,
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
    /// Set when the change only applies after a reboot.
    reboot_required: bool = false,
};

pub const config_path = "/etc/selinux/config";

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    const present = exists("/sys/fs/selinux");
    const tooling = exec.commandExists(allocator, "setenforce") and
        exec.commandExists(allocator, "getsebool") and
        exec.commandExists(allocator, "setsebool");

    const configured = try readConfigured(allocator);
    const policy = try readPolicy(allocator);
    const enforcing = readEnforcing(allocator);

    var booleans: []const Boolean = &.{};
    if (present and tooling) booleans = try listBooleans(allocator);

    const semanage = exec.commandExists(allocator, "semanage");

    // Policy data only exists when a store is present; a fresh host answers
    // with "no SELinux policy is managed here", which is not an error.
    var contexts: []const Context = &.{};
    var ports: []const PortType = &.{};
    var modules: []const Module = &.{};
    var policy_store = false;
    if (present and semanage) {
        contexts = try listContexts(allocator);
        ports = try listPorts(allocator);
        modules = try listModules(allocator);
        policy_store = contexts.len > 0 or ports.len > 0 or modules.len > 0;
    }
    const denials = try listDenials(allocator, present);

    var message: []const u8 = "";
    if (!present) {
        message = "当前主机未启用 SELinux（可能使用 AppArmor）；不会展示无法生效的策略开关。";
    } else if (!tooling) {
        message = "未安装 setenforce/getsebool/setsebool，只能查看状态，无法修改策略。";
    } else if (!semanage) {
        message = "未安装 semanage，无法查看或编辑文件上下文与端口标签。";
    } else if (!policy_store) {
        message = "可访问策略存储，但当前策略没有任何本地定制。";
    }

    return .{
        .present = present,
        .enforcing = enforcing,
        .configured = configured,
        .policy = policy,
        .tooling = tooling,
        .semanage = semanage,
        .booleans = booleans,
        .contexts = contexts,
        .ports = ports,
        .modules = modules,
        .denials = denials,
        .policy_store = policy_store,
        .relabelled = (!present) or relabelMarker(),
        .managed_paths = managedPathCount(allocator, data_dir),
        .managed_total = managedPathTotal(allocator, data_dir, present and semanage),
        .reboot_allowed = if (present) relabelMarker() else true,
        .message = message,
    };
}

/// `semanage fcontext -C -l` lists only local customisations. (-n alone is not
/// a listing flag; with -C it is rejected as "one of the arguments
/// -a/-d/-m/-l/-E/-D is required", which is what made the list look empty.)
///   /var/www(/.*)?  all files  system_u:object_r:httpd_sys_content_t:s0
pub fn parseContexts(allocator: std.mem.Allocator, output: []const u8) ![]const Context {
    var list = std.array_list.Managed(Context).init(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0 or std.mem.startsWith(u8, text, "#")) continue;
        // Layout per line: "<path> <fclass> <context>", where fclass itself may
        // be two words ("all files", "regular file"). Parsing therefore starts
        // from the end: the context is the final field, and the class is
        // whatever sits between the path and it.
        const spec_start = std.mem.lastIndexOfScalar(u8, text, ' ') orelse continue;
        const spec = std.mem.trim(u8, text[spec_start + 1 ..], " \t");
        if (std.mem.indexOf(u8, spec, ":") == null) continue;
        const kind = contextType(spec) orelse continue;
        if (kind.len == 0) continue;

        const head = std.mem.trim(u8, text[0..spec_start], " \t");
        // The path is the first token; the rest is the file class.
        var columns = std.mem.tokenizeAny(u8, head, " \t");
        const path = columns.next() orelse continue;
        const file_type = std.mem.trim(u8, columns.rest(), " \t");
        try list.append(.{
            .path = try allocator.dupe(u8, path),
            .kind = try allocator.dupe(u8, kind),
            .file_type = try allocator.dupe(u8, if (file_type.len == 0) "all files" else file_type),
        });
    }
    return list.toOwnedSlice();
}

/// SELinux context spec: `user:role:type:level`, where level is optional.
/// The type is therefore the third field, not the last — trailing `:s0`
/// sensitivity labels are common on real policies.
fn contextType(spec: []const u8) ?[]const u8 {
    var fields: [4][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= spec.len) : (index += 1) {
        if (index == spec.len or spec[index] == ':') {
            if (count >= fields.len) return null;
            fields[count] = spec[start..index];
            count += 1;
            start = index + 1;
        }
    }
    if (count < 3) return null;
    return fields[2];
}

/// `semanage port -l`:
///   http_port_t      tcp   80, 443, 488, 8008, 8009
pub fn parsePorts(allocator: std.mem.Allocator, output: []const u8) ![]const PortType {
    var list = std.array_list.Managed(PortType).init(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0 or std.mem.startsWith(u8, text, "#")) continue;
        if (std.mem.startsWith(u8, text, "SELinux")) continue;
        var columns = std.mem.tokenizeAny(u8, text, " \t");
        const kind = columns.next() orelse continue;
        const protocol = columns.next() orelse continue;
        if (!std.mem.eql(u8, protocol, "tcp") and !std.mem.eql(u8, protocol, "udp") and
            !std.mem.eql(u8, protocol, "sctp") and !std.mem.eql(u8, protocol, "dccp")) continue;
        const rest = std.mem.trim(u8, columns.rest(), " \r\t");
        var ports = std.mem.splitScalar(u8, rest, ',');
        while (ports.next()) |entry| {
            const value = std.mem.trim(u8, entry, " \t");
            if (value.len == 0) continue;
            const port = std.fmt.parseInt(u16, value, 10) catch continue;
            try list.append(.{
                .port = port,
                .protocol = try allocator.dupe(u8, protocol),
                .kind = try allocator.dupe(u8, kind),
            });
        }
    }
    return list.toOwnedSlice();
}

/// `semodule -l`:
///   container  1.2.3
///   mypolicy   1.0
pub fn parseModules(allocator: std.mem.Allocator, output: []const u8) ![]const Module {
    var list = std.array_list.Managed(Module).init(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        var columns = std.mem.tokenizeAny(u8, text, " \t");
        const name = columns.next() orelse continue;
        if (!validModuleName(name)) continue;
        const version = columns.next() orelse "";
        try list.append(.{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
        });
    }
    return list.toOwnedSlice();
}

/// Adds or removes a port type. The port range is validated so a typo cannot
/// reassign a service port by accident.
pub fn setPort(
    allocator: std.mem.Allocator,
    entry: PortType,
    remove: bool,
) !Outcome {
    if (entry.port == 0) return error.InvalidPort;
    if (!validTypeName(entry.kind)) return error.InvalidType;
    if (!std.mem.eql(u8, entry.protocol, "tcp") and !std.mem.eql(u8, entry.protocol, "udp") and
        !std.mem.eql(u8, entry.protocol, "sctp") and !std.mem.eql(u8, entry.protocol, "dccp")) {
        return error.InvalidProtocol;
    }
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "semanage")) return error.ToolingUnavailable;
    var port_buffer: [8]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buffer, "{d}", .{entry.port}) catch
        return error.InvalidPort;
    const result = exec.run(allocator, &.{
        "semanage", "port", if (remove) "-d" else "-a",
        "-t", entry.kind,
        "-p", entry.protocol,
        port_text,
    }, 1024 * 1024) catch return error.ToolingUnavailable;
    const text = try allocator.dupe(u8, textOf(result));
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return .{ .ok = result.ok(), .output = text };
}

pub fn validModuleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') return false;
    }
    return true;
}

/// AVC denials as printed by `ausearch -if /var/log/audit/audit.log -m AVC,USER_AVC`.
/// Only the fields the
/// panel shows are extracted; the raw line stays in the log for detail.
pub fn parseDenials(allocator: std.mem.Allocator, output: []const u8) ![]const Denial {
    var list = std.array_list.Managed(Denial).init(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    var current: ?Denial = null;
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) {
            if (current) |entry| try list.append(entry);
            current = null;
            continue;
        }
        if (std.mem.startsWith(u8, text, "----")) {
            if (current) |entry| try list.append(entry);
            current = null;
            continue;
        }
        if (std.mem.startsWith(u8, text, "type=AVC") or std.mem.startsWith(u8, text, "type=USER_AVC")) {
            if (current) |entry| try list.append(entry);
            current = .{
                .at = try allocator.dupe(u8, auditStamp(text) orelse ""),
                .source = try allocator.dupe(u8, field(text, "scontext=") orelse ""),
                .target = try allocator.dupe(u8, field(text, "tcontext=") orelse ""),
                .object_type = try allocator.dupe(u8, field(text, "tclass=") orelse ""),
                .tclass = try allocator.dupe(u8, field(text, "tclass=") orelse ""),
                .permission = try allocator.dupe(u8, permissionOf(text) orelse ""),
                // `path=` may sit on the same line as the denial.
                .path = try allocator.dupe(u8, quotedField(text, "path=") orelse ""),
            };
            continue;
        }
        if (current) |*entry| {
            if (std.mem.startsWith(u8, text, "path=") and entry.path.len == 0) {
                entry.path = try allocator.dupe(u8, text[5..]);
            }
        }
    }
    if (current) |entry| try list.append(entry);
    return list.toOwnedSlice();
}

fn auditStamp(text: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, text, "audit(") orelse return null) + 6;
    const end = std.mem.indexOfPos(u8, text, start, ")") orelse return null;
    return text[start..end];
}

/// Reads a quoted value such as `path="/run/app.sock"`.
fn quotedField(text: []const u8, key: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, text, key) orelse return null) + key.len;
    if (start >= text.len) return null;
    const quote: u8 = if (text[start] == '"') '"' else ' ';
    if (quote == '"') {
        const end = std.mem.indexOfPos(u8, text, start + 1, "\"") orelse return null;
        return text[start + 1 .. end];
    }
    var end = start;
    while (end < text.len and text[end] != ' ' and text[end] != '\t') : (end += 1) {}
    return text[start..end];
}

fn field(text: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, key) orelse return null;
    const value_start = start + key.len;
    var end = value_start;
    while (end < text.len and text[end] != ' ' and text[end] != '\t' and text[end] != '"') : (end += 1) {}
    return text[value_start..end];
}

fn permissionOf(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, "{ ") orelse return null;
    const end = std.mem.indexOfPos(u8, text, start, " }") orelse return null;
    return text[start + 2 .. end];
}

fn listContexts(allocator: std.mem.Allocator) ![]const Context {
    const result = exec.run(allocator, &.{ "semanage", "fcontext", "-C", "-l" }, 2 * 1024 * 1024) catch
        return &.{};
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (!result.ok()) return &.{};
    if (std.mem.indexOf(u8, result.stdout, "ValueError") != null or
        std.mem.indexOf(u8, result.stderr, "ValueError") != null) return &.{};
    return parseContexts(allocator, result.stdout);
}

fn listPorts(allocator: std.mem.Allocator) ![]const PortType {
    const result = exec.run(allocator, &.{ "semanage", "port", "-l", "-n" }, 2 * 1024 * 1024) catch
        return &.{};
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (!result.ok()) return &.{};
    return parsePorts(allocator, result.stdout);
}

fn listModules(allocator: std.mem.Allocator) ![]const Module {
    const result = exec.run(allocator, &.{ "semodule", "-l" }, 2 * 1024 * 1024) catch
        return &.{};
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (!result.ok()) return &.{};
    return parseModules(allocator, result.stdout);
}

fn listDenials(allocator: std.mem.Allocator, present: bool) ![]const Denial {
    if (!present) return &.{};
    // -ts recent relies on ausearch resolving the configured log file itself,
    // which silently yields "<no matches>" on hosts where that path is not what
    // ausearch expects.  Pointing it at the file directly is what actually works.
    const result = exec.run(
        allocator,
        &.{ "ausearch", "-if", "/var/log/audit/audit.log", "-m", "AVC,USER_AVC" },
        4 * 1024 * 1024,
    ) catch return &.{};
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (!result.ok()) return &.{};
    return parseDenials(allocator, result.stdout);
}

/// A path Hampanel needs labelled before enforcing mode is safe to enter.
///
/// Everything here is read or written by the daemon and by the containers it
/// manages. If these stay `unlabeled_t`/`var_t` while SELinux is enforcing, the
/// daemon itself is denied access and the machine may not boot.
pub const ManagedPath = struct {
    /// The real path.
    path: []const u8,
    /// Context it should carry.
    kind: []const u8,
    /// Human-readable reason shown in the UI.
    why: []const u8,
};

pub fn managedPaths(allocator: std.mem.Allocator, data_dir: []const u8) ![]const ManagedPath {
    var list = std.array_list.Managed(ManagedPath).init(allocator);
    const pairs = .{
        .{ "/etc/hampanel(/.*)?", "etc_t", "面板配置、证书与注册信息" },
        .{ "/var/lib/hampanel(/.*)?", "var_lib_t", "面板数据、任务队列与日志" },
        .{ "/var/log/hampanel(/.*)?", "var_log_t", "面板日志" },
        .{ "/run/hampanel(/.*)?", "var_run_t", "面板运行状态" },
        .{ "/usr/local/bin/hampaneld", "bin_t", "面板守护进程" },
        .{ "/etc/systemd/system/hampanel*.service", "systemd_unit_file_t", "面板的 systemd 单元" },
        .{ "/etc/systemd/system/hampaneld*.service", "systemd_unit_file_t", "面板的 systemd 单元" },
        // Container storage: without these labels Docker/Podman are denied their
        // own graph root once enforcing, and every managed container breaks.
        .{ "/var/lib/docker(/.*)?", "container_var_lib_t", "Docker 存储（面板管理的容器）" },
        .{ "/var/lib/containers(/.*)?", "container_var_lib_t", "Podman 存储（面板管理的容器）" },
        .{ "/etc/containers(/.*)?", "container_config_t", "Podman 配置与 registries" },
        .{ "/etc/docker(/.*)?", "etc_t", "Docker 配置" },
        .{ "/run/containers(/.*)?", "container_var_run_t", "容器运行时状态" },
        .{ "/run/docker.sock", "container_var_run_t", "Docker 套接字" },
        .{ "/run/podman(/.*)?", "container_var_run_t", "Podman 套接字" },
    };
    inline for (pairs) |pair| {
        try list.append(.{ .path = pair[0], .kind = pair[1], .why = pair[2] });
    }
    // The data dir may have been relocated; label it too.
    if (!std.mem.startsWith(u8, data_dir, "/var/lib/hampanel")) {
        try list.append(.{
            .path = try std.fmt.allocPrint(allocator, "{s}(/.*)?", .{data_dir}),
            .kind = "var_lib_t",
            .why = "面板数据（自定义路径）",
        });
    }
    return list.toOwnedSlice();
}

/// True once the host has completed at least one full relabel.
///
/// `/.autorelabel` is created by the panel (and by the distro) before a
/// relabel run and removed when it completes. Its absence alone proves
/// nothing, so the marker file the panel writes afterwards is the real signal.
pub fn relabelMarker() bool {
    return exists("/var/lib/selinux/.hampanel-relabelled") or
        exists("/etc/selinux/.hampanel-relabelled");
}

fn managedPathTotal(allocator: std.mem.Allocator, data_dir: []const u8, probe: bool) u32 {
    if (!probe) return 0;
    const paths = managedPaths(allocator, data_dir) catch return 0;
    defer allocator.free(paths);
    return @intCast(paths.len);
}

fn managedPathCount(allocator: std.mem.Allocator, data_dir: []const u8) u32 {
    const paths = managedPaths(allocator, data_dir) catch return 0;
    defer allocator.free(paths);
    var count: u32 = 0;
    for (paths) |entry| {
        const base = basePath(entry.path);
        if (hasContextRule(allocator, base, entry.kind)) count += 1;
    }
    return count;
}

/// Whether `semanage fcontext -l` already maps this path to this type.
fn hasContextRule(allocator: std.mem.Allocator, path: []const u8, kind: []const u8) bool {
    const result = exec.run(allocator, &.{ "semanage", "fcontext", "-C", "-l" }, 2 * 1024 * 1024) catch
        return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (!result.ok()) return false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, path) == null) continue;
        if (std.mem.indexOf(u8, line, kind) != null) return true;
    }
    return false;
}

/// Prepares a host for enforcing mode: writes the panel's context rules,
/// applies them, records the relabel marker and does a full filesystem relabel.
///
/// This is deliberately a separate, explicit step. Switching to enforcing on a
/// host that was never relabelled is how machines stop booting: init is
/// `unlabeled_t`, every process inherits `kernel_t`, and the policy then denies
/// the very accesses the boot needs.
/// Units whose start/stop reboots or powers off the host.
///
/// Restarting `reboot.target` (or the matching systemd-*.service) takes the
/// machine down just as surely as a reboot button would, so these have to be
/// recognised by name rather than trusted to the caller.
pub fn isRebootUnit(unit: []const u8) bool {
    const names = [_][]const u8{
        "reboot.target",             "poweroff.target",
        "halt.target",               "kexec.target",
        "systemd-reboot.service",    "systemd-poweroff.service",
        "systemd-halt.service",      "systemd-kexec.service",
        "reboot.service",            "poweroff.service",
        "halt.service",              "kexec.service",
    };
    for (names) |name| {
        if (std.mem.eql(u8, unit, name)) return true;
    }
    return false;
}

/// Whether a reboot is safe right now.
///
/// Before the filesystem has been relabelled, the machine comes back with init
/// unlabeled_t and every process in kernel_t, which the policy then denies —
/// that is exactly the unbootable state this guard exists to prevent. Hosts
/// without SELinux, and hosts that have completed initialization, are free to
/// reboot.
pub fn rebootAllowed(allocator: std.mem.Allocator) bool {
    if (!exists("/sys/fs/selinux")) return true;
    // `semanage` missing means we cannot reason about labels at all; treat the
    // host as unmanaged rather than locking its operator out of rebooting.
    if (!exec.commandExists(allocator, "semanage")) return true;
    return relabelMarker();
}

pub fn initialize(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "semanage")) return error.ToolingUnavailable;
    if (!exec.commandExists(allocator, "restorecon")) return error.ToolingUnavailable;

    const paths = try managedPaths(allocator, data_dir);
    var report = std.array_list.Managed(u8).init(allocator);

    // 1. Write the context rules. Existing identical rules are left alone so a
    //    second run is not an error.
    var written: u32 = 0;
    for (paths) |entry| {
        if (hasContextRule(allocator, basePath(entry.path), entry.kind)) continue;
        const result = exec.run(allocator, &.{
            "semanage", "fcontext", "-a", "-t", entry.kind, "-f", "a", entry.path,
        }, 1024 * 1024) catch continue;
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        if (result.ok()) written += 1;
    }
    try report.appendSlice(try std.fmt.allocPrint(allocator, "已写入 {d} 条文件上下文规则（共 {d} 项）。\n", .{ written, paths.len }));

    // 2. Relabel. Container storage is excluded on purpose: overlay layers hold
    //    an entire guest filesystem, and `restorecon -R /` stamps the *host*
    //    policy onto guest files. In practice a busybox inside an image came out
    //    as ntp_drift_t and the container could no longer execute it. Container
    //    runtimes label their own storage; the host must not.
    try report.appendSlice(
        "开始重打标签（restorecon -R /，跳过容器存储）。首次执行可能需要数分钟。\n",
    );
    const relabel = exec.run(allocator, &.{
        "restorecon", "-R", "-e", "/var/lib/docker", "-e", "/var/lib/containers", "-e", "/run/containers", "/",
    }, 8 * 1024 * 1024) catch return error.ToolingUnavailable;
    // textOf borrows from the result buffers, so copy before releasing them.
    const relabel_ok = relabel.ok();
    const relabel_text = try allocator.dupe(u8, textOf(relabel));
    defer allocator.free(relabel_text);
    allocator.free(relabel.stdout);
    allocator.free(relabel.stderr);
    if (relabel_text.len > 0) {
        try report.appendSlice(relabel_text);
        try report.appendSlice("\n");
    }

    if (!relabel_ok) {
        try report.appendSlice("重打标签未成功完成，已保留未就绪状态；请修复后重试。\n");
        return .{ .ok = false, .output = try report.toOwnedSlice() };
    }

    // 3. Record completion. Written under /var/lib/selinux so it survives a
    //    reboot alongside the policy it certifies.
    try compat.cwd().makePath("/var/lib/selinux");
    var marker = compat.createFileAbsolute("/var/lib/selinux/.hampanel-relabelled", .{
        .truncate = true,
        .mode = 0o644,
    }) catch null;
    if (marker) |*file| {
        file.writeAll("hampanel relabel complete\n") catch {};
        file.close();
    }
    try report.appendSlice("重打标签完成。可以安全切换到 enforcing。\n");
    return .{ .ok = true, .output = try report.toOwnedSlice() };
}

/// Switches the live mode. `disabled` is not a live operation: SELinux can only
/// be turned off through the config file plus a reboot.
pub fn setMode(allocator: std.mem.Allocator, mode: []const u8) !Outcome {
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "setenforce")) return error.ToolingUnavailable;

    if (std.mem.eql(u8, mode, "enforcing")) {
        // Refuse to enter enforcing before the filesystem has been relabelled.
        // On an unrelabelled host init is unlabeled_t and every process falls
        // back to kernel_t, so the policy denies boot-time access and the
        // machine can hang or fail to start. `initialize` is the way out.
        if (!relabelMarker()) return error.RelabelRequired;
        const result = exec.run(allocator, &.{ "setenforce", "1" }, 64 * 1024) catch
            return error.ToolingUnavailable;
        return .{ .ok = result.ok(), .output = textOf(result) };
    }
    if (std.mem.eql(u8, mode, "permissive")) {
        const result = exec.run(allocator, &.{ "setenforce", "0" }, 64 * 1024) catch
            return error.ToolingUnavailable;
        return .{ .ok = result.ok(), .output = textOf(result) };
    }
    if (std.mem.eql(u8, mode, "disabled")) {
        try writeConfigured(allocator, "disabled");
        return .{
            .ok = true,
            .output = "已写入 /etc/selinux/config；禁用 SELinux 需要重启主机后才生效",
            .reboot_required = true,
        };
    }
    return error.InvalidMode;
}

pub fn setBoolean(allocator: std.mem.Allocator, name: []const u8, enabled: bool) !Outcome {
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "setsebool")) return error.ToolingUnavailable;
    if (!validBooleanName(name)) return error.InvalidBoolean;

    // Only names the policy actually declares may be written: anything else is
    // either a typo or an attempt to reach setsebool with unexpected input.
    const known = try listBooleans(allocator);
    defer {
        for (known) |entry| allocator.free(entry.name);
        allocator.free(known);
    }
    var found = false;
    for (known) |entry| {
        if (std.mem.eql(u8, entry.name, name)) found = true;
    }
    if (!found) return error.InvalidBoolean;

    const result = exec.run(
        allocator,
        &.{ "setsebool", "-P", name, if (enabled) "on" else "off" },
        256 * 1024,
    ) catch return error.ToolingUnavailable;
    return .{ .ok = result.ok(), .output = textOf(result) };
}

/// Adds or removes a file-context rule, then applies it with `restorecon`.
///
/// The path expression and type are validated rather than passed through: both
/// end up as argv entries, and a bad type would silently break labelling for
/// the whole subtree.
pub fn setContext(
    allocator: std.mem.Allocator,
    spec: Context,
    remove: bool,
) !Outcome {
    // Input is validated first so a malformed request is reported as such even
    // on a host without SELinux, instead of hiding behind NotPresent.
    if (!validContextPath(spec.path)) return error.InvalidPath;
    if (!validTypeName(spec.kind)) return error.InvalidType;
    const ftype = ftypeFlag(spec.file_type) orelse return error.InvalidType;
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "semanage")) return error.ToolingUnavailable;

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "semanage", "fcontext", if (remove) "-d" else "-a", "-t" });
    try argv.append(spec.kind);
    try argv.append("-f");
    try argv.append(ftype);
    try argv.append(spec.path);

    const result = exec.run(allocator, argv.items, 1024 * 1024) catch
        return error.ToolingUnavailable;
    const output = try allocator.dupe(u8, textOf(result));
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    if (!result.ok()) return .{ .ok = false, .output = output };

    // semanage only records the rule; restorecon is what relabels the tree.
    const relabel = exec.run(allocator, &.{ "restorecon", "-R", basePath(spec.path) }, 1024 * 1024) catch
        return .{ .ok = true, .output = output };
    const relabel_text = try allocator.dupe(u8, textOf(relabel));
    allocator.free(relabel.stdout);
    allocator.free(relabel.stderr);
    const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{
        output,
        if (relabel.ok()) "" else relabel_text,
    });
    allocator.free(output);
    allocator.free(relabel_text);
    return .{ .ok = true, .output = merged };
}

/// `/var/www(/.*)?` labels `/var/www`; the regex suffix is dropped for
/// restorecon, which cannot take an expression.
fn basePath(expression: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, expression, "([") orelse expression.len;
    var trimmed = expression[0..cut];
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    return trimmed;
}

pub fn validContextPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 512) return false;
    if (!std.mem.startsWith(u8, path, "/")) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    // Metacharacters that would change the meaning of the expression instead of
    // describing a path.
    return std.mem.indexOfAny(u8, path, " |;&$`\n\r") == null;
}

/// Maps a file-context spec's file type to the single-letter category that
/// `semanage fcontext -f` actually accepts. `semanage fcontext -l` prints the
/// verbose names ("all files", "regular file"), but -f rejects anything that is
/// not one of a/f/d/c/b/s/l/p, so the two cannot be passed through verbatim.
pub fn ftypeFlag(file_type: []const u8) ?[]const u8 {
    if (file_type.len == 1 and std.mem.indexOfScalar(u8, "afdcbslp", file_type[0]) != null) {
        return file_type;
    }
    const table = .{
        .{ "all", "a" },      .{ "all files", "a" },
        .{ "file", "f" },     .{ "regular file", "f" },
        .{ "directory", "d" }, .{ "dir", "d" },
        .{ "character", "c" }, .{ "character device", "c" },
        .{ "block", "b" },     .{ "block device", "b" },
        .{ "socket", "s" },    .{ "link", "l" }, .{ "pipe", "p" },
    };
    inline for (table) |pair| {
        if (std.mem.eql(u8, file_type, pair[0])) return pair[1];
    }
    return null;
}

pub fn validTypeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

pub fn validBooleanName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

fn readEnforcing(allocator: std.mem.Allocator) ?bool {
    const raw = compat.cwd().readFileAlloc(allocator, "/sys/fs/selinux/enforce", 8) catch return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \r\n\t");
    if (text.len == 0) return null;
    return std.mem.eql(u8, text, "1");
}

fn readConfigured(allocator: std.mem.Allocator) ![]const u8 {
    return (try parseConfig(allocator, config_path, "SELINUX=")) orelse
        try allocator.dupe(u8, "");
}

fn readPolicy(allocator: std.mem.Allocator) ![]const u8 {
    return (try parseConfig(allocator, config_path, "SELINUXTYPE=")) orelse
        try allocator.dupe(u8, "");
}

/// Reads one `KEY=value` line. Comments and surrounding whitespace are ignored
/// because the file is hand-edited on most hosts.
pub fn parseConfigValue(
    allocator: std.mem.Allocator,
    contents: []const u8,
    key: []const u8,
) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0 or text[0] == '#') continue;
        if (!std.mem.startsWith(u8, text, key)) continue;
        return try allocator.dupe(u8, std.mem.trim(u8, text[key.len..], " \r\t"));
    }
    return null;
}

fn parseConfig(allocator: std.mem.Allocator, path: []const u8, key: []const u8) !?[]const u8 {
    const raw = compat.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return null;
    defer allocator.free(raw);
    return parseConfigValue(allocator, raw, key);
}

fn writeConfigured(allocator: std.mem.Allocator, mode: []const u8) !void {
    if (!std.mem.eql(u8, mode, "enforcing") and !std.mem.eql(u8, mode, "permissive") and
        !std.mem.eql(u8, mode, "disabled")) return error.InvalidMode;
    const raw = compat.cwd().readFileAlloc(allocator, config_path, 64 * 1024) catch
        try allocator.dupe(u8, "");
    defer allocator.free(raw);

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    var replaced = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (!replaced and text.len > 0 and text[0] != '#' and
            std.mem.startsWith(u8, text, "SELINUX="))
        {
            try out.appendSlice(try std.fmt.allocPrint(allocator, "SELINUX={s}\n", .{mode}));
            replaced = true;
            continue;
        }
        if (line.len == 0 and !replaced) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }
    if (!replaced) try out.appendSlice(try std.fmt.allocPrint(allocator, "SELINUX={s}\n", .{mode}));

    var file = try compat.createFileAbsolute(config_path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(out.items);
}

/// `getsebool -a` prints lines like `httpd_can_network_connect --> off`.
pub fn parseBooleans(allocator: std.mem.Allocator, output: []const u8) ![]const Boolean {
    var list = std.array_list.Managed(Boolean).init(allocator);
    errdefer {
        for (list.items) |entry| allocator.free(entry.name);
        list.deinit();
    }
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0) continue;
        const arrow = std.mem.indexOf(u8, text, "-->") orelse continue;
        const name = std.mem.trim(u8, text[0..arrow], " \t:");
        const value = std.mem.trim(u8, text[arrow + 3 ..], " \r\t");
        if (!validBooleanName(name)) continue;
        try list.append(.{
            .name = try allocator.dupe(u8, name),
            .enabled = std.mem.eql(u8, value, "on"),
        });
    }
    const owned = try allocator.dupe(Boolean, list.items);
    list.deinit();
    return owned;
}

fn listBooleans(allocator: std.mem.Allocator) ![]const Boolean {
    const result = exec.run(allocator, &.{ "getsebool", "-a" }, 1024 * 1024) catch
        return &.{};
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (!result.ok()) return &.{};
    return parseBooleans(allocator, result.stdout);
}

fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
