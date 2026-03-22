const std = @import("std");

pub const Task = struct {
    id: u32,
    status: []const u8, // dynamic: "Todo", "In Progress", "Done", etc.
    title: []const u8,
};

/// Default columns when creating a new TASKS.md
pub const default_columns = [_][]const u8{ "Todo", "In Progress", "Done" };

pub const Store = struct {
    tasks: std.ArrayList(Task),
    /// Ordered list of column names, read from TASKS.md headers
    columns: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        return .{
            .tasks = .empty,
            .columns = .empty,
            .allocator = allocator,
            .path = path,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.tasks.items) |task| {
            self.allocator.free(task.title);
            self.allocator.free(task.status);
        }
        self.tasks.deinit(self.allocator);
        for (self.columns.items) |col| {
            self.allocator.free(col);
        }
        self.columns.deinit(self.allocator);
    }

    pub fn load(self: *Store) !void {
        const file = std.fs.cwd().openFile(self.path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                for (default_columns) |col| {
                    try self.columns.append(self.allocator, try self.allocator.dupe(u8, col));
                }
                try self.save();
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var current_status: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "## ")) {
                const col_name = std.mem.trimRight(u8, line[3..], " \r");
                if (col_name.len > 0) {
                    const owned = try self.allocator.dupe(u8, col_name);
                    try self.columns.append(self.allocator, owned);
                    current_status = owned;
                }
            } else if (current_status) |status| {
                if (parseLine(line)) |parsed| {
                    const title = try self.allocator.dupe(u8, parsed.title);
                    const status_owned = try self.allocator.dupe(u8, status);
                    try self.tasks.append(self.allocator, .{
                        .id = parsed.id,
                        .status = status_owned,
                        .title = title,
                    });
                }
            }
        }
    }

    const ParsedLine = struct { id: u32, title: []const u8 };

    fn parseLine(line: []const u8) ?ParsedLine {
        const prefix_unchecked = "- [ ] ";
        const prefix_checked = "- [x] ";
        var rest: []const u8 = undefined;

        if (std.mem.startsWith(u8, line, prefix_unchecked)) {
            rest = line[prefix_unchecked.len..];
        } else if (std.mem.startsWith(u8, line, prefix_checked)) {
            rest = line[prefix_checked.len..];
        } else {
            return null;
        }

        const marker = "<!-- id:";
        const end_marker = " -->";
        const marker_pos = std.mem.indexOf(u8, rest, marker) orelse return null;
        const id_start = marker_pos + marker.len;
        const id_end = std.mem.indexOfPos(u8, rest, id_start, end_marker) orelse return null;

        const id_str = rest[id_start..id_end];
        const id = std.fmt.parseInt(u32, id_str, 10) catch return null;

        var title = rest[0..marker_pos];
        title = std.mem.trimRight(u8, title, " ");

        return .{ .id = id, .title = title };
    }

    pub fn save(self: *Store) !void {
        const file = try std.fs.cwd().createFile(self.path, .{});
        defer file.close();

        try file.writeAll("# Tasks\n\n");

        for (self.columns.items) |col| {
            var hdr_buf: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "## {s}\n\n", .{col}) catch unreachable;
            try file.writeAll(hdr);

            for (self.tasks.items) |task| {
                if (std.mem.eql(u8, task.status, col)) {
                    const check: []const u8 = if (isLastColumn(self, col)) "x" else " ";
                    var buf: [1024]u8 = undefined;
                    const line = std.fmt.bufPrint(&buf, "- [{s}] {s} <!-- id:{d} -->\n", .{ check, task.title, task.id }) catch unreachable;
                    try file.writeAll(line);
                }
            }
            try file.writeAll("\n");
        }
    }

    fn isLastColumn(self: *const Store, col: []const u8) bool {
        if (self.columns.items.len == 0) return false;
        return std.mem.eql(u8, self.columns.items[self.columns.items.len - 1], col);
    }

    pub fn nextId(self: *const Store) u32 {
        var max: u32 = 0;
        for (self.tasks.items) |task| {
            if (task.id > max) max = task.id;
        }
        return max + 1;
    }

    pub fn add(self: *Store, title: []const u8, status: []const u8) !u32 {
        const id = self.nextId();
        const owned_title = try self.allocator.dupe(u8, title);
        const owned_status = try self.allocator.dupe(u8, status);
        try self.tasks.append(self.allocator, .{ .id = id, .status = owned_status, .title = owned_title });
        try self.save();
        return id;
    }

    pub fn findById(self: *const Store, id: u32) ?*const Task {
        for (self.tasks.items) |*task| {
            if (task.id == id) return task;
        }
        return null;
    }

    pub fn updateStatus(self: *Store, id: u32, new_status: []const u8) !void {
        for (self.tasks.items) |*task| {
            if (task.id == id) {
                self.allocator.free(task.status);
                task.status = try self.allocator.dupe(u8, new_status);
                try self.save();
                return;
            }
        }
        return error.TaskNotFound;
    }

    pub fn updateTitle(self: *Store, id: u32, new_title: []const u8) !void {
        for (self.tasks.items) |*task| {
            if (task.id == id) {
                self.allocator.free(task.title);
                task.title = try self.allocator.dupe(u8, new_title);
                try self.save();
                return;
            }
        }
        return error.TaskNotFound;
    }

    pub fn remove(self: *Store, id: u32) ![]const u8 {
        for (self.tasks.items, 0..) |task, i| {
            if (task.id == id) {
                const title = task.title;
                self.allocator.free(task.status);
                _ = self.tasks.orderedRemove(i);
                try self.save();
                return title;
            }
        }
        return error.TaskNotFound;
    }

    pub fn countByStatus(self: *const Store, status: []const u8) usize {
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (std.mem.eql(u8, task.status, status)) count += 1;
        }
        return count;
    }

    /// First column name (default status for new tasks)
    pub fn firstColumn(self: *const Store) []const u8 {
        if (self.columns.items.len > 0) return self.columns.items[0];
        return "Todo";
    }

    /// Find column by case-insensitive prefix match
    pub fn findColumn(self: *const Store, query: []const u8) ?[]const u8 {
        // Exact match first
        for (self.columns.items) |col| {
            if (std.mem.eql(u8, col, query)) return col;
        }
        // Case-insensitive match
        for (self.columns.items) |col| {
            if (eqlIgnoreCase(col, query)) return col;
        }
        return null;
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "parse and save roundtrip" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator, "/tmp/test_tasks.md");
    defer s.deinit();

    // Set up columns
    for (default_columns) |col| {
        try s.columns.append(allocator, try allocator.dupe(u8, col));
    }

    _ = try s.add("Task one", "Todo");
    _ = try s.add("Task two", "In Progress");
    _ = try s.add("Task three", "Done");

    var s2 = Store.init(allocator, "/tmp/test_tasks.md");
    defer s2.deinit();
    try s2.load();

    try std.testing.expectEqual(@as(usize, 3), s2.tasks.items.len);
    try std.testing.expectEqualStrings("Task one", s2.tasks.items[0].title);
    try std.testing.expectEqualStrings("In Progress", s2.tasks.items[1].status);
    try std.testing.expectEqual(@as(usize, 3), s2.columns.items.len);

    std.fs.cwd().deleteFile("/tmp/test_tasks.md") catch {};
}
