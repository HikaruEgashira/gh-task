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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.fs.File.stdout();

    if (args.len < 2) return runList(allocator, stdout);

    const cmd = args[1];
    const rest = args[2..];

    const commands = .{
        .{ "add", runAdd },
        .{ "list", runList_ },
        .{ "ls", runList_ },
        .{ "view", runView },
        .{ "move", runMove },
        .{ "edit", runEdit },
        .{ "rm", runRemove },
        .{ "remove", runRemove },
        .{ "columns", runColumns },
        .{ "cols", runColumns },
        .{ "push", runSync },
        .{ "pull", runSync },
    };

    inline for (commands) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) {
            return entry[1](allocator, cmd, rest, stdout);
        }
    }

    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        return stdout.writeAll(usage_text);
    }

    die("Unknown command: {s}\n", .{cmd});
}

// --- commands ---

fn runList_(allocator: std.mem.Allocator, _: []const u8, _: []const []const u8, stdout: std.fs.File) !void {
    return runList(allocator, stdout);
}

fn runList(allocator: std.mem.Allocator, stdout: std.fs.File) !void {
    var s = try loadStore(allocator);
    defer s.deinit();
    try kanban.render(&s, stdout);
}

fn runAdd(allocator: std.mem.Allocator, _: []const u8, args: []const []const u8, stdout: std.fs.File) !void {
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

    if (title_parts.items.len == 0) die("Error: title is required\n", .{});

    const title = try std.mem.join(allocator, " ", title_parts.items);
    defer allocator.free(title);

    var s = try loadStore(allocator);
    defer s.deinit();

    const status = if (status_arg) |sa|
        s.findColumn(sa) orelse dieUnknownColumn(&s, sa)
    else
        s.firstColumn();

    const id = try s.add(title, status);
    print(stdout, "Created #{d}: {s} [{s}]\n", .{ id, title, status });
}

fn runMove(allocator: std.mem.Allocator, _: []const u8, args: []const []const u8, stdout: std.fs.File) !void {
    if (args.len < 2) die("Usage: gh task move <id> <status>\n", .{});

    const id = parseId(args[0]);
    const query = try std.mem.join(allocator, " ", args[1..]);
    defer allocator.free(query);

    var s = try loadStore(allocator);
    defer s.deinit();

    const new_status = s.findColumn(query) orelse dieUnknownColumn(&s, query);
    s.updateStatus(id, new_status) catch die("Task #{d} not found\n", .{id});
    print(stdout, "Moved #{d} -> {s}\n", .{ id, new_status });
}

fn runEdit(allocator: std.mem.Allocator, _: []const u8, args: []const []const u8, stdout: std.fs.File) !void {
    if (args.len < 2) die("Usage: gh task edit <id> <new-title>\n", .{});

    const id = parseId(args[0]);
    const title = try std.mem.join(allocator, " ", args[1..]);
    defer allocator.free(title);

    var s = try loadStore(allocator);
    defer s.deinit();

    s.updateTitle(id, title) catch die("Task #{d} not found\n", .{id});
    print(stdout, "Updated #{d}: {s}\n", .{ id, title });
}

fn runRemove(allocator: std.mem.Allocator, _: []const u8, args: []const []const u8, stdout: std.fs.File) !void {
    if (args.len == 0) die("Error: task id is required\n", .{});

    const id = parseId(args[0]);

    var s = try loadStore(allocator);
    defer s.deinit();

    const title = s.remove(id) catch die("Task #{d} not found\n", .{id});
    defer allocator.free(title);
    print(stdout, "Removed #{d}: {s}\n", .{ id, title });
}

fn runView(allocator: std.mem.Allocator, _: []const u8, args: []const []const u8, stdout: std.fs.File) !void {
    var s = try loadStore(allocator);
    defer s.deinit();

    const Color = kanban.Color;

    const query = if (args.len > 0) std.mem.join(allocator, " ", args) catch null else null;
    defer if (query) |q| allocator.free(q);
    const filter: ?[]const u8 = if (query) |q| s.findColumn(q) else null;

    for (s.columns.items, 0..) |col, ci| {
        if (filter) |f| {
            if (!std.mem.eql(u8, col, f)) continue;
        }

        const color = Color.palette[ci % Color.palette.len];
        print(stdout, "\n{s}{s} ({d}){s}\n", .{ color, col, s.countByStatus(col), Color.reset });

        var found = false;
        for (s.tasks.items) |task| {
            if (std.mem.eql(u8, task.status, col)) {
                print(stdout, "  {s}#{d}{s} {s}\n", .{ Color.dim, task.id, Color.reset, task.title });
                found = true;
            }
        }
        if (!found) print(stdout, "  {s}(empty){s}\n", .{ Color.dim, Color.reset });
    }
}

fn runColumns(allocator: std.mem.Allocator, _: []const u8, _: []const []const u8, stdout: std.fs.File) !void {
    var s = try loadStore(allocator);
    defer s.deinit();

    for (s.columns.items, 0..) |col, i| {
        print(stdout, "{d}. {s} ({d})\n", .{ i + 1, col, s.countByStatus(col) });
    }
}

fn runSync(allocator: std.mem.Allocator, cmd: []const u8, args: []const []const u8, _: std.fs.File) !void {
    if (args.len < 2) die("Usage: gh task push|pull <owner> <project-number>\n", .{});

    var s = try loadStore(allocator);
    defer s.deinit();

    if (std.mem.eql(u8, cmd, "push")) {
        sync.push(allocator, &s, args[0], args[1]);
    } else {
        sync.pull(allocator, &s, args[0], args[1]);
    }
}

// --- helpers ---

fn loadStore(allocator: std.mem.Allocator) !store.Store {
    var s = store.Store.init(allocator, "TASKS.md");
    try s.load();
    return s;
}

fn print(file: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    file.writeAll(msg) catch {};
}

fn parseId(arg: []const u8) u32 {
    return std.fmt.parseInt(u32, arg, 10) catch die("Invalid id: {s}\n", .{arg});
}

fn dieUnknownColumn(s: *const store.Store, query: []const u8) noreturn {
    const stderr = std.fs.File.stderr();
    print(stderr, "Unknown column: {s}\nAvailable: ", .{query});
    for (s.columns.items, 0..) |col, i| {
        if (i > 0) stderr.writeAll(", ") catch {};
        stderr.writeAll(col) catch {};
    }
    stderr.writeAll("\n") catch {};
    std.process.exit(1);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    print(std.fs.File.stderr(), fmt, args);
    std.process.exit(1);
}
