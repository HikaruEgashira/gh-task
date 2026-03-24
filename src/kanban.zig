const std = @import("std");
const store = @import("store.zig");

pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const dim = "\x1b[2m";
    pub const palette = [_][]const u8{
        "\x1b[1;33m", "\x1b[1;36m", "\x1b[1;32m", "\x1b[1;35m", "\x1b[1;34m",
    };
};

fn getTermWidth() u16 {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0) return ws.col;
    return 80;
}

const Entry = struct { id: u32, title: []const u8 };

pub fn render(s: *const store.Store, file: std.fs.File) !void {
    const ncols = s.columns.items.len;
    if (ncols == 0) return file.writeAll("No columns defined.\n");

    const term_width: usize = getTermWidth();
    const col_width = (term_width -| (ncols - 1)) / ncols;
    const inner = if (col_width > 3) col_width - 2 else 1;

    var wbuf: [8192]u8 = undefined;
    var fw = file.writer(&wbuf);
    const w = &fw.interface;

    // Header
    for (s.columns.items, 0..) |col, i| {
        const count = s.countByStatus(col);
        const color = Color.palette[i % Color.palette.len];
        try w.print(" {s}{s} ({d}){s}", .{ color, col, count, Color.reset });
        const label_len = col.len + 3 + countDigits(count);
        try writeRepeat(w, ' ', inner -| label_len);
        if (i < ncols - 1) try w.writeAll("\xe2\x94\x82");
    }
    try w.writeByte('\n');

    // Separator
    for (0..ncols) |i| {
        try w.writeByte(' ');
        for (0..inner) |_| try w.writeAll("\xe2\x94\x80");
        if (i < ncols - 1) try w.writeAll("\xe2\x94\xbc");
    }
    try w.writeByte('\n');

    // Collect tasks per column
    const allocator = s.allocator;
    var col_tasks = try allocator.alloc(std.ArrayList(Entry), ncols);
    defer allocator.free(col_tasks);
    for (col_tasks) |*ct| ct.* = .empty;
    defer for (col_tasks) |*ct| ct.deinit(allocator);

    for (s.tasks.items) |task| {
        for (s.columns.items, 0..) |col, ci| {
            if (std.mem.eql(u8, task.status, col)) {
                try col_tasks[ci].append(allocator, .{ .id = task.id, .title = task.title });
                break;
            }
        }
    }

    var max_rows: usize = 0;
    for (col_tasks) |ct| max_rows = @max(max_rows, ct.items.len);

    if (max_rows == 0) {
        try w.print(" {s}(no tasks){s}\n", .{ Color.dim, Color.reset });
        try w.flush();
        return;
    }

    // Rows
    for (0..max_rows) |row| {
        for (col_tasks, 0..) |ct, ci| {
            if (row < ct.items.len) {
                const entry = ct.items[row];
                const id_len = countDigits(entry.id);
                const prefix_len = 1 + id_len + 1;
                const max_title = if (inner > prefix_len + 1) inner - prefix_len - 1 else 0;
                const title = if (entry.title.len > max_title and max_title > 0)
                    entry.title[0..max_title]
                else
                    entry.title;

                try w.print(" {s}#{d}{s} {s}", .{ Color.dim, entry.id, Color.reset, title });
                const used = prefix_len + title.len;
                try writeRepeat(w, ' ', inner -| used);
            } else {
                try writeRepeat(w, ' ', inner + 1);
            }
            if (ci < ncols - 1) try w.writeAll("\xe2\x94\x82");
        }
        try w.writeByte('\n');
    }

    try w.flush();
}

fn countDigits(n: anytype) usize {
    if (n == 0) return 1;
    var v = n;
    var d: usize = 0;
    while (v > 0) : (d += 1) v /= 10;
    return d;
}

fn writeRepeat(w: *std.Io.Writer, byte: u8, n: usize) !void {
    const buf = [_]u8{byte} ** 64;
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        try w.writeAll(buf[0..chunk]);
        remaining -= chunk;
    }
}
