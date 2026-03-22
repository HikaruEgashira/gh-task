const std = @import("std");
const store = @import("store.zig");
const kanban = @import("kanban.zig");
const sync = @import("sync.zig");

const usage_text =
    \\Usage: gh task <command> [options]
    \\
    \\Kanban-based task manager. Tasks stored in TASKS.md.
    \\Columns are read from TASKS.md headers (## Section).
    \\
    \\Commands:
    \\  add <title> [-s status]      Add task (default: first column)
    \\  list, ls                     Show kanban board
    \\  view [column]                List tasks by column
    \\  move <id> <status>           Move task to column
    \\  rm <id>                      Remove a task
    \\  edit <id> <new-title>        Edit task title
    \\  columns                      List available columns
    \\  push <owner> <num>           Push to GitHub Project
    \\  pull <owner> <num>           Pull from GitHub Project
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

    if (args.len < 2) return runList(allocator, out);

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "add")) {
        return runAdd(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        return runList(allocator, out);
    } else if (std.mem.eql(u8, cmd, "view")) {
        return runView(allocator, args[2..], out);
    } else if (std.mem.eql(u8, cmd, "move")) {
        return runMove(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "edit")) {
        return runEdit(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "remove")) {
        return runRemove(allocator, args[2..], out, err);
    } else if (std.mem.eql(u8, cmd, "columns") or std.mem.eql(u8, cmd, "cols")) {
        return runColumns(allocator, out);
    } else if (std.mem.eql(u8, cmd, "push")) {
        return runPushPull(allocator, args[2..], err, true);
    } else if (std.mem.eql(u8, cmd, "pull")) {
        return runPushPull(allocator, args[2..], err, false);
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
    var status_arg: ?[]const u8 = null;
    var title_parts: std.ArrayList([]const u8) = .empty;
    defer title_parts.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((std.mem.eql(u8, args[i], "-s") or std.mem.eql(u8, args[i], "--status")) and i + 1 < args.len) {
            status_arg = args[i + 1];
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

    const status = if (status_arg) |sa|
        s.findColumn(sa) orelse {
            writeStr(err_file, "Unknown column: {s}\nAvailable: ", .{sa});
            for (s.columns.items, 0..) |col, ci| {
                if (ci > 0) err_file.writeAll(", ") catch {};
                err_file.writeAll(col) catch {};
            }
            err_file.writeAll("\n") catch {};
            std.process.exit(1);
        }
    else
        s.firstColumn();

    const id = try s.add(title, status);
    writeStr(out, "Created #{d}: {s} [{s}]\n", .{ id, title, status });
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

    // Join remaining args as status name (e.g. "In Progress")
    const status_query = std.mem.join(allocator, " ", args[1..]) catch {
        try err_file.writeAll("Out of memory\n");
        std.process.exit(1);
    };
    defer allocator.free(status_query);

    var s = try loadStore(allocator);
    defer s.deinit();

    const new_status = s.findColumn(status_query) orelse {
        writeStr(err_file, "Unknown column: {s}\nAvailable: ", .{status_query});
        for (s.columns.items, 0..) |col, ci| {
            if (ci > 0) err_file.writeAll(", ") catch {};
            err_file.writeAll(col) catch {};
        }
        err_file.writeAll("\n") catch {};
        std.process.exit(1);
    };

    s.updateStatus(id, new_status) catch {
        writeStr(err_file, "Task #{d} not found\n", .{id});
        std.process.exit(1);
    };

    writeStr(out, "Moved #{d} -> {s}\n", .{ id, new_status });
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

fn runView(allocator: std.mem.Allocator, args: []const []const u8, out: std.fs.File) !void {
    var s = try loadStore(allocator);
    defer s.deinit();

    const colors = [_][]const u8{ "\x1b[1;33m", "\x1b[1;36m", "\x1b[1;32m", "\x1b[1;35m", "\x1b[1;34m" };
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";

    const query = if (args.len > 0) std.mem.join(allocator, " ", args) catch null else null;
    defer if (query) |q| allocator.free(q);

    const filter: ?[]const u8 = if (query) |q| s.findColumn(q) else null;

    for (s.columns.items, 0..) |col, ci| {
        if (filter) |f| {
            if (!std.mem.eql(u8, col, f)) continue;
        }

        const count = s.countByStatus(col);
        const color = colors[ci % colors.len];
        writeStr(out, "\n{s}{s} ({d}){s}\n", .{ color, col, count, reset });

        var found = false;
        for (s.tasks.items) |task| {
            if (std.mem.eql(u8, task.status, col)) {
                writeStr(out, "  {s}#{d}{s} {s}\n", .{ dim, task.id, reset, task.title });
                found = true;
            }
        }
        if (!found) {
            writeStr(out, "  {s}(empty){s}\n", .{ dim, reset });
        }
    }
}

fn runColumns(allocator: std.mem.Allocator, out: std.fs.File) !void {
    var s = try loadStore(allocator);
    defer s.deinit();

    for (s.columns.items, 0..) |col, i| {
        const count = s.countByStatus(col);
        writeStr(out, "{d}. {s} ({d})\n", .{ i + 1, col, count });
    }
}

fn runPushPull(allocator: std.mem.Allocator, args: []const []const u8, err_file: std.fs.File, is_push: bool) !void {
    if (args.len < 2) {
        try err_file.writeAll("Usage: gh task push|pull <owner> <project-number>\n");
        std.process.exit(1);
    }

    const owner = args[0];
    const number = args[1];

    var s = try loadStore(allocator);
    defer s.deinit();

    if (is_push) {
        sync.push(allocator, &s, owner, number);
    } else {
        sync.pull(allocator, &s, owner, number);
    }
}
