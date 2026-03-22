const std = @import("std");
const store = @import("store.zig");
const kanban = @import("kanban.zig");
const sync = @import("sync.zig");

const usage_text =
    \\Usage: gh task <command> [options]
    \\
    \\Kanban-based task manager. Tasks stored in TASKS.md.
    \\
    \\Commands:
    \\  add <title> [-s status]   Add a new task (default: todo)
    \\  list, ls                  Show kanban board
    \\  start <id>               Mark task as doing
    \\  done <id>                Mark task as done
    \\  move <id> <status>       Move task to column
    \\  edit <id> <new-title>    Edit task title
    \\  rm <id>                  Remove a task
    \\  sync push <owner> <num>  Push tasks to GitHub Project
    \\  sync pull <owner> <num>  Pull tasks from GitHub Project
    \\
    \\Statuses: todo, doing, done
    \\
;

fn writeStr(file: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    file.writeAll(msg) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const out = std.fs.File.stdout();
    const err = std.fs.File.stderr();

    if (args.len < 2) {
        return runList(allocator, out);
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "add")) {
        return runAdd(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        return runList(allocator, out);
    } else if (std.mem.eql(u8, cmd, "start")) {
        return runSetStatus(allocator, args[2..], .doing, out, err);
    } else if (std.mem.eql(u8, cmd, "done")) {
        return runSetStatus(allocator, args[2..], .done, out, err);
    } else if (std.mem.eql(u8, cmd, "move")) {
        return runMove(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "edit")) {
        return runEdit(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "remove")) {
        return runRemove(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "sync")) {
        return runSync(allocator, args[2..], err);
    } else if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try out.writeAll(usage_text);
    } else {
        writeStr(err, "Unknown command: {s}\n", .{cmd});
        try err.writeAll(usage_text);
        std.process.exit(1);
    }
}

fn loadStore(allocator: std.mem.Allocator) !store.Store {
    var s = store.Store.init(allocator, "TASKS.md");
    try s.load();
    return s;
}

fn runList(allocator: std.mem.Allocator, out: std.fs.File) !void {
    var s = try loadStore(allocator);
    defer s.deinit();
    try kanban.render(&s, out);
}

fn runAdd(allocator: std.mem.Allocator, args: []const []const u8, out: std.fs.File, err_file: std.fs.File) !void {
    var status: store.Status = .todo;
    var title_parts: std.ArrayList([]const u8) = .empty;
    defer title_parts.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((std.mem.eql(u8, args[i], "-s") or std.mem.eql(u8, args[i], "--status")) and i + 1 < args.len) {
            status = store.Status.fromString(args[i + 1]) orelse {
                writeStr(err_file, "Invalid status: {s}\n", .{args[i + 1]});
                std.process.exit(1);
            };
            i += 1;
        } else {
            try title_parts.append(allocator, args[i]);
        }
    }

    if (title_parts.items.len == 0) {
        try err_file.writeAll("Error: title is required\n");
        std.process.exit(1);
    }

    const title = try std.mem.join(allocator, " ", title_parts.items);
    defer allocator.free(title);

    var s = try loadStore(allocator);
    defer s.deinit();

    const id = try s.add(title, status);
    writeStr(out, "Created #{d}: {s} [{s}]\n", .{ id, title, status.label() });
}

fn runSetStatus(allocator: std.mem.Allocator, args: []const []const u8, new_status: store.Status, out: std.fs.File, err_file: std.fs.File) !void {
    if (args.len == 0) {
        try err_file.writeAll("Error: task id is required\n");
        std.process.exit(1);
    }

    const id = std.fmt.parseInt(u32, args[0], 10) catch {
        writeStr(err_file, "Invalid id: {s}\n", .{args[0]});
        std.process.exit(1);
    };

    var s = try loadStore(allocator);
    defer s.deinit();

    const task = s.findById(id) orelse {
        writeStr(err_file, "Task #{d} not found\n", .{id});
        std.process.exit(1);
    };

    const title_copy = try allocator.dupe(u8, task.title);
    defer allocator.free(title_copy);

    try s.updateStatus(id, new_status);
    const verb: []const u8 = if (new_status == .done) "Done" else "Started";
    writeStr(out, "{s} #{d}: {s}\n", .{ verb, id, title_copy });
}

fn runMove(allocator: std.mem.Allocator, args: []const []const u8, out: std.fs.File, err_file: std.fs.File) !void {
    if (args.len < 2) {
        try err_file.writeAll("Usage: gh task move <id> <status>\n");
        std.process.exit(1);
    }

    const id = std.fmt.parseInt(u32, args[0], 10) catch {
        writeStr(err_file, "Invalid id: {s}\n", .{args[0]});
        std.process.exit(1);
    };

    const new_status = store.Status.fromString(args[1]) orelse {
        writeStr(err_file, "Invalid status: {s}\n", .{args[1]});
        std.process.exit(1);
    };

    var s = try loadStore(allocator);
    defer s.deinit();

    s.updateStatus(id, new_status) catch {
        writeStr(err_file, "Task #{d} not found\n", .{id});
        std.process.exit(1);
    };

    writeStr(out, "Moved #{d} -> {s}\n", .{ id, new_status.label() });
}

fn runEdit(allocator: std.mem.Allocator, args: []const []const u8, out: std.fs.File, err_file: std.fs.File) !void {
    if (args.len < 2) {
        try err_file.writeAll("Usage: gh task edit <id> <new-title>\n");
        std.process.exit(1);
    }

    const id = std.fmt.parseInt(u32, args[0], 10) catch {
        writeStr(err_file, "Invalid id: {s}\n", .{args[0]});
        std.process.exit(1);
    };

    const title = try std.mem.join(allocator, " ", args[1..]);
    defer allocator.free(title);

    var s = try loadStore(allocator);
    defer s.deinit();

    s.updateTitle(id, title) catch {
        writeStr(err_file, "Task #{d} not found\n", .{id});
        std.process.exit(1);
    };

    writeStr(out, "Updated #{d}: {s}\n", .{ id, title });
}

fn runSync(allocator: std.mem.Allocator, args: []const []const u8, err_file: std.fs.File) !void {
    if (args.len < 3) {
        try err_file.writeAll("Usage: gh task sync <push|pull> <owner> <project-number>\n");
        std.process.exit(1);
    }

    const direction = args[0];
    const owner = args[1];
    const number = args[2];

    var s = try loadStore(allocator);
    defer s.deinit();

    if (std.mem.eql(u8, direction, "push")) {
        sync.syncPush(allocator, &s, owner, number);
    } else if (std.mem.eql(u8, direction, "pull")) {
        sync.syncPull(allocator, &s, owner, number);
    } else {
        try err_file.writeAll("Usage: gh task sync <push|pull> <owner> <project-number>\n");
        std.process.exit(1);
    }
}

fn runRemove(allocator: std.mem.Allocator, args: []const []const u8, out: std.fs.File, err_file: std.fs.File) !void {
    if (args.len == 0) {
        try err_file.writeAll("Error: task id is required\n");
        std.process.exit(1);
    }

    const id = std.fmt.parseInt(u32, args[0], 10) catch {
        writeStr(err_file, "Invalid id: {s}\n", .{args[0]});
        std.process.exit(1);
    };

    var s = try loadStore(allocator);
    defer s.deinit();

    const title = s.remove(id) catch {
        writeStr(err_file, "Task #{d} not found\n", .{id});
        std.process.exit(1);
    };
    defer allocator.free(title);

    writeStr(out, "Removed #{d}: {s}\n", .{ id, title });
}
