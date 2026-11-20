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
///    assignment and no raw disk; storage is a qcow2 file created by us;
///  - networking is QEMU user-mode (slirp), which cannot reach the host's LAN
///    or the host itself, and is the only path to the guest;
///  - the guest gets its own MAC, and the DMI is overridden with `-smbios`.
///
/// Observation is read-only: the serial console and the HTTP probe are the only
/// interfaces, and the guest is always started detached with a pid file.

pub const Mode = enum {
    ssh,
    web,
    both,

    pub fn fromString(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "ssh")) return .ssh;
        if (std.mem.eql(u8, value, "web")) return .web;
        if (std.mem.eql(u8, value, "both")) return .both;
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

    pub fn image(self: Paths, allocator: std.mem.Allocator) ![]u8 {
        return compat.path.join(allocator, &.{ self.root, "guest-initramfs.gz" });
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
    const memory_kb = readMemTotalKb(allocator) orelse 2048 * 1024;
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
    const image = try paths.image(allocator);

    const kernel = kernelPath(allocator) catch "";
    const profile = try hostProfile(allocator);
    const sessions = try listSessions(allocator, paths);

    var message: []const u8 = "";
    const qemu = qemuAvailable(allocator);
    if (!qemu) {
        message = "服务器未安装 qemu-system-x86_64，无法运行蜜罐";
    } else if (!kvmAvailable()) {
        message = "缺少 /dev/kvm，只能软件模拟（极慢）；请确认已开启嵌套虚拟化";
    } else if (kernel.len == 0) {
        message = "未找到 /boot/vmlinuz-<当前内核>，无法构建 guest";
    } else if (!exists(image)) {
        message = "尚未构建 guest 镜像";
    }

    return .{
        .qemu = qemu,
        .kvm = kvmAvailable(),
        .kernel = kernel,
        // A mutable []u8 serializes as a byte array; the status must carry text.
        .image = @as([]const u8, image),
        .image_ready = exists(image),
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

    const work = try compat.path.join(allocator, &.{ paths.root, "build" });
    defer allocator.free(work);
    try compat.cwd().makePath(work);
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

    // Decoy content is generated per build, so two honeypots do not look like
    // copies of each other. Everything in it is fabricated.
    const hostname = try decoys.populate(allocator, rootfs, mode.name());
    defer allocator.free(hostname);

    const init = try compat.path.join(allocator, &.{ rootfs, "init" });
    defer allocator.free(init);
    // /init must be executable: the kernel refuses it otherwise with
    // "Failed to execute /init (error -13)" and panics.
    try writeFileMode(init, try renderInit(allocator, mode, hostname), 0o755);

    // `cpio` is the only archiver assumed; the image stays inspectable by hand.
    const archive = try paths.image(allocator);
    defer allocator.free(archive);
    const script = try std.fmt.allocPrint(
        allocator,
        "cd {s} && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > {s}",
        .{ rootfs, archive },
    );
    defer allocator.free(script);
    const result = exec.run(allocator, &.{ "sh", "-c", script }, 1024 * 1024) catch
        return error.BuildFailed;
    if (!result.ok() or !exists(archive)) {
        return .{ .ok = false, .output = textOf(result) };
    }

    // The build directory is large and useless once archived.
    deleteTree(work);
    return .{ .ok = true, .output = "guest 镜像已构建" };
}

fn renderInit(allocator: std.mem.Allocator, mode: Mode, hostname: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    try w.print(
        \\#!/bin/busybox sh
        \\/bin/busybox --install -s /bin
        \\export PATH=/bin
        \\mount -t proc proc /proc
        \\mount -t sysfs sys /sys
        \\mount -t devtmpfs dev /dev 2>/dev/null
        \\mount -t tmpfs tmp /tmp
        \\hostname {s}
        \\ip link set lo up 2>/dev/null
        \\
    , .{hostname});
    // QEMU user-mode networking is always 10.0.2.0/24 with gateway 10.0.2.2.
    // The guest is configured statically because this image carries no DHCP
    // helper script and must not depend on one.
    try w.writeAll(
        \\ip link set eth0 up 2>/dev/null
        \\ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
        \\ip route add default via 10.0.2.2 2>/dev/null
        \\
    );
    if (mode == .web or mode == .both) {
        // Serve the generated site, not a placeholder page.
        try w.writeAll(
            \\httpd -p 80 -h /var/www/html
            \\echo "[honeypot] http listening on 80"
            \\
        );
    }
    if (mode == .ssh or mode == .both) {
        // busybox has no sshd; telnetd gives the same "someone is poking at a
        // port" signal without shipping an unauditable SSH implementation.
        try w.writeAll(
            \\echo "[honeypot] telnet listening on 23"
            \\telnetd -p 23 -l /bin/sh 2>/dev/null
            \\
        );
    }
    try w.writeAll(
        \\while true; do sleep 3600; done
        \\
    );
    return out.written();
}

const GuestGuard = struct {
    child: std.process.Child,
    pid: std.posix.pid_t,
    pid_path: []const u8,
    console_path: []const u8,
};

/// Copies the guest's serial console into the session file so the panel can
/// show what the attacker actually did, then waits for the process so it is
/// reaped instead of becoming a zombie.
fn pumpGuest(guard: *GuestGuard) void {
    const io = compat.io();
    const file = compat.createFileAbsolute(guard.console_path, .{ .truncate = true, .mode = 0o600 }) catch null;

    // QEMU writes the console itself; the supervisor only has to reap it.
    _ = file;
    _ = guard.child.wait(io) catch {};
    compat.deleteFileAbsolute(guard.pid_path) catch {};
    std.heap.page_allocator.free(guard.pid_path);
    std.heap.page_allocator.free(guard.console_path);
    std.heap.page_allocator.destroy(guard);
}

/// Starts a guest. `expose_port` is a host port forwarded to the guest service;
/// 0 keeps the guest reachable only through its console.
pub fn start(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    mode: Mode,
    expose_port: u16,
) !Outcome {
    const paths = try buildPaths(allocator, data_dir);
    defer paths.deinit(allocator);
    if (!qemuAvailable(allocator)) return error.QemuUnavailable;
    if (!kvmAvailable()) return error.KvmUnavailable;

    const image = try paths.image(allocator);
    defer allocator.free(image);
    if (!exists(image)) return error.ImageNotBuilt;
    const kernel = kernelPath(allocator) catch return error.KernelNotFound;

    // Not freed: `id` is returned to the caller and `console_path` is returned
    // inside the session metadata, so both must outlive this function.
    const id = try randomId(allocator);
    const dir = try compat.path.join(allocator, &.{ paths.root, id });
    defer allocator.free(dir);
    try compat.cwd().makePath(dir);

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

    // Storage is a qcow2 file owned by us: no host block device is attached,
    // so a compromised guest cannot touch real disks.
    const disk = try compat.path.join(allocator, &.{ dir, "disk.qcow2" });
    defer allocator.free(disk);
    {
        const size = try std.fmt.allocPrint(allocator, "{d}G", .{profile.disk_gb});
        defer allocator.free(size);
        const created = exec.run(allocator, &.{ "qemu-img", "create", "-f", "qcow2", disk, size }, 256 * 1024) catch
            return error.DiskCreateFailed;
        if (!created.ok()) return .{ .ok = false, .output = textOf(created) };
    }

    const guest_port: u16 = if (mode == .web) 80 else 23;
    const forward = try std.fmt.allocPrint(
        allocator,
        "user,id=n0,hostfwd=tcp:127.0.0.1:{d}-:{d}",
        .{ if (expose_port == 0) @as(u16, 0) else expose_port, guest_port },
    );
    defer allocator.free(forward);
    const netdev = if (expose_port == 0)
        "user,id=n0"
    else
        forward;

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    const smp = try std.fmt.allocPrint(allocator, "{d}", .{profile.cpu_cores});
    defer allocator.free(smp);
    const mem = try std.fmt.allocPrint(allocator, "{d}", .{profile.memory_mb});
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
        "-enable-kvm",
        // The guest sees the host's CPU model because the identity is being
        // replicated; no other host hardware is passed through.
        "-cpu", "host",
        "-smp", smp,
        "-m", mem,
        "-kernel", kernel,
        "-initrd", image,
        "-append", "console=ttyS0 quiet panic=1",
        "-display", "none",
        "-no-reboot",
        // Present a plausible machine, but nothing is passed through.
        "-machine", "pc",
        "-smbios", smbios,
        "-netdev", netdev,
        // Unique MAC per session: a shared one would let a guest correlate
        // sessions and lets the host tell guests apart in its own ARP tables.
        "-device", try std.fmt.allocPrint(allocator, "virtio-net-pci,netdev=n0,mac={s}", .{mac}),
        // No host device passthrough of any kind.
        "-nodefaults",
        "-monitor", "none",
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
    const pid = child.id orelse return error.SpawnFailed;
    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_text);
    try writeFile(pid_path, pid_text);

    // The guest must outlive this call, and somebody has to drain its console.
    // A detached supervisor owns the Child: without an owner the process is
    // reaped immediately and turns into a zombie, and the boot log is lost.
    const guard = try std.heap.page_allocator.create(GuestGuard);
    guard.* = .{
        .child = child,
        .pid = pid,
        .pid_path = try std.heap.page_allocator.dupe(u8, pid_path),
        .console_path = try std.heap.page_allocator.dupe(u8, console_path),
    };
    const thread = std.Thread.spawn(.{}, pumpGuest, .{guard}) catch |err| {
        child.kill(compat.io());
        std.heap.page_allocator.destroy(guard);
        return err;
    };
    thread.detach();

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

    return .{
        .ok = true,
        .output = "guest 已启动",
        .session_id = try allocator.dupe(u8, id),
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
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    compat.deleteFileAbsolute(pid_path) catch {};
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
            .running = pid > 0 and processAlive(pid),
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

fn processAlive(pid: i32) bool {
    var buffer: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&buffer, "/proc/{d}", .{pid}) catch return false;
    return exists(dir);
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
    _ = exec.run(std.heap.page_allocator, &.{ "rm", "-rf", path }, 64 * 1024) catch {};
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
