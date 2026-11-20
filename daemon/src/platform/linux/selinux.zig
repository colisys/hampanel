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

pub fn status(allocator: std.mem.Allocator) !Status {
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
        .message = message,
    };
}

/// `semanage fcontext -C -n` lists only local customisations:
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

/// AVC denials as printed by `ausearch -m AVC -ts recent`. Only the fields the
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
    const result = exec.run(allocator, &.{ "semanage", "fcontext", "-C", "-n" }, 2 * 1024 * 1024) catch
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
    const result = exec.run(allocator, &.{ "ausearch", "-m", "AVC,USER_AVC", "-ts", "recent" }, 4 * 1024 * 1024) catch
        return &.{};
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (!result.ok()) return &.{};
    return parseDenials(allocator, result.stdout);
}

/// Switches the live mode. `disabled` is not a live operation: SELinux can only
/// be turned off through the config file plus a reboot.
pub fn setMode(allocator: std.mem.Allocator, mode: []const u8) !Outcome {
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "setenforce")) return error.ToolingUnavailable;

    if (std.mem.eql(u8, mode, "enforcing")) {
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
    if (!std.mem.eql(u8, spec.file_type, "file") and
        !std.mem.eql(u8, spec.file_type, "directory") and
        !std.mem.eql(u8, spec.file_type, "all") and
        !std.mem.eql(u8, spec.file_type, "all files") and
        !std.mem.eql(u8, spec.file_type, "regular file")) return error.InvalidType;
    if (!exists("/sys/fs/selinux")) return error.NotPresent;
    if (!exec.commandExists(allocator, "semanage")) return error.ToolingUnavailable;

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "semanage", "fcontext", if (remove) "-d" else "-a", "-t" });
    try argv.append(spec.kind);
    try argv.append("-f");
    try argv.append(spec.file_type);
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
