const std = @import("std");
const Conn = @import("../net/conn.zig").Conn;
const request = @import("request.zig");

pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

pub const Error = error{
    NotWebSocket,
    MissingKey,
    ProtocolError,
    FrameTooLarge,
    UnsupportedOpcode,
    EndOfStream,
    UnexpectedEof,
    Io,
    WouldBlock,
    OutOfMemory,
};

pub fn isUpgrade(req: request.Request) bool {
    const upgrade = req.header("upgrade") orelse return false;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " \t"), "websocket")) return false;
    return req.hasToken("connection", "upgrade");
}

pub fn writeUpgrade(conn: *Conn, req: request.Request, allocator: std.mem.Allocator) Error!void {
    if (!isUpgrade(req)) return error.NotWebSocket;
    const version_raw = req.header("sec-websocket-version") orelse "";
    if (!std.mem.eql(u8, std.mem.trim(u8, version_raw, " \t"), "13")) {
        return error.ProtocolError;
    }
    const key_raw = req.header("sec-websocket-key") orelse return error.MissingKey;
    const key = std.mem.trim(u8, key_raw, " \t");
    if (key.len == 0) return error.MissingKey;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(key) catch {
        return error.ProtocolError;
    };
    if (decoded_len != 16) return error.ProtocolError;

    const accept = try acceptKey(allocator, key);
    defer allocator.free(accept);

    var buffer: [512]u8 = undefined;
    const head = std.fmt.bufPrint(
        &buffer,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    ) catch return error.ProtocolError;

    conn.writeAll(head) catch return error.Io;
}

fn acceptKey(allocator: std.mem.Allocator, key: []const u8) Error![]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    const size = std.base64.standard.Encoder.calcSize(digest.len);
    const out = allocator.alloc(u8, size) catch return error.OutOfMemory;
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out;
}

pub fn readFrame(conn: *Conn, allocator: std.mem.Allocator, max_payload: usize) Error!?Frame {
    var header: [2]u8 = undefined;
    conn.readFull(&header) catch |e| switch (e) {
        error.EndOfStream => return null,
        else => return error.Io,
    };

    const fin = (header[0] & 0x80) != 0;
    const opcode = decodeOpcode(header[0] & 0x0F) orelse return error.UnsupportedOpcode;
    const masked = (header[1] & 0x80) != 0;
    var length: u64 = header[1] & 0x7F;

    if (length == 126) {
        var ext: [2]u8 = undefined;
        conn.readFull(&ext) catch return error.Io;
        length = std.mem.readInt(u16, &ext, .big);
    } else if (length == 127) {
        var ext: [8]u8 = undefined;
        conn.readFull(&ext) catch return error.Io;
        length = std.mem.readInt(u64, &ext, .big);
    }

    if ((length & (@as(u64, 1) << 63)) != 0) return error.ProtocolError;
    if (!masked) return error.ProtocolError;
    if (opcode == .close or opcode == .ping or opcode == .pong) {
        if (!fin or length > 125) return error.ProtocolError;
    }
    if (length > max_payload) return error.FrameTooLarge;
    const size: usize = @intCast(length);

    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    conn.readFull(&mask) catch return error.Io;

    const payload = allocator.alloc(u8, size) catch return error.OutOfMemory;
    if (size > 0) conn.readFull(payload) catch return error.Io;
    if (masked and size > 0) {
        var i: usize = 0;
        while (i < payload.len) : (i += 1) payload[i] ^= mask[i % 4];
    }

    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

pub fn writeFrame(conn: *Conn, opcode: Opcode, payload: []const u8) Error!void {
    var header: [10]u8 = undefined;
    var head_len: usize = 2;
    header[0] = 0x80 | @backingInt(opcode);
    if (payload.len < 126) {
        header[1] = @intCast(payload.len);
    } else if (payload.len <= 0xFFFF) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        head_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        head_len = 10;
    }
    conn.writeAll(header[0..head_len]) catch return error.Io;
    if (payload.len > 0) conn.writeAll(payload) catch return error.Io;
}

pub fn writeText(conn: *Conn, text: []const u8) Error!void {
    return writeFrame(conn, .text, text);
}

pub fn writeBinary(conn: *Conn, data: []const u8) Error!void {
    return writeFrame(conn, .binary, data);
}

pub fn writeClose(conn: *Conn, code: u16, reason: []const u8) void {
    var payload: [125]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], code, .big);
    const reason_len = @min(reason.len, payload.len - 2);
    @memcpy(payload[2 .. 2 + reason_len], reason[0..reason_len]);
    writeFrame(conn, .close, payload[0 .. 2 + reason_len]) catch {};
}

fn decodeOpcode(raw: u8) ?Opcode {
    return switch (raw) {
        0x0 => .continuation,
        0x1 => .text,
        0x2 => .binary,
        0x8 => .close,
        0x9 => .ping,
        0xA => .pong,
        else => null,
    };
}
