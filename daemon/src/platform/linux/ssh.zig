const std = @import("std");
const exec = @import("shared").exec;

const sshd_config = "/etc/ssh/sshd_config";
const drop_in_dir = "/etc/ssh/sshd_config.d";
const drop_in_path = "/etc/ssh/sshd_config.d/99-hampanel.conf";
const include_marker = "# BEGIN HAMPANEL SSH INCLUDE";

pub const Status = struct {
    available: bool,
    active: bool,
    service: []const u8,
    version: []const u8,
    port: []const u8,
    permit_root_login: []const u8,
    password_authentication: []const u8,
    pubkey_authentication: []const u8,
    drop_in: []const u8,
    current_user: []const u8,
    message: []const u8 = "",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
};

pub const Key = struct {
    index: usize,
    key_type: []const u8,
    comment: []const u8,
    key: []const u8,
};

pub const UserInfo = struct {
    name: []const u8,
    home: []const u8,
    uid: u32,
    gid: u32,
};

pub fn status(allocator: std.mem.Allocator) !Status {
    const service = detectService(allocator);
    const active = isActive(allocator, service);
    const version = sshdVersion(allocator);
    const effective = sshdEffective(allocator) catch "";

    const current_user = findUserByUid(allocator, std.os.linux.geteuid()) catch null;

    return .{
        .available = version.len > 0 or effective.len > 0,
        .active = active,
        .service = service,
        .version = version,
        .port = effectiveValue(effective, "port") orelse "",
        .permit_root_login = effectiveValue(effective, "permitrootlogin") orelse "",
        .password_authentication = effectiveValue(effective, "passwordauthentication") orelse "",
        .pubkey_authentication = effectiveValue(effective, "pubkeyauthentication") orelse "",
        .drop_in = if (includePresent(allocator)) drop_in_path else "",
        .current_user = if (current_user) |user| user.name else "",
        .message = if (effective.len == 0) "sshd -T 未返回有效配置，可能需要以 root 运行" else "",
    };
}

pub fn apply(
    allocator: std.mem.Allocator,
    port: u16,
    permit_root_login: []const u8,
    password_authentication: bool,
    pubkey_authentication: bool,
) !Outcome {
    if (port == 0) return error.InvalidPort;
    if (!validRootLogin(permit_root_login)) return error.InvalidRootLogin;

    const original = std.fs.cwd().readFileAlloc(allocator, sshd_config, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SshUnavailable,
        else => return err,
    };

    var main_config = original;
    var main_changed = false;
    if (!includePresentContent(original)) {
        main_config = try std.fmt.allocPrint(allocator, "{s}\nInclude /etc/ssh/sshd_config.d/*.conf\n# END HAMPANEL SSH INCLUDE\n{s}", .{ include_marker, original });
        main_changed = true;
    }

    const drop_in_content = try std.fmt.allocPrint(
        allocator,
        "# Managed by Hampanel. Validated before reload.\nPort {d}\nPermitRootLogin {s}\nPasswordAuthentication {s}\nPubkeyAuthentication {s}\n",
        .{
            port,
            permit_root_login,
            if (password_authentication) "yes" else "no",
            if (pubkey_authentication) "yes" else "no",
        },
    );

    const previous_drop_in = std.fs.cwd().readFileAlloc(allocator, drop_in_path, 1024 * 1024) catch null;

    std.fs.cwd().makePath(drop_in_dir) catch |err| return err;
    if (main_changed) {
        const backup = try std.fmt.allocPrint(allocator, "{s}.hampanel.bak", .{sshd_config});
        try writeFile(allocator, backup, original, 0o600);
        try writeFile(allocator, sshd_config, main_config, 0o644);
    }
    try writeFile(allocator, drop_in_path, drop_in_content, 0o644);

    const test_result = runSshd(allocator, &.{ "-t", "-f", sshd_config }) catch null;
    if (test_result == null or !test_result.?.ok()) {
        restore(allocator, main_changed, original, previous_drop_in);
        return .{
            .ok = false,
            .output = if (test_result) |result| textOf(result, "sshd -t 未通过，配置已回滚") else "无法执行 sshd -t，配置已回滚",
        };
    }

    const service = detectService(allocator);
    const reload = exec.run(allocator, &.{ "systemctl", "reload", service }, 1024 * 1024) catch null;
    var reload_note: []const u8 = "";
    if (reload) |result| {
        if (!result.ok()) reload_note = "配置已通过校验，但 systemctl reload 失败，请手动检查服务状态";
    } else {
        reload_note = "配置已通过校验，但未能调用 systemctl；请手动重载 sshd";
    }

    const output = if (reload_note.len > 0)
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ textOf(test_result.?, ""), reload_note })
    else
        try std.fmt.allocPrint(allocator, "配置校验通过，已重载 {s}。修改端口后请确认防火墙与网络放行。", .{service});

    return .{ .ok = true, .output = output };
}

pub fn listKeys(allocator: std.mem.Allocator, username: []const u8) ![]Key {
    const user = try findUser(allocator, username);
    const path = try std.fs.path.join(allocator, &.{ user.home, ".ssh", "authorized_keys" });
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };

    var keys = std.ArrayList(Key).init(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var index: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const key_type = tokens.next() orelse continue;
        const payload = tokens.next() orelse continue;
        const comment = std.mem.trim(u8, tokens.rest(), " \t\r");
        if (!validKeyType(key_type)) continue;
        try keys.append(.{
            .index = index,
            .key_type = key_type,
            .comment = comment,
            .key = try allocator.dupe(u8, line),
        });
        _ = payload;
        index += 1;
    }
    return keys.toOwnedSlice();
}

pub fn addKey(allocator: std.mem.Allocator, username: []const u8, raw_key: []const u8, comment: []const u8) !Outcome {
    const user = try findUser(allocator, username);
    const normalized = try normalizeKey(allocator, raw_key, comment);

    const path = try std.fs.path.join(allocator, &.{ user.home, ".ssh", "authorized_keys" });
    const existing = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const key_type = tokens.next() orelse continue;
        const payload = tokens.next() orelse continue;
        var new_tokens = std.mem.tokenizeAny(u8, normalized, " \t");
        const new_type = new_tokens.next() orelse "";
        const new_payload = new_tokens.next() orelse "";
        if (std.mem.eql(u8, key_type, new_type) and std.mem.eql(u8, payload, new_payload)) {
            return .{ .ok = true, .output = "该公钥已存在" };
        }
    }

    var content = std.ArrayList(u8).init(allocator);
    try content.appendSlice(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try content.append('\n');
    try content.appendSlice(normalized);
    try content.append('\n');

    try ensureSshDir(allocator, user);
    try writeFileOwned(allocator, path, content.items, 0o600, user.uid, user.gid);
    return .{ .ok = true, .output = "公钥已添加" };
}

pub fn removeKey(allocator: std.mem.Allocator, username: []const u8, target_index: usize) !Outcome {
    const user = try findUser(allocator, username);
    const path = try std.fs.path.join(allocator, &.{ user.home, ".ssh", "authorized_keys" });
    const existing = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.KeyNotFound,
        else => return err,
    };

    var rebuilt = std.ArrayList(u8).init(allocator);
    var lines = std.mem.splitScalar(u8, existing, '\n');
    var index: usize = 0;
    var removed = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            try rebuilt.appendSlice(line);
            try rebuilt.append('\n');
            continue;
        }
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const key_type = tokens.next() orelse continue;
        if (!validKeyType(key_type)) {
            try rebuilt.appendSlice(line);
            try rebuilt.append('\n');
            continue;
        }
        if (index == target_index) {
            removed = true;
            index += 1;
            continue;
        }
        try rebuilt.appendSlice(line);
        try rebuilt.append('\n');
        index += 1;
    }

    if (!removed) return error.KeyNotFound;
    try writeFileOwned(allocator, path, rebuilt.items, 0o600, user.uid, user.gid);
    return .{ .ok = true, .output = "公钥已删除" };
}

fn ensureSshDir(allocator: std.mem.Allocator, user: UserInfo) !void {
    var home = std.fs.openDirAbsolute(user.home, .{}) catch return error.UserNotFound;
    home.close();
    const dir_path = try std.fs.path.join(allocator, &.{ user.home, ".ssh" });
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    std.posix.fchmod(dir.fd, 0o700) catch {};
    std.posix.fchown(dir.fd, user.uid, user.gid) catch {};
}

fn normalizeKey(allocator: std.mem.Allocator, raw_key: []const u8, comment: []const u8) ![]const u8 {
    const line = std.mem.trim(u8, raw_key, " \t\r\n");
    if (line.len == 0 or line.len > 8192) return error.InvalidKey;
    for (line) |ch| {
        if (ch < 0x20 or ch == 0x7f) return error.InvalidKey;
    }

    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const key_type = tokens.next() orelse return error.InvalidKey;
    const payload = tokens.next() orelse return error.InvalidKey;
    if (!validKeyType(key_type)) return error.InvalidKey;
    for (payload) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '/' and ch != '=') return error.InvalidKey;
    }

    const trimmed_comment = std.mem.trim(u8, if (comment.len > 0) comment else tokens.rest(), " \t\r");
    if (trimmed_comment.len > 200) return error.InvalidKey;
    for (trimmed_comment) |ch| {
        if (ch < 0x20 or ch == 0x7f) return error.InvalidKey;
    }

    if (trimmed_comment.len == 0) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ key_type, payload });
    }
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ key_type, payload, trimmed_comment });
}

fn validKeyType(value: []const u8) bool {
    const types = [_][]const u8{
        "ssh-ed25519",
        "ssh-rsa",
        "ssh-dss",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
    };
    for (types) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn validRootLogin(value: []const u8) bool {
    return std.mem.eql(u8, value, "yes") or
        std.mem.eql(u8, value, "no") or
        std.mem.eql(u8, value, "prohibit-password") or
        std.mem.eql(u8, value, "forced-commands-only");
}

fn includePresent(allocator: std.mem.Allocator) bool {
    const content = std.fs.cwd().readFileAlloc(allocator, sshd_config, 1024 * 1024) catch return false;
    return includePresentContent(content);
}

fn includePresentContent(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, include_marker)) return true;
        if (!std.ascii.startsWithIgnoreCase(line, "include")) continue;
        if (std.mem.indexOf(u8, line, "sshd_config.d") != null) return true;
    }
    return false;
}

fn effectiveValue(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len == key.len) return "";
        if (line[key.len] != ' ' and line[key.len] != '\t') continue;
        return std.mem.trim(u8, line[key.len..], " \t\r");
    }
    return null;
}

fn sshdEffective(allocator: std.mem.Allocator) ![]const u8 {
    const result = try runSshd(allocator, &.{"-T"});
    if (!result.ok()) return error.SshUnavailable;
    return result.stdout;
}

fn sshdVersion(allocator: std.mem.Allocator) []const u8 {
    const result = runSshd(allocator, &.{"-V"}) catch return "";
    const raw = if (result.stderr.len > 0) result.stderr else result.stdout;
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn runSshd(allocator: std.mem.Allocator, args: []const []const u8) !exec.Result {
    const candidates = [_][]const u8{ "sshd", "/usr/sbin/sshd", "/sbin/sshd" };
    var last_error: anyerror = error.SshUnavailable;
    for (candidates) |binary| {
        var argv = std.ArrayList([]const u8).init(allocator);
        try argv.append(binary);
        try argv.appendSlice(args);
        const result = exec.run(allocator, argv.items, 1024 * 1024) catch |err| {
            last_error = err;
            continue;
        };
        return result;
    }
    return last_error;
}

fn detectService(allocator: std.mem.Allocator) []const u8 {
    const units = [_][]const u8{ "sshd", "ssh" };
    var installed: ?[]const u8 = null;
    for (units) |unit| {
        const unit_file = std.fmt.allocPrint(allocator, "{s}.service", .{unit}) catch continue;
        const result = exec.run(allocator, &.{ "systemctl", "list-unit-files", unit_file, "--no-legend", "--no-pager" }, 64 * 1024) catch continue;
        if (!result.ok() or std.mem.indexOf(u8, result.stdout, unit_file) == null) continue;
        if (installed == null) installed = unit;
        const active = exec.run(allocator, &.{ "systemctl", "is-active", unit }, 64 * 1024) catch continue;
        if (active.ok() and std.mem.indexOf(u8, active.stdout, "active") != null) return unit;
    }
    return installed orelse "sshd";
}

fn isActive(allocator: std.mem.Allocator, service: []const u8) bool {
    const result = exec.run(allocator, &.{ "systemctl", "is-active", service }, 64 * 1024) catch return false;
    return result.ok() and std.mem.indexOf(u8, result.stdout, "active") != null;
}

fn writeFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8, mode: std.fs.File.Mode) !void {
    const temp = try std.fmt.allocPrint(allocator, "{s}.hampanel.tmp", .{path});
    {
        var file = try std.fs.createFileAbsolute(temp, .{ .truncate = true, .mode = mode });
        defer file.close();
        try file.writeAll(content);
        file.chmod(mode) catch {};
    }
    std.fs.renameAbsolute(temp, path) catch |err| {
        std.fs.deleteFileAbsolute(temp) catch {};
        return err;
    };
}

fn writeFileOwned(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    mode: std.fs.File.Mode,
    uid: u32,
    gid: u32,
) !void {
    const temp = try std.fmt.allocPrint(allocator, "{s}.hampanel.tmp", .{path});
    {
        var file = try std.fs.createFileAbsolute(temp, .{ .truncate = true, .mode = mode });
        defer file.close();
        try file.writeAll(content);
        file.chmod(mode) catch {};
        std.posix.fchown(file.handle, uid, gid) catch {};
    }
    std.fs.renameAbsolute(temp, path) catch |err| {
        std.fs.deleteFileAbsolute(temp) catch {};
        return err;
    };
}

fn restore(
    allocator: std.mem.Allocator,
    main_changed: bool,
    original_main: []const u8,
    previous_drop_in: ?[]const u8,
) void {
    if (main_changed) {
        writeFile(allocator, sshd_config, original_main, 0o644) catch {};
    }
    if (previous_drop_in) |content| {
        writeFile(allocator, drop_in_path, content, 0o644) catch {};
    } else {
        std.fs.deleteFileAbsolute(drop_in_path) catch {};
    }
}

pub const LoggingStatus = struct {
    mode: []const u8,
    file: []const u8,
    rsyslog_available: bool,
    rsyslog_service: []const u8,
    journal_available: bool,
    auth_log_path: []const u8,
    service: []const u8,
    message: []const u8,
};

pub const Logs = struct {
    source: []const u8,
    path: []const u8,
    truncated: bool,
    content: []const u8,
};

const file_log_path = "/var/log/hampanel-sshd.log";
const rsyslog_managed_path = "/etc/rsyslog.d/49-hampanel-sshd.conf";

pub fn loggingStatus(allocator: std.mem.Allocator) !LoggingStatus {
    const rsyslog_service = detectRsyslogService(allocator);
    const rsyslog_available = rsyslog_service.len > 0 and pathExists("/etc/rsyslog.d");
    const journal_available = journalAvailable(allocator);
    const auth_path = authLogPath();

    var message: []const u8 = "";
    if (!rsyslog_available) {
        message = "未检测到 rsyslog，文件日志模式不可用；可先从应用商店安装 rsyslog。";
    }

    return .{
        .mode = if (pathExists(rsyslog_managed_path)) "file" else "syslog",
        .file = file_log_path,
        .rsyslog_available = rsyslog_available,
        .rsyslog_service = rsyslog_service,
        .journal_available = journal_available,
        .auth_log_path = auth_path,
        .service = detectService(allocator),
        .message = message,
    };
}

pub fn setLogging(allocator: std.mem.Allocator, mode: []const u8) !Outcome {
    if (std.mem.eql(u8, mode, "file")) return enableFileLogging(allocator);
    if (std.mem.eql(u8, mode, "syslog")) return disableFileLogging(allocator);
    return error.InvalidMode;
}

fn enableFileLogging(allocator: std.mem.Allocator) !Outcome {
    const rsyslog_service = detectRsyslogService(allocator);
    if (rsyslog_service.len == 0 or !pathExists("/etc/rsyslog.d")) return error.RsyslogUnavailable;

    const previous = std.fs.cwd().readFileAlloc(allocator, rsyslog_managed_path, 1024 * 1024) catch null;
    const content =
        "# Managed by Hampanel. Syslog pipeline is preserved for fail2ban compatibility.\n" ++
        ":programname, isequal, \"sshd\" /var/log/hampanel-sshd.log\n" ++
        ":programname, isequal, \"sshd-session\" /var/log/hampanel-sshd.log\n";

    std.fs.cwd().makePath("/etc/rsyslog.d") catch |err| return err;
    writeConfig(allocator, rsyslog_managed_path, content) catch |err| {
        restoreManaged(allocator, previous);
        return err;
    };

    const test_result = runRsyslogd(allocator) catch null;
    if (test_result != null and !test_result.?.ok()) {
        restoreManaged(allocator, previous);
        _ = reloadRsyslog(allocator, rsyslog_service);
        return .{
            .ok = false,
            .output = textOf(test_result.?, "rsyslog 配置校验失败，已回滚"),
        };
    }

    const reload_ok = reloadRsyslog(allocator, rsyslog_service);
    if (!reload_ok) {
        restoreManaged(allocator, previous);
        _ = reloadRsyslog(allocator, rsyslog_service);
        return .{ .ok = false, .output = "rsyslog 重载失败，已回滚" };
    }

    return .{
        .ok = true,
        .output = "已启用文件日志：/var/log/hampanel-sshd.log。syslog 仍保留，fail2ban 不受影响。",
    };
}

fn disableFileLogging(allocator: std.mem.Allocator) !Outcome {
    const previous = std.fs.cwd().readFileAlloc(allocator, rsyslog_managed_path, 1024 * 1024) catch null;
    std.fs.deleteFileAbsolute(rsyslog_managed_path) catch {};

    const rsyslog_service = detectRsyslogService(allocator);
    if (rsyslog_service.len > 0) {
        if (!reloadRsyslog(allocator, rsyslog_service)) {
            restoreManaged(allocator, previous);
            _ = reloadRsyslog(allocator, rsyslog_service);
            return .{ .ok = false, .output = "rsyslog 重载失败，已恢复原配置" };
        }
    }

    return .{ .ok = true, .output = "已切换回 syslog，文件日志配置已移除（日志文件保留）。" };
}

pub fn logs(allocator: std.mem.Allocator, source: []const u8, lines: usize) !Logs {
    const limit = @max(@as(usize, 1), @min(lines, 2000));

    if (std.mem.eql(u8, source, "file")) {
        const tail = tailFile(allocator, file_log_path, limit) catch |err| switch (err) {
            error.FileNotFound => return .{
                .source = source,
                .path = file_log_path,
                .truncated = false,
                .content = "",
            },
            else => return err,
        };
        return .{
            .source = source,
            .path = file_log_path,
            .truncated = tail.truncated,
            .content = tail.content,
        };
    }

    if (std.mem.eql(u8, source, "journal")) {
        const count = try std.fmt.allocPrint(allocator, "{d}", .{limit});
        const result = exec.run(allocator, &.{
            "journalctl",
            "-u",
            "sshd",
            "-u",
            "ssh",
            "-n",
            count,
            "--no-pager",
            "-o",
            "short-iso",
        }, 2 * 1024 * 1024) catch return error.LogSourceUnavailable;
        const content = if (result.ok()) result.stdout else textOf(result, "");
        return .{
            .source = source,
            .path = "journalctl -u sshd -u ssh",
            .truncated = false,
            .content = std.mem.trim(u8, content, "\n"),
        };
    }

    if (std.mem.eql(u8, source, "auth")) {
        const path = authLogPath();
        if (path.len == 0) return error.LogSourceUnavailable;
        const tail = try tailFile(allocator, path, limit);
        return .{
            .source = source,
            .path = path,
            .truncated = tail.truncated,
            .content = tail.content,
        };
    }

    return error.InvalidSource;
}

fn detectRsyslogService(allocator: std.mem.Allocator) []const u8 {
    const units = [_][]const u8{ "rsyslog", "syslog" };
    for (units) |unit| {
        const unit_file = std.fmt.allocPrint(allocator, "{s}.service", .{unit}) catch continue;
        const result = exec.run(allocator, &.{ "systemctl", "list-unit-files", unit_file, "--no-legend", "--no-pager" }, 64 * 1024) catch continue;
        if (result.ok() and std.mem.indexOf(u8, result.stdout, unit_file) != null) return unit;
    }
    return "";
}

fn journalAvailable(allocator: std.mem.Allocator) bool {
    const result = exec.run(allocator, &.{ "journalctl", "--version" }, 64 * 1024) catch return false;
    return result.ok();
}

fn authLogPath() []const u8 {
    const candidates = [_][]const u8{ "/var/log/auth.log", "/var/log/secure" };
    for (candidates) |path| {
        if (pathExists(path)) return path;
    }
    return "";
}

fn runRsyslogd(allocator: std.mem.Allocator) !exec.Result {
    const candidates = [_][]const u8{ "rsyslogd", "/usr/sbin/rsyslogd", "/sbin/rsyslogd" };
    var last_error: anyerror = error.RsyslogUnavailable;
    for (candidates) |binary| {
        const result = exec.run(allocator, &.{ binary, "-N1" }, 1024 * 1024) catch |err| {
            last_error = err;
            continue;
        };
        return result;
    }
    return last_error;
}

fn reloadRsyslog(allocator: std.mem.Allocator, service: []const u8) bool {
    if (service.len == 0) return true;
    if (exec.run(allocator, &.{ "systemctl", "reload", service }, 1024 * 1024)) |result| {
        if (result.ok()) return true;
    } else |_| {}
    if (exec.run(allocator, &.{ "systemctl", "restart", service }, 1024 * 1024)) |result| {
        return result.ok();
    } else |_| {}
    return false;
}

fn restoreManaged(allocator: std.mem.Allocator, previous: ?[]const u8) void {
    if (previous) |content| {
        writeConfig(allocator, rsyslog_managed_path, content) catch {};
    } else {
        std.fs.deleteFileAbsolute(rsyslog_managed_path) catch {};
    }
}

fn writeConfig(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    _ = allocator;
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer file.close();
    try file.writeAll(content);
    file.chmod(0o644) catch {};
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

const TailResult = struct {
    content: []const u8,
    truncated: bool,
};

fn tailFile(allocator: std.mem.Allocator, path: []const u8, lines: usize) !TailResult {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const size = (try file.stat()).size;
    const max_window: u64 = 512 * 1024;
    const window: u64 = @min(size, max_window);
    if (window == 0) return .{ .content = "", .truncated = size > 0 };

    try file.seekFromEnd(-@as(i64, @intCast(window)));
    const buffer = try allocator.alloc(u8, @intCast(window));
    const read = try file.readAll(buffer);

    var items = std.ArrayList([]const u8).init(allocator);
    var iterator = std.mem.splitScalar(u8, buffer[0..read], '\n');
    while (iterator.next()) |line| {
        if (line.len == 0) continue;
        try items.append(line);
    }
    const start = if (items.items.len > lines) items.items.len - lines else 0;
    const content = try std.mem.join(allocator, "\n", items.items[start..]);
    return .{ .content = content, .truncated = size > window };
}

fn textOf(result: exec.Result, fallback: []const u8) []const u8 {
    const primary = if (result.stderr.len > 0) result.stderr else result.stdout;
    const trimmed = std.mem.trim(u8, primary, " \t\r\n");
    if (trimmed.len > 0) return trimmed;
    return fallback;
}

fn findUser(allocator: std.mem.Allocator, name: []const u8) !UserInfo {
    const passwd = try std.fs.cwd().readFileAlloc(allocator, "/etc/passwd", 1024 * 1024);
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        const user = parsePasswdLine(line) orelse continue;
        if (std.mem.eql(u8, user.name, name)) return user;
    }
    return error.UserNotFound;
}

fn findUserByUid(allocator: std.mem.Allocator, uid: u32) !UserInfo {
    const passwd = try std.fs.cwd().readFileAlloc(allocator, "/etc/passwd", 1024 * 1024);
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        const user = parsePasswdLine(line) orelse continue;
        if (user.uid == uid) return user;
    }
    return error.UserNotFound;
}

fn parsePasswdLine(line: []const u8) ?UserInfo {
    var fields = std.mem.splitScalar(u8, line, ':');
    const name = fields.next() orelse return null;
    if (name.len == 0) return null;
    _ = fields.next() orelse return null;
    const uid_raw = fields.next() orelse return null;
    const gid_raw = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    const home = fields.next() orelse return null;
    const uid = std.fmt.parseInt(u32, uid_raw, 10) catch return null;
    const gid = std.fmt.parseInt(u32, gid_raw, 10) catch return null;
    return .{ .name = name, .home = home, .uid = uid, .gid = gid };
}
