const std = @import("std");
const compat = @import("compat");

/// Plausible content for the honeypot guest.
///
/// Everything here is fabricated: fake users, fake credentials, fake access
/// logs with fake source addresses. The point is that an intruder who lands in
/// the guest should find a machine that looks lived-in, so they keep poking at
/// it while the observation channels record what they do.
///
/// All of it is generated per build from a random seed, so two honeypots on the
/// same host do not look like copies of one another.
pub const Generator = struct {
    allocator: std.mem.Allocator,
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator) Generator {
        var seed_bytes: [8]u8 = undefined;
        compat.randomBytes(&seed_bytes);
        const seed = std.mem.readInt(u64, &seed_bytes, .little) ^
            @as(u64, @intCast(compat.milliTimestamp()));
        return .{ .allocator = allocator, .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn random(self: *Generator) std.Random {
        return self.prng.random();
    }

    fn pick(self: *Generator, comptime options: []const []const u8) []const u8 {
        return options[self.random().uintLessThan(usize, options.len)];
    }

    fn between(self: *Generator, low: u32, high: u32) u32 {
        return self.random().intRangeAtMost(u32, low, high);
    }

    /// Exposed for tests: fake attack sources must never reach a real network.
    pub fn sourceAddressForTest(self: *Generator, allocator: std.mem.Allocator) ![]u8 {
        return sourceAddress(self, allocator);
    }

    /// A hostname that reads like a real deployment rather than "honeypot".
    pub fn hostname(self: *Generator, allocator: std.mem.Allocator) ![]u8 {
        const role = self.pick(&.{ "web", "api", "db", "app", "edge", "cache", "queue" });
        const env = self.pick(&.{ "prod", "staging", "internal", "dev", "eu-west", "us-east" });
        const index = self.between(1, 24);
        return std.fmt.allocPrint(allocator, "{s}-{s}-{d:0>2}", .{ role, env, index });
    }

    /// Public-looking addresses for the fake attack log. Documentation ranges
    /// and private space are avoided so nothing points at a real host.
    fn sourceAddress(self: *Generator, allocator: std.mem.Allocator) ![]u8 {
        const first = self.pick(&.{ "45", "62", "77", "91", "103", "141", "185", "193", "212" });
        return std.fmt.allocPrint(allocator, "{s}.{d}.{d}.{d}", .{
            first,
            self.between(2, 250),
            self.between(0, 255),
            self.between(1, 254),
        });
    }

    fn userAgent(self: *Generator) []const u8 {
        return self.pick(&.{
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36",
            "Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.4 Safari/605.1.15",
            "python-requests/2.31.0",
            "curl/8.5.0",
            "Go-http-client/1.1",
            "Mozilla/5.0 (compatible; Nmap Scripting Engine; https://nmap.org/book/nse.html)",
        });
    }
};

/// Writes the decoy tree into a prepared rootfs and returns the hostname that
/// /init should set, so the identity files and the live system agree.
///
/// The caller uses one generator for the whole build: seeding twice would make
/// the hostname and the served site independent of each other, which is exactly
/// the kind of incoherence an intruder notices.
pub fn populate(
    allocator: std.mem.Allocator,
    rootfs: []const u8,
    mode: []const u8,
) ![]u8 {
    var gen = Generator.init(allocator);
    const hostname = try gen.hostname(allocator);

    try writeTree(allocator, rootfs, try renderIdentity(allocator, &gen, hostname, mode));
    try writeTree(allocator, rootfs, try renderAccounts(allocator, &gen));
    try writeTree(allocator, rootfs, try renderWeb(allocator, &gen, mode));
    try writeTree(allocator, rootfs, try renderLogs(allocator, &gen));
    try writeTree(allocator, rootfs, try renderSecrets(allocator, &gen, hostname));
    return hostname;
}

const File = struct {
    path: []const u8,
    content: []const u8,
    mode: u32 = 0o644,
    /// True when `content` was allocated and must be freed with the tree.
    owned: bool = false,
};

fn renderIdentity(
    allocator: std.mem.Allocator,
    gen: *Generator,
    hostname: []const u8,
    mode: []const u8,
) ![]const File {
    var files = std.array_list.Managed(File).init(allocator);
    const os_release = gen.pick(&.{
        "Ubuntu 22.04.4 LTS (Jammy Jellyfish)",
        "Debian GNU/Linux 12 (bookworm)",
        "CentOS Linux 7 (Core)",
        "Rocky Linux 9.4 (Blue Onyx)",
    });
    const version_id = if (std.mem.indexOf(u8, os_release, "22.04") != null)
        "22.04"
    else if (std.mem.indexOf(u8, os_release, "12") != null)
        "12"
    else if (std.mem.indexOf(u8, os_release, "7") != null)
        "7"
    else
        "9";

    try files.append(.{
        .path = "etc/hostname",
        .content = try std.fmt.allocPrint(allocator, "{s}\n", .{hostname}),
        .owned = true,
    });
    try files.append(.{
        .path = "etc/os-release",
        .content = try std.fmt.allocPrint(
            allocator,
            "PRETTY_NAME=\"{s}\"\nNAME=\"Linux\"\nVERSION_ID=\"{s}\"\nVERSION=\"(build {d})\"\nID=linux\n",
            .{ os_release, version_id, gen.between(20, 240) },
        ),
        .owned = true,
    });
    try files.append(.{
        .path = "etc/hosts",
        .content = try std.fmt.allocPrint(
            allocator,
            "127.0.0.1\tlocalhost\n127.0.1.1\t{s}\n10.0.2.15\t{s}\n\n::1\tlocalhost ip6-localhost\n",
            .{ hostname, hostname },
        ),
        .owned = true,
    });
    // A listening-service hint file sells the "real server" story cheaply.
    if (std.mem.eql(u8, mode, "web") or std.mem.eql(u8, mode, "both")) {
        try files.append(.{
            .path = "etc/nginx/sites-enabled/default",
            .content = try std.fmt.allocPrint(
                allocator,
                "server {{\n    listen 80 default_server;\n    server_name {s};\n    root /var/www/html;\n    index index.html index.php;\n}}\n",
                .{hostname},
            ),
            .owned = true,
        });
    }
    return try files.toOwnedSlice();
}

fn renderAccounts(allocator: std.mem.Allocator, gen: *Generator) ![]const File {
    var files = std.array_list.Managed(File).init(allocator);
    // A passwd that looks like a normal small server, not a container.
    try files.append(.{
        .path = "etc/passwd",
        .content =
        \\root:x:0:0:root:/root:/bin/bash
        \\daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        \\bin:x:2:2:bin:/bin:/usr/sbin/nologin
        \\sys:x:3:3:sys:/dev:/usr/sbin/nologin
        \\sync:x:4:65534:sync:/bin:/bin/sync
        \\www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
        \\sshd:x:110:65534::/run/sshd:/usr/sbin/nologin
        \\deploy:x:1000:1000:deploy,,,:/home/deploy:/bin/bash
        \\
        ,
    });
    // Hashes are syntactically valid but generated per build.
    var shadow = std.Io.Writer.Allocating.init(allocator);
    const w = &shadow.writer;
    try w.print("root:{s}:19700:0:99999:7:::\n", .{try fakeHash(allocator, gen)});
    try w.print("www-data:*:19700:0:99999:7:::\n", .{});
    try w.print("deploy:{s}:19710:0:99999:7:::\n", .{try fakeHash(allocator, gen)});
    try files.append(.{ .path = "etc/shadow", .content = shadow.written(), .mode = 0o640 });

    try files.append(.{
        .path = "etc/group",
        .content =
        \\root:x:0:
        \\www-data:x:33:
        \\deploy:x:1000:
        \\sudo:x:27:deploy
        \\
        ,
    });
    // An authorized_keys file invites an attacker to think a login would work.
    var keys = std.Io.Writer.Allocating.init(allocator);
    try keys.writer.writeAll(
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI",
    );
    var random_key: [68]u8 = undefined;
    gen.random().bytes(&random_key);
    for (random_key) |byte| {
        try keys.writer.writeByte("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"[byte % 64]);
    }
    try keys.writer.print(" deploy@{s}\n", .{
        gen.pick(&.{"ci-runner", "ops-laptop", "bastion"}),
    });
    try files.append(.{
        .path = "root/.ssh/authorized_keys",
        .content = keys.written(),
        .mode = 0o600,
    });

    // Shell history is the cheapest way to make the box feel used.
    const commands = [_][]const u8{
        "apt update && apt upgrade -y",
        "systemctl restart nginx",
        "tail -f /var/log/nginx/access.log",
        "docker ps",
        "certbot renew --dry-run",
        "rsync -avz ./public/ deploy@10.0.2.40:/var/www/html/",
        "journalctl -u app.service -n 200 --no-pager",
        "mysql -u app -p app_prod < /srv/backup/latest.sql",
        "git pull && make deploy",
        "vim /etc/nginx/sites-enabled/app.conf",
    };
    var history = std.Io.Writer.Allocating.init(allocator);
    const count = gen.between(5, commands.len);
    for (commands[0..count]) |command| {
        try history.writer.print("{s}\n", .{command});
    }
    try files.append(.{
        .path = "root/.bash_history",
        .content = history.written(),
        .mode = 0o600,
    });
    return try files.toOwnedSlice();
}

fn fakeHash(allocator: std.mem.Allocator, gen: *Generator) ![]u8 {
    const alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const prefix = gen.pick(&.{ "$6$", "$5$", "$y$j9T$" });
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice(prefix);
    var salt: [16]u8 = undefined;
    gen.random().bytes(&salt);
    for (salt) |byte| try out.append(alphabet[byte % 64]);
    try out.append('$');
    var body: [43]u8 = undefined;
    gen.random().bytes(&body);
    for (body) |byte| try out.append(alphabet[byte % 64]);
    return out.toOwnedSlice();
}

fn renderWeb(
    allocator: std.mem.Allocator,
    gen: *Generator,
    mode: []const u8,
) ![]const File {
    var files = std.array_list.Managed(File).init(allocator);
    if (!std.mem.eql(u8, mode, "web") and !std.mem.eql(u8, mode, "both")) return try files.toOwnedSlice();

    const theme = gen.pick(&.{
        "Northwind Portal",
        "Acme Intranet",
        "Grafana",
        "Jenkins",
        "phpMyAdmin",
    });
    try files.append(.{
        .path = "var/www/html/index.html",
        .content = try std.fmt.allocPrint(
            allocator,
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="utf-8">
            \\  <title>{s}</title>
            \\  <link rel="stylesheet" href="/assets/site.css">
            \\</head>
            \\<body>
            \\  <header><h1>{s}</h1></header>
            \\  <main>
            \\    <p>Sign in to continue.</p>
            \\    <form action="/login.php" method="post">
            \\      <input name="user" placeholder="Username">
            \\      <input name="pass" type="password" placeholder="Password">
            \\      <button type="submit">Log in</button>
            \\    </form>
            \\  </main>
            \\  <footer>v{d}.{d}.{d} &middot; build {d}</footer>
            \\</body>
            \\</html>
            \\
            ,
            .{
                theme,
                theme,
                gen.between(1, 4),
                gen.between(0, 20),
                gen.between(0, 40),
                gen.between(100, 9999),
            },
        ),
        .owned = true,
    });
    try files.append(.{
        .path = "var/www/html/robots.txt",
        .content = "User-agent: *\nDisallow: /admin/\nDisallow: /backup/\nAllow: /\n",
    });
    // A "backup" directory that looks like someone made a mistake: this is
    // exactly what an automated scanner will try to fetch.
    try files.append(.{
        .path = "var/www/html/backup/config.php.bak",
        .content = try std.fmt.allocPrint(
            allocator,
            "<?php\n$db_host = '127.0.0.1';\n$db_name = 'app_prod';\n$db_user = 'app';\n$db_pass = '{s}';\n",
            .{try password(allocator, gen)},
        ),
        .owned = true,
    });
    try files.append(.{
        .path = "var/www/html/assets/site.css",
        .content = "body{font-family:system-ui,sans-serif;margin:0}header{padding:24px}h1{margin:0}\n",
    });
    return try files.toOwnedSlice();
}

fn password(allocator: std.mem.Allocator, gen: *Generator) ![]u8 {
    const words = [_][]const u8{
        "sunset", "harbor", "copper", "lantern", "meadow", "quartz",
        "ember",  "willow", "cobalt", "feather", "marble", "thunder",
    };
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{d}",
        .{ gen.pick(&words), gen.pick(&words), gen.between(10, 99) },
    );
}

fn renderLogs(allocator: std.mem.Allocator, gen: *Generator) ![]const File {
    var files = std.array_list.Managed(File).init(allocator);
    // Access log entries spread over the past two weeks with scans mixed in,
    // so the log looks like a server that has been probed before.
    var log = std.Io.Writer.Allocating.init(allocator);
    const w = &log.writer;
    const now = compat.timestamp();
    const paths = [_][]const u8{
        "/",          "/index.php",   "/wp-login.php", "/admin",
        "/.env",      "/phpmyadmin/", "/api/v1/health", "/login",
        "/backup.zip", "/cgi-bin/luci",
    };
    const total = gen.between(90, 220);
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        const seconds_ago = gen.between(60, 14 * 24 * 3600);
        const stamp = now - @as(i64, @intCast(seconds_ago));
        const address = try gen.sourceAddress(allocator);
        defer allocator.free(address);
        const status = gen.pick(&.{ "200", "200", "200", "301", "404", "404", "403", "500" });
        const bytes = gen.between(180, 48000);
        const stamp_text = try nginxStamp(allocator, stamp);
        defer allocator.free(stamp_text);
        try w.print(
            "{s} - - [{s}] \"GET {s} HTTP/1.1\" {s} {d} \"-\" \"{s}\"\n",
            .{
                address,
                stamp_text,
                gen.pick(&paths),
                status,
                bytes,
                gen.userAgent(),
            },
        );
    }
    try files.append(.{
        .path = "var/log/nginx/access.log",
        .content = log.written(),
    });

    // Auth log with failed logins from several addresses.
    var auth = std.Io.Writer.Allocating.init(allocator);
    const a = &auth.writer;
    const users = [_][]const u8{ "root", "admin", "deploy", "ubuntu", "test", "oracle" };
    var tries: u32 = 0;
    while (tries < gen.between(20, 60)) : (tries += 1) {
        const address = try gen.sourceAddress(allocator);
        defer allocator.free(address);
        const seconds_ago = gen.between(300, 10 * 24 * 3600);
        const date_text = try monthDay(allocator, now - @as(i64, @intCast(seconds_ago)));
        defer allocator.free(date_text);
        try a.print(
            "{s} {s} sshd[{d}]: Failed password for {s}{s} from {s} port {d} ssh2\n",
            .{
                date_text,
                "06:00:00",
                gen.between(1000, 32000),
                if (gen.between(0, 3) == 0) "invalid user " else "",
                gen.pick(&users),
                address,
                gen.between(1024, 65000),
            },
        );
    }
    try files.append(.{ .path = "var/log/auth.log", .content = auth.written(), .mode = 0o640 });
    return try files.toOwnedSlice();
}

pub fn nginxStampForTest(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    return nginxStamp(allocator, timestamp);
}

pub fn monthDayForTest(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    return monthDay(allocator, timestamp);
}

/// Unix epoch to a civil year, so the log carries the real year instead of a
/// number derived from a day count.
fn year_of(timestamp: i64) u16 {
    var days = @divTrunc(timestamp, 24 * 3600);
    var year: u16 = 1970;
    while (true) {
        const length: i64 = if (isLeap(year)) 366 else 365;
        if (days < length) return year;
        days -= length;
        year += 1;
    }
}

fn isLeap(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

/// nginx combined-log timestamp: 12/Mar/2024:07:31:04 +0000.
fn nginxStamp(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    const day_seconds: i64 = 24 * 3600;
    const days = @divTrunc(timestamp, day_seconds);
    const seconds_of_day = @mod(timestamp, day_seconds);
    const hours = @divTrunc(seconds_of_day, 3600);
    const minutes = @divTrunc(@mod(seconds_of_day, 3600), 60);
    const seconds = @mod(seconds_of_day, 60);
    return std.fmt.allocPrint(allocator, "{d:0>2}/{s}/{d}:{d:0>2}:{d:0>2}:{d:0>2} +0000", .{
        @as(u8, @intCast(@mod(days, 28) + 1)),
        months[@intCast(@mod(@divTrunc(days, 30), 12))],
        year_of(timestamp),
        @as(u8, @intCast(hours)),
        @as(u8, @intCast(minutes)),
        @as(u8, @intCast(seconds)),
    });
}

fn monthDay(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    // The log format only needs something monotonic and date-shaped.
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    const day_seconds: i64 = 24 * 3600;
    const days = @divTrunc(timestamp, day_seconds);
    const month_index = @mod(@divTrunc(days, 30), 12);
    const day: u8 = @intCast(@mod(days, 28) + 1);
    return std.fmt.allocPrint(allocator, "{s} {d: >2}", .{
        months[@intCast(month_index)],
        day,
    });
}

fn renderSecrets(
    allocator: std.mem.Allocator,
    gen: *Generator,
    hostname: []const u8,
) ![]const File {
    var files = std.array_list.Managed(File).init(allocator);
    try files.append(.{
        .path = "srv/app/.env",
        .content = try std.fmt.allocPrint(
            allocator,
            \\APP_ENV=production
            \\APP_NAME={s}
            \\DB_HOST=127.0.0.1
            \\DB_DATABASE=app_prod
            \\DB_USERNAME=app
            \\DB_PASSWORD={s}
            \\REDIS_HOST=127.0.0.1
            \\MAIL_MAILER=smtp
            \\MAIL_HOST=smtp.internal
            \\MAIL_USERNAME=noreply@{s}
            \\
            ,
            .{ hostname, try password(allocator, gen), hostname },
        ),
        .owned = true,
        .mode = 0o600,
    });
    try files.append(.{
        .path = "etc/crontab",
        .content = try std.fmt.allocPrint(
            allocator,
            "SHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n\n" ++
                "*/{d} * * * * root /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1\n",
            .{gen.between(5, 30)},
        ),
        .owned = true,
    });
    return try files.toOwnedSlice();
}

/// Takes ownership of `files` (an owned slice from the render functions).
fn writeTree(allocator: std.mem.Allocator, rootfs: []const u8, files: []const File) !void {
    defer {
        for (files) |file| {
            if (file.owned) allocator.free(file.content);
        }
        allocator.free(files);
    }
    for (files) |file| {
        const path = try compat.path.join(allocator, &.{ rootfs, file.path });
        defer allocator.free(path);
        if (compat.path.dirname(path)) |dir| compat.cwd().makePath(dir) catch {};
        var handle = try compat.createFileAbsolute(path, .{
            .truncate = true,
            .mode = @intCast(file.mode),
        });
        defer handle.close();
        try handle.writeAll(file.content);
    }
}
