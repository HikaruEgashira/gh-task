const std = @import("std");

pub const Task = struct {
    id: u32,
    status: Status,
    title: []const u8,
};

pub const Status = enum {
    todo,
    doing,
    done,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .todo => "TODO",
            .doing => "DOING",
            .done => "DONE",
        };
    }

    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "todo")) return .todo;
        if (std.mem.eql(u8, s, "doing")) return .doing;
        if (std.mem.eql(u8, s, "done")) return .done;
        return null;
    }
};

pub const Store = struct {
    tasks: std.ArrayList(Task),
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        return .{
            .tasks = .empty,
            .allocator = allocator,
            .path = path,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.tasks.items) |task| {
            self.allocator.free(task.title);
        }
        self.tasks.deinit(self.allocator);
    }

    pub fn load(self: *Store) !void {
        const file = std.fs.cwd().openFile(self.path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try self.save();
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var current_status: ?Status = null;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "## TODO")) {
                current_status = .todo;
            } else if (std.mem.startsWith(u8, line, "## DOING")) {
                current_status = .doing;
            } else if (std.mem.startsWith(u8, line, "## DONE")) {
                current_status = .done;
            } else if (current_status != null) {
                if (parseLine(line)) |parsed| {
                    const title = try self.allocator.dupe(u8, parsed.title);
                    try self.tasks.append(self.allocator, .{
                        .id = parsed.id,
                        .status = current_status.?,
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

        const statuses = [_]Status{ .todo, .doing, .done };
        for (statuses) |status| {
            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "## {s}\n\n", .{status.label()}) catch unreachable;
            try file.writeAll(label);

            for (self.tasks.items) |task| {
                if (task.status == status) {
                    const check: []const u8 = if (task.status == .done) "x" else " ";
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

    pub fn add(self: *Store, title: []const u8, status: Status) !u32 {
        const id = self.nextId();
        const owned_title = try self.allocator.dupe(u8, title);
        try self.tasks.append(self.allocator, .{ .id = id, .status = status, .title = owned_title });
        try self.save();
        return id;
    }

    pub fn findById(self: *const Store, id: u32) ?*const Task {
        for (self.tasks.items) |*task| {
            if (task.id == id) return task;
        }
        return null;
    }

    pub fn updateStatus(self: *Store, id: u32, new_status: Status) !void {
        for (self.tasks.items) |*task| {
            if (task.id == id) {
                task.status = new_status;
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
                _ = self.tasks.orderedRemove(i);
                try self.save();
                return title;
            }
        }
        return error.TaskNotFound;
    }

    pub fn countByStatus(self: *const Store, status: Status) usize {
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.status == status) count += 1;
        }
        return count;
    }
};

test "parse and save roundtrip" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator, "/tmp/test_tasks.md");
    defer s.deinit();

    _ = try s.add("Task one", .todo);
    _ = try s.add("Task two", .doing);
    _ = try s.add("Task three", .done);

    var s2 = Store.init(allocator, "/tmp/test_tasks.md");
    defer s2.deinit();
    try s2.load();

    try std.testing.expectEqual(@as(usize, 3), s2.tasks.items.len);
    try std.testing.expectEqualStrings("Task one", s2.tasks.items[0].title);
    try std.testing.expectEqual(Status.doing, s2.tasks.items[1].status);

    std.fs.cwd().deleteFile("/tmp/test_tasks.md") catch {};
}
