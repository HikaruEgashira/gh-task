const std = @import("std");
const store = @import("store.zig");

const Color = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    // Cycle through colors for N columns
    const palette = [_][]const u8{
        "\x1b[1;33m", // yellow
        "\x1b[1;36m", // cyan
        "\x1b[1;32m", // green
        "\x1b[1;35m", // magenta
        "\x1b[1;34m", // blue
    };
};

fn getTermWidth() u16 {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0) return ws.col;
    return 80;
}

const TaskEntry = struct { id: u32, title: []const u8 };

pub fn render(s: *const store.Store, file: std.fs.File) !void {
    const ncols = s.columns.items.len;
    if (ncols == 0) {
        file.writeAll("No columns defined.\n") catch {};
        return;
    }

    const term_width: usize = getTermWidth();
    const col_width = if (ncols > 0) (term_width -| (ncols - 1)) / ncols else term_width;
    const inner = if (col_width > 3) col_width - 2 else 1;

    // Header
    for (s.columns.items, 0..) |col, i| {
        const count = s.countByStatus(col);
        const color = Color.palette[i % Color.palette.len];
        var buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&buf, " {s}{s} ({d}){s}", .{ color, col, count, Color.reset }) catch unreachable;
        file.writeAll(hdr) catch {};
        const label_len = col.len + 3 + countDigits(count);
        if (inner > label_len) writeSpaces(file, inner - label_len);
        if (i < ncols - 1) file.writeAll("\xe2\x94\x82") catch {}; // │
    }
    file.writeAll("\n") catch {};

    // Separator
    for (0..ncols) |i| {
        file.writeAll(" ") catch {};
        for (0..inner) |_| file.writeAll("\xe2\x94\x80") catch {}; // ─
        if (i < ncols - 1) file.writeAll("\xe2\x94\xbc") catch {}; // ┼
    }
    file.writeAll("\n") catch {};

    // Collect tasks per column
    const allocator = s.allocator;
    var col_tasks = allocator.alloc(std.ArrayList(TaskEntry), ncols) catch return;
    defer allocator.free(col_tasks);
    for (col_tasks) |*ct| ct.* = .empty;
    defer for (col_tasks) |*ct| ct.deinit(allocator);

    for (s.tasks.items) |task| {
        for (s.columns.items, 0..) |col, ci| {
            if (std.mem.eql(u8, task.status, col)) {
                col_tasks[ci].append(allocator, .{ .id = task.id, .title = task.title }) catch {};
                break;
            }
        }
    }

    var max_rows: usize = 0;
    for (col_tasks) |ct| {
        if (ct.items.len > max_rows) max_rows = ct.items.len;
    }

    if (max_rows == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, " {s}(no tasks){s}\n", .{ Color.dim, Color.reset }) catch unreachable;
        file.writeAll(msg) catch {};
        return;
    }

    for (0..max_rows) |row| {
        for (col_tasks, 0..) |ct, ci| {
            if (row < ct.items.len) {
                const entry = ct.items[row];
                const id_len = countDigits(entry.id);
                const prefix_len = 1 + id_len + 1;
                const max_title: usize = if (inner > prefix_len + 1) inner - prefix_len - 1 else 0;
                const display_title = if (entry.title.len > max_title and max_title > 0)
                    entry.title[0..max_title]
                else
                    entry.title;

                var buf: [1024]u8 = undefined;
                const cell = std.fmt.bufPrint(&buf, " {s}#{d}{s} {s}", .{ Color.dim, entry.id, Color.reset, display_title }) catch unreachable;
                file.writeAll(cell) catch {};
                const used = prefix_len + display_title.len;
                if (inner > used) writeSpaces(file, inner - used);
            } else {
                writeSpaces(file, inner + 1);
            }
            if (ci < ncols - 1) file.writeAll("\xe2\x94\x82") catch {}; // │
        }
        file.writeAll("\n") catch {};
    }
}

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

fn writeSpaces(file: std.fs.File, n: usize) void {
    const spaces = "                                                                                ";
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        file.writeAll(spaces[0..chunk]) catch {};
        remaining -= chunk;
    }
}
