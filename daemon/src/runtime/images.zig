const std = @import("std");
const catalog = @import("catalog.zig");

pub fn imageRef(allocator: std.mem.Allocator, image: []const u8, tag: []const u8) ![]u8 {
    if (tag.len == 0) return allocator.dupe(u8, image);
    if (std.mem.indexOfScalar(u8, image, '@') != null) return allocator.dupe(u8, image);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ image, tag });
}

pub fn renderDockerfile(
    allocator: std.mem.Allocator,
    runtime: *const catalog.Runtime,
    image: []const u8,
    tag: []const u8,
    extensions: []const []const u8,
    mirror: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    const image_ref = try imageRef(allocator, image, tag);
    defer allocator.free(image_ref);

    try writer.print("FROM {s}\n", .{image_ref});
    try writer.print("ENV DEBIAN_FRONTEND=noninteractive\n", .{});
    try appendMirror(writer, runtime, mirror);

    if (std.mem.eql(u8, runtime.id, "php")) {
        try writer.writeAll(
            "RUN apt-get update \\\n" ++
                " && apt-get install -y --no-install-recommends nginx supervisor curl ca-certificates \\\n" ++
                " && rm -rf /var/lib/apt/lists/*\n",
        );
        try writer.writeAll("COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/\n");
        if (extensions.len > 0) {
            try writer.writeAll("RUN install-php-extensions");
            for (extensions) |extension| try writer.print(" {s}", .{extension});
            try writer.writeAll("\n");
        }
        try writer.writeAll(
            "RUN mkdir -p /etc/hampanel /var/www/html \\\n" ++
                " && ln -sf /dev/stdout /var/log/nginx/access.log \\\n" ++
                " && ln -sf /dev/stderr /var/log/nginx/error.log\n",
        );
    } else {
        try writer.writeAll(
            "RUN if command -v apt-get >/dev/null 2>&1; then \\\n" ++
                "      apt-get update && apt-get install -y --no-install-recommends supervisor curl ca-certificates \\\n" ++
                "      && rm -rf /var/lib/apt/lists/*; \\\n" ++
                "    elif command -v apk >/dev/null 2>&1; then \\\n" ++
                "      apk add --no-cache supervisor curl ca-certificates; \\\n" ++
                "    fi\n",
        );
        if (extensions.len > 0) {
            if (std.mem.eql(u8, runtime.id, "node")) {
                try writer.writeAll("RUN npm install -g --no-audit --no-fund");
                for (extensions) |extension| try writer.print(" {s}", .{extension});
                try writer.writeAll("\n");
            } else if (std.mem.eql(u8, runtime.id, "python")) {
                try writer.writeAll("RUN pip install --no-cache-dir");
                for (extensions) |extension| try writer.print(" {s}", .{extension});
                try writer.writeAll("\n");
            } else if (std.mem.eql(u8, runtime.id, "ruby")) {
                try writer.writeAll("RUN gem install --no-document");
                for (extensions) |extension| try writer.print(" {s}", .{extension});
                try writer.writeAll("\n");
            } else if (std.mem.eql(u8, runtime.id, "go")) {
                for (extensions) |extension| {
                    if (std.mem.eql(u8, extension, "air")) {
                        try writer.writeAll("RUN go install github.com/air-verse/air@latest\n");
                    } else if (std.mem.eql(u8, extension, "delve")) {
                        try writer.writeAll("RUN go install github.com/go-delve/delve/cmd/dlv@latest\n");
                    }
                }
                try writer.writeAll("ENV PATH=/root/go/bin:$PATH\n");
            }
        }
        try writer.writeAll("RUN mkdir -p /etc/hampanel\n");
    }

    try writer.print("WORKDIR {s}\n", .{runtime.workdir});
    try writer.writeAll("CMD [\"/usr/bin/supervisord\",\"-c\",\"/etc/hampanel/supervisord.conf\"]\n");
    return out.toOwnedSlice();
}

fn appendMirror(writer: anytype, runtime: *const catalog.Runtime, mirror: []const u8) !void {
    if (mirror.len == 0) return;

    var apt_host: []const u8 = "";
    var alpine_host: []const u8 = "";
    var pip_url: []const u8 = "";
    var npm_url: []const u8 = "";
    var composer_url: []const u8 = "";

    if (catalog.mirrorPreset(mirror)) |preset| {
        apt_host = preset.apt_host;
        alpine_host = preset.alpine_host;
        pip_url = preset.pip_url;
        npm_url = preset.npm_url;
        composer_url = preset.composer_url;
    } else if (std.mem.startsWith(u8, mirror, "custom:")) {
        const url = mirror["custom:".len..];
        apt_host = hostOf(url);
        alpine_host = apt_host;
        pip_url = url;
        npm_url = url;
        composer_url = url;
    } else {
        return;
    }
    if (apt_host.len == 0) return;

    try writer.writeAll("RUN if [ -f /etc/apt/sources.list ]; then \\\n");
    try writer.print(
        "      sed -i 's|deb.debian.org|{s}|g; s|security.debian.org|{s}|g; s|archive.ubuntu.com|{s}|g; s|security.ubuntu.com|{s}|g' /etc/apt/sources.list; \\\n",
        .{ apt_host, apt_host, apt_host, apt_host },
    );
    try writer.writeAll("    fi; \\\n");
    try writer.writeAll("    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \\\n");
    try writer.print(
        "      sed -i 's|deb.debian.org|{s}|g; s|security.debian.org|{s}|g' /etc/apt/sources.list.d/debian.sources; \\\n",
        .{ apt_host, apt_host },
    );
    try writer.writeAll("    fi; \\\n");
    try writer.print(
        "    if [ -f /etc/apk/repositories ]; then sed -i 's|dl-cdn.alpinelinux.org|{s}|g' /etc/apk/repositories; fi\n",
        .{alpine_host},
    );

    if (std.mem.eql(u8, runtime.id, "python") and pip_url.len > 0) {
        try writer.print("ENV PIP_INDEX_URL={s}\n", .{pip_url});
        if (hostOf(pip_url).len > 0) {
            try writer.print("ENV PIP_TRUSTED_HOST={s}\n", .{hostOf(pip_url)});
        }
    }
    if (std.mem.eql(u8, runtime.id, "node") and npm_url.len > 0) {
        try writer.print("RUN npm config set registry {s}\n", .{npm_url});
    }
    if (std.mem.eql(u8, runtime.id, "php") and composer_url.len > 0) {
        try writer.print(
            "RUN if command -v composer >/dev/null 2>&1; then composer config -g repos.packagist composer {s}; fi\n",
            .{composer_url},
        );
    }
}

fn hostOf(url: []const u8) []const u8 {
    var value = url;
    if (std.mem.indexOf(u8, value, "://")) |index| value = value[index + 3 ..];
    const end = std.mem.indexOfAny(u8, value, "/:") orelse value.len;
    return value[0..end];
}

test "node dockerfile renders extensions and mirror" {
    const allocator = std.testing.allocator;
    const runtime = catalog.find("node").?;
    const dockerfile = try renderDockerfile(
        allocator,
        runtime,
        runtime.image,
        runtime.tag,
        &.{"typescript"},
        "aliyun",
    );
    defer allocator.free(dockerfile);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "FROM node:24-bookworm-slim") != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "npm install -g --no-audit --no-fund typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "registry.npmmirror.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "/etc/hampanel/supervisord.conf") != null);
}

test "php dockerfile installs nginx and extensions" {
    const allocator = std.testing.allocator;
    const runtime = catalog.find("php").?;
    const dockerfile = try renderDockerfile(
        allocator,
        runtime,
        runtime.image,
        runtime.tag,
        &.{ "opcache", "redis" },
        "",
    );
    defer allocator.free(dockerfile);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "FROM php:8.5-fpm-bookworm") != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "install-php-extensions opcache redis") != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "nginx supervisor") != null);
}
