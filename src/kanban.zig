const std = @import("std");
const store = @import("store.zig");

const Color = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const yellow = "\x1b[1;33m";
    const cyan = "\x1b[1;36m";
    const green = "\x1b[1;32m";
};

fn getTermWidth() u16 {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0) return ws.col;
    return 80;
}

pub fn render(s: *const store.Store, file: std.fs.File) !void {
    const term_width: usize = getTermWidth();
    const col_width = (term_width - 2) / 3;
    const inner = col_width - 3;

    const statuses = [_]store.Status{ .todo, .doing, .done };
    const labels = [_][]const u8{ "TODO", "DOING", "DONE" };
    const colors = [_][]const u8{ Color.yellow, Color.cyan, Color.green };

    // Header
    var hdr_buf: [1024]u8 = undefined;
    for (statuses, 0..) |status, i| {
        const count = s.countByStatus(status);
        const hdr = std.fmt.bufPrint(&hdr_buf, " {s}{s} ({d}){s}", .{ colors[i], labels[i], count, Color.reset }) catch unreachable;
        try file.writeAll(hdr);
        const label_len = labels[i].len + 3 + countDigits(count);
        if (inner > label_len) {
            try writeSpaces(file, inner - label_len);
        }
        if (i < 2) try file.writeAll("\xe2\x94\x82"); // │
    }
    try file.writeAll("\n");

    // Separator
    for (0..3) |i| {
        try file.writeAll(" ");
        for (0..inner) |_| try file.writeAll("\xe2\x94\x80"); // ─
        if (i < 2) try file.writeAll("\xe2\x94\xbc"); // ┼
    }
    try file.writeAll("\n");

    // Collect per column
    const allocator = s.allocator;
    var todo: std.ArrayList(TaskEntry) = .empty;
    defer todo.deinit(allocator);
    var doing: std.ArrayList(TaskEntry) = .empty;
    defer doing.deinit(allocator);
    var done: std.ArrayList(TaskEntry) = .empty;
    defer done.deinit(allocator);

    for (s.tasks.items) |task| {
        const list = switch (task.status) {
            .todo => &todo,
            .doing => &doing,
            .done => &done,
        };
        try list.append(allocator, .{ .id = task.id, .title = task.title });
    }

    const max_rows = @max(todo.items.len, @max(doing.items.len, done.items.len));
    if (max_rows == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, " {s}(no tasks){s}\n", .{ Color.dim, Color.reset }) catch unreachable;
        try file.writeAll(msg);
        return;
    }

    const columns = [_]*const std.ArrayList(TaskEntry){ &todo, &doing, &done };

    for (0..max_rows) |row| {
        for (columns, 0..) |col, i| {
            if (row < col.items.len) {
                const entry = col.items[row];
                const id_len = countDigits(entry.id);
                const prefix_len = 1 + id_len + 1; // "#N "
                const max_title: usize = if (inner > prefix_len + 1) inner - prefix_len - 1 else 0;
                const display_title = if (entry.title.len > max_title and max_title > 0)
                    entry.title[0..max_title]
                else
                    entry.title;

                var buf: [1024]u8 = undefined;
                const cell = std.fmt.bufPrint(&buf, " {s}#{d}{s} {s}", .{ Color.dim, entry.id, Color.reset, display_title }) catch unreachable;
                try file.writeAll(cell);
                const used = prefix_len + display_title.len;
                if (inner > used) {
                    try writeSpaces(file, inner - used);
                }
            } else {
                try writeSpaces(file, inner + 1);
            }
            if (i < 2) try file.writeAll("\xe2\x94\x82"); // │
        }
        try file.writeAll("\n");
    }
}

const TaskEntry = struct {
    id: u32,
    title: []const u8,
};

fn countDigits(n: anytype) usize {
    if (n == 0) return 1;
    var v = n;
    var d: usize = 0;
    while (v > 0) {
        v /= 10;
        d += 1;
    }
    return d;
}

fn writeSpaces(file: std.fs.File, n: usize) !void {
    const spaces = "                                                                                ";
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try file.writeAll(spaces[0..chunk]);
        remaining -= chunk;
    }
}
