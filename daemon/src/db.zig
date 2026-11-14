const std = @import("std");
const c = @import("sqlite_c");
const compat = @import("compat");

fn logSqliteError(handle: *c.sqlite3, operation: []const u8) void {
    std.debug.print(
        "hampaneld: sqlite {s} failed: {s}\n",
        .{ operation, std.mem.span(c.sqlite3_errmsg(handle)) },
    );
}

pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    text: []const u8,
};

pub fn pathFor(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return compat.path.join(allocator, &.{ data_dir, "hampanel.db" });
}

pub const Db = struct {
    handle: *c.sqlite3,
    mutex: std.Io.Mutex = .init,
    file_path: ?[:0]u8 = null,

    pub fn open(raw_path: []const u8) !Db {
        const owned = try compat.dupeZ(std.heap.page_allocator, raw_path);

        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(owned.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |h| {
                logSqliteError(h, "open");
                _ = c.sqlite3_close(h);
            }
            std.heap.page_allocator.free(owned);
            return error.SqliteOpenFailed;
        }
        var db = Db{ .handle = handle.?, .file_path = owned };
        try db.exec("PRAGMA journal_mode = WAL");
        try db.exec("PRAGMA synchronous = NORMAL");
        try db.exec("PRAGMA foreign_keys = ON");
        try db.exec("PRAGMA busy_timeout = 5000");
        return db;
    }

    pub fn path(self: *const Db) ?[]const u8 {
        return self.file_path;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(self.handle);
        if (self.file_path) |owned| std.heap.page_allocator.free(owned);
        self.file_path = null;
        self.mutex = .init;
        self.handle = undefined;
    }

    pub fn errmsg(self: *Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn lock(self: *Db) void {
        self.mutex.lockUncancelable(compat.io());
    }

    pub fn unlock(self: *Db) void {
        self.mutex.unlock(compat.io());
    }

    pub fn exec(self: *Db, sql: []const u8) !void {
        self.lock();
        defer self.unlock();
        return self.execUnlocked(sql);
    }

    pub fn execUnlocked(self: *Db, sql: []const u8) !void {
        var err: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &err);
        if (rc != c.SQLITE_OK) {
            if (err != null) {
                std.debug.print(
                    "hampaneld: sqlite exec failed: {s}\n",
                    .{std.mem.span(err)},
                );
                c.sqlite3_free(err);
            } else {
                logSqliteError(self.handle, "exec");
            }
            return error.SqliteExecFailed;
        }
    }

    pub fn execute(self: *Db, sql: []const u8, values: []const Value) !void {
        self.lock();
        defer self.unlock();
        var statement = try self.prepareUnlocked(sql);
        defer statement.deinit();
        try statement.bind(values);
        _ = try statement.step();
    }

    pub fn prepare(self: *Db, sql: []const u8) !Statement {
        self.lock();
        return self.prepareUnlocked(sql);
    }

    pub fn prepareUnlocked(self: *Db, sql: []const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            logSqliteError(self.handle, "prepare");
            return error.SqlitePrepareFailed;
        }
        return .{ .handle = stmt orelse return error.SqlitePrepareFailed };
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes64(self.handle);
    }

    pub fn getSetting(self: *Db, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        self.lock();
        defer self.unlock();
        var statement = try self.prepareUnlocked("SELECT value FROM settings WHERE key = ?1");
        defer statement.deinit();
        try statement.bind(&.{.{ .text = key }});
        if (!(try statement.step())) return null;
        return try statement.dupeColumnText(allocator, 0);
    }

    pub fn setSetting(self: *Db, key: []const u8, value: []const u8) !void {
        try self.execute(
            "INSERT INTO settings(key, value, updated_at) VALUES(?1, ?2, ?3) " ++
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            &.{ .{ .text = key }, .{ .text = value }, .{ .int = compat.timestamp() } },
        );
    }
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn bind(self: *Statement, values: []const Value) !void {
        for (values, 0..) |value, index| {
            const position: c_int = @intCast(index + 1);
            const rc = switch (value) {
                .null => c.sqlite3_bind_null(self.handle, position),
                .int => |number| c.sqlite3_bind_int64(self.handle, position, number),
                .float => |number| c.sqlite3_bind_double(self.handle, position, number),
                .text => |text| c.sqlite3_bind_text(self.handle, position, text.ptr, @intCast(text.len), null),
            };
            if (rc != c.SQLITE_OK) {
                if (c.sqlite3_db_handle(self.handle)) |database| {
                    logSqliteError(database, "bind");
                }
                return error.SqliteBindFailed;
            }
        }
    }

    pub fn step(self: *Statement) !bool {
        switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => return true,
            c.SQLITE_DONE => return false,
            else => {
                if (c.sqlite3_db_handle(self.handle)) |database| {
                    logSqliteError(database, "step");
                }
                return error.SqliteStepFailed;
            },
        }
    }

    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn columnText(self: *Statement, index: c_int) []const u8 {
        const pointer = c.sqlite3_column_text(self.handle, index);
        if (pointer == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return pointer[0..len];
    }

    pub fn dupeColumnText(self: *Statement, allocator: std.mem.Allocator, index: c_int) ![]u8 {
        return allocator.dupe(u8, self.columnText(index));
    }

    pub fn columnInt(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn columnFloat(self: *Statement, index: c_int) f64 {
        return c.sqlite3_column_double(self.handle, index);
    }

    pub fn columnIsNull(self: *Statement, index: c_int) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }
};
