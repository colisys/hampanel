const std = @import("std");
const compat = @import("compat");
const exec = @import("shared").exec;
pub const decoys = @import("honeypot_decoys.zig");

/// SSH / Web honeypot.
///
/// The guest runs under QEMU/KVM and is built from the host's own kernel plus a
/// busybox initramfs, so nothing is downloaded. Hardware *identity* is copied
/// from the host (CPU model, core count, memory size, DMI strings, disk size) so
/// an attacker sees a plausible machine, but every device is emulated:
///
///  - no host device is passed through: there is no `-device vfio`, no PCI
///    assignment and no raw disk; storage is the guest initramfs;
///  - networking is QEMU user-mode (slirp), which cannot reach the host's LAN
///    or the host itself, and is the only path to the guest;
///  - the guest gets its own MAC, and the DMI is overridden with `-smbios`.
///
/// Observation is read-only: the serial console and the HTTP probe are the only
/// interfaces, and the guest is always started detached with a pid file.
pub const Mode = enum {
    ssh,
    web,

    pub fn fromString(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "ssh")) return .ssh;
        if (std.mem.eql(u8, value, "web")) return .web;

        return null;
    }

    pub fn name(self: Mode) []const u8 {
        return @tagName(self);
    }
};

/// Hardware profile mirrored from the host so the guest looks plausible.
pub const Profile = struct {
    cpu_model: []const u8,
    cpu_cores: u16,
    memory_mb: u32,
    disk_gb: u16,
    vendor: []const u8,
    product: []const u8,
    board: []const u8,
    serial: []const u8,
    mac: []const u8,
};

pub const Session = struct {
    id: []const u8,
    mode: []const u8,
    running: bool,
    /// Host port forwarded to the guest's SSH or HTTP port; 0 when not exposed.
    port: u16,
    started_at: i64,
    console_path: []const u8,
    /// Human-readable isolation statement.
    isolation: []const u8,
};

pub const Status = struct {
    qemu: bool,
    kvm: bool,
    kernel: []const u8,
    image: []const u8,
    image_ready: bool,
    web_image_ready: bool,
    ssh_image_ready: bool,
    profile: Profile,
    sessions: []const Session,
    message: []const u8 = "",
};

pub const Outcome = struct {
    ok: bool,
    output: []const u8,
    session_id: ?[]const u8 = null,
    port: u16 = 0,
};

pub const Paths = struct {
    root: []u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
    }

    pub fn image(self: Paths, allocator: std.mem.Allocator, mode: Mode) ![]u8 {
        return compat.path.join(allocator, &.{ self.root, switch (mode) {
            .web => "protocol-v1-web.cpio.gz",
            .ssh => "protocol-v1-ssh.cpio.gz",
        } });
    }

    pub fn state(self: Paths, allocator: std.mem.Allocator, id: []const u8, name: []const u8) ![]u8 {
        return compat.path.join(allocator, &.{ self.root, id, name });
    }
};

pub fn buildPaths(allocator: std.mem.Allocator, data_dir: []const u8) !Paths {
    return .{ .root = try compat.path.join(allocator, &.{ data_dir, "security", "honeypot" }) };
}

/// The kernel is taken from the host so the guest boots without downloads.
pub fn kernelPath(allocator: std.mem.Allocator) ![]const u8 {
    if (if (@import("builtin").is_test) std.testing.environ.getPosix("HONEYPOT_KERNEL") else compat.getEnv("HONEYPOT_KERNEL")) |path| {
        if (!exists(path)) return error.KernelNotFound;
        return allocator.dupe(u8, path);
    }
    const uname = exec.run(allocator, &.{ "uname", "-r" }, 4096) catch return error.KernelNotFound;
    const release = std.mem.trim(u8, uname.stdout, " \r\n\t");
    if (release.len == 0) return error.KernelNotFound;
    const path = try std.fmt.allocPrint(allocator, "/boot/vmlinuz-{s}", .{release});
    if (!exists(path)) return error.KernelNotFound;
    return path;
}

pub fn kvmAvailable() bool {
    // Readable by root; the daemon runs privileged in production.
    var file = compat.openFileAbsolute("/dev/kvm", .{ .mode = .read_write }) catch return false;
    file.close();
    return true;
}

pub fn qemuAvailable(allocator: std.mem.Allocator) bool {
    return exec.commandExists(allocator, "qemu-system-x86_64");
}

/// Mirrors the host identity. Values that cannot be read fall back to neutral
/// ones so the guest still boots instead of failing the whole feature.
pub fn hostProfile(allocator: std.mem.Allocator) !Profile {
    const cpu_model = readFirstLine(allocator, "/proc/cpuinfo", "model name") orelse
        try allocator.dupe(u8, "QEMU Virtual CPU");
    const cores = std.Thread.getCpuCount() catch 2;
    const memory_kb = readMemTotalKb(allocator) orelse (2048 * 1024);
    // Half the host memory, capped: the guest must not be able to starve the host.
    const memory_mb: u32 = @intCast(@min(@as(u64, memory_kb) / 2048, 8192));

    return .{
        .cpu_model = cpu_model,
        .cpu_cores = @intCast(@min(cores, 8)),
        .memory_mb = @max(memory_mb, 256),
        .disk_gb = 20,
        .vendor = readTrimmed(allocator, "/sys/class/dmi/id/sys_vendor") orelse
            try allocator.dupe(u8, "Hampanel"),
        .product = readTrimmed(allocator, "/sys/class/dmi/id/product_name") orelse
            try allocator.dupe(u8, "Honeypot"),
        .board = readTrimmed(allocator, "/sys/class/dmi/id/board_name") orelse
            try allocator.dupe(u8, "Hampanel Board"),
        .serial = readTrimmed(allocator, "/sys/class/dmi/id/product_serial") orelse
            try allocator.dupe(u8, "HP-0000"),
        .mac = "52:54:00:12:34:56",
    };
}

pub fn status(allocator: std.mem.Allocator, data_dir: []const u8) !Status {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    // Not freed: the caller serializes this struct after `status` returns, and
    // the caller's arena owns it (see api/security.zig).
    const web_image = try paths.image(allocator, .web);
    const ssh_image = try paths.image(allocator, .ssh);
    const image = if (exists(web_image)) web_image else ssh_image;

    const kernel = kernelPath(allocator) catch "";
    const profile = try hostProfile(allocator);
    const sessions = try listSessions(allocator, paths);

    var message: []const u8 = "";
    const qemu = qemuAvailable(allocator);
    if (!qemu) {
        message = "服务器未安装 qemu-system-x86_64，无法运行蜜罐";
    } else if (kernel.len == 0) {
        message = "未找到 /boot/vmlinuz-<当前内核>，无法构建 guest";
    } else if (!exists(image)) {
        message = "尚未构建 guest 镜像";
    } else if (!kvmAvailable()) {
        message = "使用 QEMU 软件模拟，启动可能较慢";
    }

    return .{
        .qemu = qemu,
        .kvm = kvmAvailable(),
        .kernel = kernel,
        // A mutable []u8 serializes as a byte array; the status must carry text.
        .image = @as([]const u8, image),
        .image_ready = exists(image),
        .web_image_ready = exists(web_image),
        .ssh_image_ready = exists(ssh_image),
        .profile = profile,
        .sessions = sessions,
        .message = message,
    };
}

/// Builds the guest initramfs from the host's busybox: no network access, no
/// package manager, everything deterministic and inspectable.
pub fn buildImage(allocator: std.mem.Allocator, data_dir: []const u8, mode: Mode) !Outcome {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    try compat.cwd().makePath(paths.root);

    const busybox = if (compat.getEnv("HONEYPOT_BUSYBOX")) |value|
        value
    else
        "/usr/bin/busybox";
    if (!exists(busybox)) return error.BusyboxUnavailable;

    const nonce = try randomId(allocator);
    const work_name = try std.fmt.allocPrint(allocator, "build-{s}", .{nonce});
    const work = try compat.path.join(allocator, &.{ paths.root, work_name });
    defer allocator.free(work);
    try compat.makeDirAbsolute(work, 0o700);
    defer deleteTree(work);
    const rootfs = try compat.path.join(allocator, &.{ work, "rootfs" });
    defer allocator.free(rootfs);

    for ([_][]const u8{ "bin", "proc", "sys", "dev", "tmp", "etc", "www" }) |dir| {
        const full = try compat.path.join(allocator, &.{ rootfs, dir });
        defer allocator.free(full);
        try compat.cwd().makePath(full);
    }

    const busybox_copy = try compat.path.join(allocator, &.{ rootfs, "bin", "busybox" });
    defer allocator.free(busybox_copy);
    try copyFile(busybox, busybox_copy);

    const source = try compat.path.join(allocator, &.{ work, "listener.c" });
    const listener = try compat.path.join(allocator, &.{ rootfs, "bin", "listener" });
    try writeFile(source, @embedFile("honeypot_guest.c"));
    const compiled = try exec.run(allocator, &.{ "cc", "-Os", "-static", source, "-o", listener }, 64 * 1024);
    if (!compiled.ok()) return .{ .ok = false, .output = textOf(compiled) };

    const init = try compat.path.join(allocator, &.{ rootfs, "init" });
    defer allocator.free(init);
    // /init must be executable: the kernel refuses it otherwise with
    // "Failed to execute /init (error -13)" and panics.
    try writeFileMode(init, try renderInit(allocator, mode), 0o755);

    // `cpio` is the only archiver assumed; the image stays inspectable by hand.
    const archive = try paths.image(allocator, mode);
    defer allocator.free(archive);
    const staged = try compat.path.join(allocator, &.{ work, "image.gz" });
    const result = try exec.run(allocator, &.{ "bash", "-o", "pipefail", "-c", "cd -- \"$1\" && find . -print0 | cpio --null -o -H newc | gzip -9 > \"$2\"", "build", rootfs, staged }, 64 * 1024);
    if (!result.ok()) return .{ .ok = false, .output = textOf(result) };
    try compat.renameAbsolute(staged, archive);
    return .{ .ok = true, .output = "guest 镜像已构建" };
}

fn renderInit(allocator: std.mem.Allocator, mode: Mode) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    try w.writeAll(
        \\#!/bin/busybox sh
        \\set -e
        \\/bin/busybox --install -s /bin
        \\export PATH=/bin
        \\mount -t proc proc /proc
        \\mount -t sysfs sys /sys
        \\mount -t devtmpfs dev /dev 2>/dev/null
        \\mount -t tmpfs tmp /tmp
        \\ip link set lo up 2>/dev/null
        \\
    );
    // QEMU user-mode networking is always 10.0.2.0/24 with gateway 10.0.2.2.
    // The guest is configured statically because this image carries no DHCP
    // helper script and must not depend on one.
    try w.writeAll(
        \\ip link set eth0 up 2>/dev/null
        \\ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
        \\# Deliberately no default route.
        \\
    );
    try w.print("exec /bin/listener {s}\n", .{mode.name()});
    return out.written();
}

const GuestGuard = struct {
    child: std.process.Child,
    pid_path: []const u8,
};

/// QEMU owns the serial file; only reap and clear the live marker.
fn pumpGuest(guard: *GuestGuard) void {
    const io = compat.io();

    _ = guard.child.wait(io) catch {};
    compat.deleteFileAbsolute(guard.pid_path) catch {};
    std.heap.page_allocator.free(guard.pid_path);

    std.heap.page_allocator.destroy(guard);
}

/// Starts a guest. `expose_port` is a host port forwarded to the guest service;
/// QEMU must bind the selected unused nonprivileged port or startup fails.
pub fn start(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    mode: Mode,
    expose_port: u16,
) !Outcome {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    if (!qemuAvailable(allocator)) return error.QemuUnavailable;
    const kvm = kvmAvailable();

    if (expose_port < 1024) return error.InvalidPort;
    const image = try paths.image(allocator, mode);
    defer allocator.free(image);
    if (!exists(image)) return error.ImageNotBuilt;
    const kernel = kernelPath(allocator) catch return error.KernelNotFound;

    // Not freed: `id` is returned to the caller and `console_path` is returned
    // inside the session metadata, so both must outlive this function.
    const id = try randomId(allocator);
    const dir = try compat.path.join(allocator, &.{ paths.root, id });
    defer allocator.free(dir);
    try compat.makeDirAbsolute(dir, 0o700);
    errdefer deleteTree(dir);

    const profile = try hostProfile(allocator);
    defer freeProfile(allocator, profile);
    // A per-session MAC: a shared one would let guests correlate each other and
    // make them indistinguishable in the host's ARP table.
    const mac = try uniqueMac(allocator, data_dir);

    const console_path = try compat.path.join(allocator, &.{ dir, "console.log" });
    const pid_path = try compat.path.join(allocator, &.{ dir, "qemu.pid" });
    defer allocator.free(pid_path);
    const meta_path = try compat.path.join(allocator, &.{ dir, "session.json" });
    defer allocator.free(meta_path);

    // The guest needs only its initramfs; attach no disk.

    const guest_port: u16 = if (mode == .web) 8080 else 2222;
    const forward = try std.fmt.allocPrint(
        allocator,
        "user,id=n0,restrict=on,hostfwd=tcp:0.0.0.0:{d}-10.0.2.15:{d}",
        .{ expose_port, guest_port },
    );
    defer allocator.free(forward);
    const netdev = forward;

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    const smp = try std.fmt.allocPrint(allocator, "{d}", .{if (kvm) profile.cpu_cores else @min(profile.cpu_cores, 2)});
    defer allocator.free(smp);
    const mem = try std.fmt.allocPrint(allocator, "{d}", .{if (kvm) profile.memory_mb else @min(profile.memory_mb, 1024)});
    defer allocator.free(mem);
    // DMI strings are free text: a vendor such as
    // "CHUWI Innovation And Technology(ShenZhen)co.,Ltd" contains a comma,
    // which QEMU treats as an option separator and refuses to boot on.
    const vendor = try qemuEscape(allocator, profile.vendor);
    defer allocator.free(vendor);
    const product = try qemuEscape(allocator, profile.product);
    defer allocator.free(product);
    const serial = try qemuEscape(allocator, profile.serial);
    defer allocator.free(serial);
    const smbios = try std.fmt.allocPrint(
        allocator,
        "type=1,manufacturer={s},product={s},serial={s}",
        .{ vendor, product, serial },
    );
    defer allocator.free(smbios);

    try argv.appendSlice(&.{
        "qemu-system-x86_64",
        "-accel",
        if (kvm) "kvm" else "tcg",
        // TCG cannot expose the host CPU model.
        "-cpu",
        if (kvm) "host" else "max",
        "-smp",
        smp,
        "-m",
        mem,
        "-kernel",
        kernel,
        "-initrd",
        image,
        "-append",
        "console=ttyS0 quiet panic=1",
        "-display",
        "none",
        "-no-reboot",
        // Present a plausible machine, but nothing is passed through.
        "-machine",
        "pc",
        "-smbios",
        smbios,
        "-netdev",
        netdev,
        // Unique MAC per session: a shared one would let a guest correlate
        // sessions and lets the host tell guests apart in its own ARP tables.
        "-device",
        try std.fmt.allocPrint(allocator, "virtio-net-pci,netdev=n0,mac={s}", .{mac}),
        // No host device passthrough of any kind.
        "-nodefaults",
        "-monitor",
        "none",
    });

    // `-nographic` ties the serial console to stdout, and QEMU exits at once
    // when stdout is a pipe nobody is reading yet. The console is therefore
    // written by QEMU itself straight into the session file.
    const serial_arg = try std.fmt.allocPrint(allocator, "file:{s}", .{console_path});
    defer allocator.free(serial_arg);
    try argv.append("-serial");
    try argv.append(serial_arg);

    var child = std.process.spawn(compat.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;
    errdefer child.kill(compat.io());
    const pid = child.id orelse return error.SpawnFailed;
    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_text);
    try writeFile(pid_path, pid_text);

    const meta = try std.json.Stringify.valueAlloc(allocator, .{
        .id = id,
        .mode = mode.name(),
        .port = expose_port,
        .pid = pid,
        .started_at = compat.milliTimestamp(),
        .console = console_path,
    }, .{});
    defer allocator.free(meta);
    try writeFile(meta_path, meta);
    for (0..600) |_| {
        if (!ownsGuest(allocator, pid, console_path)) return error.QemuExitedCheckPortOrKernel;
        const log = compat.cwd().readFileAlloc(allocator, console_path, 64 * 1024) catch "";
        defer if (log.len > 0) allocator.free(log);
        if (std.mem.indexOf(u8, log, "[decoy] listener ready") != null) break;
        compat.sleep(100 * std.time.ns_per_ms);
    } else return error.GuestListenerTimeout;
    const guard = try std.heap.page_allocator.create(GuestGuard);
    errdefer std.heap.page_allocator.destroy(guard);
    guard.* = .{ .child = child, .pid_path = try std.heap.page_allocator.dupe(u8, pid_path) };
    errdefer std.heap.page_allocator.free(guard.pid_path);
    const thread = try std.Thread.spawn(.{}, pumpGuest, .{guard});
    thread.detach();
    return .{
        .ok = true,
        .output = "guest 已启动",
        .session_id = id,
        .port = expose_port,
    };
}

pub fn stop(allocator: std.mem.Allocator, data_dir: []const u8, id: []const u8) !Outcome {
    if (!validId(id)) return error.InvalidSession;
    // The session must exist at all, otherwise a typo'd id would look stopped.
    const session_dir = try buildPaths(allocator, data_dir);
    defer session_dir.deinit(allocator);
    const dir = try session_dir.state(allocator, id, "session.json");
    defer allocator.free(dir);
    if (!exists(dir)) return error.InvalidSession;
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    const pid_path = try paths.state(allocator, id, "qemu.pid");
    defer allocator.free(pid_path);

    // A session without a pid file has already been reaped by its supervisor;
    // stopping twice is a no-op, not an error.
    const raw = compat.cwd().readFileAlloc(allocator, pid_path, 32) catch
        return .{ .ok = true, .output = "guest 未在运行" };
    defer allocator.free(raw);
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \r\n\t"), 10) catch
        return .{ .ok = true, .output = "guest 未在运行" };
    if (pid <= 0) return .{ .ok = true, .output = "guest 未在运行" };
    const console = try paths.state(allocator, id, "console.log");
    const linux = std.os.linux;
    const handle = linux.pidfd_open(pid, 0);
    if (linux.errno(handle) == .SRCH) return .{ .ok = true, .output = "guest 未在运行" };
    if (linux.errno(handle) != .SUCCESS) return error.PidfdUnavailable;
    const fd: i32 = @intCast(handle);
    defer _ = linux.close(fd);
    if (!ownsGuest(allocator, pid, console)) return .{ .ok = true, .output = "guest 未在运行" };
    if (linux.errno(linux.pidfd_send_signal(fd, .TERM, null, 0)) != .SUCCESS) return error.StopFailed;
    for (0..50) |_| {
        if (!ownsGuest(allocator, pid, console)) break;
        compat.sleep(100 * std.time.ns_per_ms);
    } else return error.StopTimeout;
    return .{ .ok = true, .output = "guest 已停止" };
}

pub fn listSessions(allocator: std.mem.Allocator, paths: Paths) ![]const Session {
    var list = std.array_list.Managed(Session).init(allocator);
    defer list.deinit();
    var dir = std.Io.Dir.openDirAbsolute(compat.io(), paths.root, .{ .iterate = true }) catch
        return &.{};
    defer dir.close(compat.io());
    var iterator = dir.iterate();
    while (iterator.next(compat.io()) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!validId(entry.name)) continue;
        // Everything appended here is returned to the caller, so it is not freed.
        const id = try allocator.dupe(u8, entry.name);
        const pid_path = try paths.state(allocator, id, "qemu.pid");
        const console_path = try paths.state(allocator, id, "console.log");
        const raw = compat.cwd().readFileAlloc(allocator, pid_path, 32) catch "";
        defer if (raw.len > 0) allocator.free(raw);
        const pid = std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \r\n\t"), 10) catch 0;

        // The recorded session wins: mode and port are what the operator chose.
        const meta_path = try paths.state(allocator, id, "session.json");
        if (!exists(meta_path)) continue;
        const meta_raw = compat.cwd().readFileAlloc(allocator, meta_path, 64 * 1024) catch "";
        defer if (meta_raw.len > 0) allocator.free(meta_raw);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, meta_raw, .{}) catch null;
        defer if (parsed) |value| value.deinit();

        var mode: []const u8 = "guest";
        var port: u16 = 0;
        var started_at: i64 = 0;
        if (parsed) |value| {
            if (value.value == .object) {
                if (value.value.object.get("mode")) |field| {
                    if (field == .string) mode = try allocator.dupe(u8, field.string);
                }
                if (value.value.object.get("port")) |field| {
                    if (field == .integer and field.integer >= 0 and field.integer <= 65535) {
                        port = @intCast(field.integer);
                    }
                }
                if (value.value.object.get("started_at")) |field| {
                    if (field == .integer) started_at = field.integer;
                }
            }
        }
        if (std.mem.eql(u8, mode, "guest")) mode = try allocator.dupe(u8, "guest");

        try list.append(.{
            .id = id,
            .mode = mode,
            .running = pid > 0 and ownsGuest(allocator, pid, console_path),
            .port = port,
            .started_at = started_at,
            .console_path = console_path,
            .isolation = try allocator.dupe(u8, "QEMU user-mode 网络，无设备透传"),
        });
    }
    return try allocator.dupe(Session, list.items);
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 40) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

fn ownsGuest(allocator: std.mem.Allocator, pid: i32, console: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const exe_link = std.fmt.bufPrint(&buffer, "/proc/{d}/exe", .{pid}) catch return false;
    var target: [compat.max_path_bytes]u8 = undefined;
    const exe = compat.cwd().readLink(exe_link, &target) catch return false;
    if (!std.mem.eql(u8, compat.path.basename(exe), "qemu-system-x86_64")) return false;
    const path = std.fmt.bufPrint(&buffer, "/proc/{d}/cmdline", .{pid}) catch return false;
    const cmd = compat.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return false;
    defer allocator.free(cmd);
    var args = std.mem.splitScalar(u8, cmd, 0);
    if (!std.mem.eql(u8, args.next() orelse return false, "qemu-system-x86_64")) return false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-serial")) {
            const serial = args.next() orelse return false;
            return std.mem.startsWith(u8, serial, "file:") and std.mem.eql(u8, serial[5..], console);
        }
    }
    return false;
}

/// QEMU's 52:54:00 prefix is reserved for emulated adapters, so a generated
/// address cannot collide with real hardware on the segment.
fn uniqueMac(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    _ = data_dir;
    var bytes: [3]u8 = undefined;
    compat.randomBytes(&bytes);
    return std.fmt.allocPrint(allocator, "52:54:00:{x:0>2}:{x:0>2}:{x:0>2}", .{
        bytes[0], bytes[1], bytes[2],
    });
}

fn randomId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [8]u8 = undefined;
    compat.randomBytes(&bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(bytes, .lower)});
}

fn copyFile(source: []const u8, target: []const u8) !void {
    const data = compat.cwd().readFileAlloc(std.heap.page_allocator, source, 32 * 1024 * 1024) catch
        return error.BusyboxUnavailable;
    defer std.heap.page_allocator.free(data);
    try writeFile(target, data);
    var file = try compat.openFileAbsolute(target, .{ .mode = .read_write });
    defer file.close();
    try file.chmod(0o755);
}

fn deleteTree(path: []const u8) void {
    // Best effort: the archive is what matters, a leftover build dir is not.
    compat.deleteTreeAbsolute(path) catch {};
}

fn readFirstLine(allocator: std.mem.Allocator, path: []const u8, key: []const u8) ?[]const u8 {
    const raw = compat.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, key) == null) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \r\t");
        if (value.len == 0) continue;
        return allocator.dupe(u8, value) catch null;
    }
    return null;
}

fn readTrimmed(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const raw = compat.cwd().readFileAlloc(allocator, path, 4096) catch return null;
    defer allocator.free(raw);
    const value = std.mem.trim(u8, raw, " \r\n\t");
    if (value.len == 0) return null;
    return allocator.dupe(u8, value) catch null;
}

fn readMemTotalKb(allocator: std.mem.Allocator) ?u64 {
    const raw = compat.cwd().readFileAlloc(allocator, "/proc/meminfo", 64 * 1024) catch return null;
    defer allocator.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
        var tokens = std.mem.tokenizeAny(u8, line[9..], " \t");
        const value = tokens.next() orelse return null;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

fn freeProfile(allocator: std.mem.Allocator, profile: Profile) void {
    allocator.free(profile.cpu_model);
    allocator.free(profile.vendor);
    allocator.free(profile.product);
    allocator.free(profile.board);
    allocator.free(profile.serial);
}

/// Escapes a value for QEMU's comma-separated option syntax by doubling the
/// separator, which is how QEMU itself documents quoting these values.
fn qemuEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (value) |c| {
        if (c == ',') try out.append(',');
        try out.append(c);
    }
    return out.toOwnedSlice();
}

/// Exposed for tests: the escaping rule is what keeps QEMU booting on hosts
/// whose DMI strings contain commas.
pub fn qemuEscapeForTest(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return qemuEscape(allocator, value);
}

fn exists(path: []const u8) bool {
    compat.cwd().access(path, .{}) catch return false;
    return true;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    try writeFileMode(path, content, 0o600);
}

fn writeFileMode(path: []const u8, content: []const u8, mode: u32) !void {
    if (compat.path.dirname(path)) |dir| compat.cwd().makePath(dir) catch {};
    var file = try compat.createFileAbsolute(path, .{ .truncate = true, .mode = @intCast(mode) });
    defer file.close();
    try file.writeAll(content);
}

fn textOf(result: exec.Result) []const u8 {
    if (result.stderr.len > 0) return result.stderr;
    return result.stdout;
}
