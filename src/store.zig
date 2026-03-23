const std = @import("std");

pub const Task = struct {
    id: u32,
    status: []const u8, // dynamic: "Todo", "In Progress", "Done", etc.
    title: []const u8,
    checked: bool,
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
                        .id = parsed.id orelse 0,
                        .status = status_owned,
                        .title = title,
                        .checked = parsed.checked,
                    });
                }
            }
        }

        try self.normalizeTaskIds();
    }

    const ParsedLine = struct {
        id: ?u32,
        title: []const u8,
        checked: bool,
    };

    fn parseLine(line: []const u8) ?ParsedLine {
        const prefix_unchecked = "- [ ] ";
        const prefix_checked = "- [x] ";
        var rest: []const u8 = undefined;
        var checked = false;

        if (std.mem.startsWith(u8, line, prefix_unchecked)) {
            rest = line[prefix_unchecked.len..];
        } else if (std.mem.startsWith(u8, line, prefix_checked)) {
            rest = line[prefix_checked.len..];
            checked = true;
        } else {
            return null;
        }

        const marker = "<!-- id:";
        const end_marker = " -->";
        var id: ?u32 = null;
        var title = std.mem.trimRight(u8, rest, " \r");

        if (std.mem.indexOf(u8, rest, marker)) |marker_pos| {
            const id_start = marker_pos + marker.len;
            const id_end = std.mem.indexOfPos(u8, rest, id_start, end_marker) orelse return null;
            const id_str = rest[id_start..id_end];
            id = std.fmt.parseInt(u32, id_str, 10) catch return null;
            title = std.mem.trimRight(u8, rest[0..marker_pos], " ");
        }

        return .{ .id = id, .title = title, .checked = checked };
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
                    const check: []const u8 = if (task.checked) "x" else " ";
                    var buf: [1024]u8 = undefined;
                    const line = std.fmt.bufPrint(&buf, "- [{s}] {s} <!-- id:{d} -->\n", .{ check, task.title, task.id }) catch unreachable;
                    try file.writeAll(line);
                }
            }
            try file.writeAll("\n");
        }
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
        try self.tasks.append(self.allocator, .{
            .id = id,
            .status = owned_status,
            .title = owned_title,
            .checked = self.shouldCheckForStatus(status),
        });
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
                task.checked = self.shouldCheckForStatus(new_status);
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

    fn normalizeTaskIds(self: *Store) !void {
        var seen = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen.deinit();

        for (self.tasks.items) |*task| {
            if (task.id == 0) continue;
            const entry = try seen.getOrPut(task.id);
            if (entry.found_existing) {
                task.id = 0;
            }
        }

        var next_id: u32 = 1;
        for (self.tasks.items) |*task| {
            if (task.id != 0) continue;
            while (seen.contains(next_id)) : (next_id += 1) {}
            task.id = next_id;
            try seen.put(next_id, {});
            next_id += 1;
        }
    }

    fn shouldCheckForStatus(self: *const Store, status: []const u8) bool {
        if (self.columns.items.len == 0) return false;
        return std.mem.eql(u8, self.columns.items[self.columns.items.len - 1], status);
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
    const path = ".tmp/test_tasks.md";
    var s = Store.init(allocator, path);
    defer s.deinit();

    // Set up columns
    for (default_columns) |col| {
        try s.columns.append(allocator, try allocator.dupe(u8, col));
    }

    _ = try s.add("Task one", "Todo");
    _ = try s.add("Task two", "In Progress");
    _ = try s.add("Task three", "Done");

    var s2 = Store.init(allocator, path);
    defer s2.deinit();
    try s2.load();

    try std.testing.expectEqual(@as(usize, 3), s2.tasks.items.len);
    try std.testing.expectEqualStrings("Task one", s2.tasks.items[0].title);
    try std.testing.expectEqualStrings("In Progress", s2.tasks.items[1].status);
    try std.testing.expectEqual(@as(usize, 3), s2.columns.items.len);
    try std.testing.expect(s2.tasks.items[2].checked);

    std.fs.cwd().deleteFile(path) catch {};
}

test "load tasks without explicit ids and preserve checkbox state" {
    const allocator = std.testing.allocator;
    const path = ".tmp/test_tasks_without_ids.md";

    {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\# Tasks
            \\
            \\## Active
            \\- [ ] **Task A**
            \\- [ ] **Task B** <!-- id:9 -->
            \\
            \\## Done
            \\- [x] **Task C** - completed 2026-03-23
            \\- [ ] **Task D**
            \\
        );
    }

    var s = Store.init(allocator, path);
    defer s.deinit();
    try s.load();

    try std.testing.expectEqual(@as(usize, 4), s.tasks.items.len);
    try std.testing.expectEqual(@as(u32, 1), s.tasks.items[0].id);
    try std.testing.expectEqual(@as(u32, 9), s.tasks.items[1].id);
    try std.testing.expectEqual(@as(u32, 2), s.tasks.items[2].id);
    try std.testing.expect(s.tasks.items[2].checked);
    try std.testing.expect(!s.tasks.items[3].checked);

    try s.save();

    var s2 = Store.init(allocator, path);
    defer s2.deinit();
    try s2.load();

    try std.testing.expectEqual(@as(usize, 4), s2.tasks.items.len);
    try std.testing.expectEqual(@as(u32, 1), s2.tasks.items[0].id);
    try std.testing.expectEqual(@as(u32, 9), s2.tasks.items[1].id);
    try std.testing.expect(s2.tasks.items[2].checked);
    try std.testing.expect(!s2.tasks.items[3].checked);

    std.fs.cwd().deleteFile(path) catch {};
}
