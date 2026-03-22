const std = @import("std");
const store = @import("store.zig");

pub fn syncPush(allocator: std.mem.Allocator, s: *store.Store, owner: []const u8, number: []const u8) !void {
    const out = std.fs.File.stdout();

    const project_id = try getProjectId(allocator, owner, number);
    defer allocator.free(project_id);

    const field_info = try getStatusFieldInfo(allocator, owner, number);
    defer allocator.free(field_info.field_id);
    defer {
        for (field_info.options) |opt| {
            allocator.free(opt.id);
            allocator.free(opt.name);
        }
        allocator.free(field_info.options);
    }

    const existing = try listProjectItems(allocator, owner, number);
    defer {
        for (existing) |item| {
            allocator.free(item.id);
            allocator.free(item.title);
            allocator.free(item.status);
        }
        allocator.free(existing);
    }

    for (s.tasks.items) |task| {
        var found = false;
        for (existing) |item| {
            if (std.mem.eql(u8, item.title, task.title)) {
                found = true;
                const target = mapStatusToProject(task.status);
                if (!std.mem.eql(u8, item.status, target)) {
                    const opt_id = findOptionId(field_info.options, target);
                    if (opt_id) |oid| {
                        try setItemStatus(allocator, project_id, item.id, field_info.field_id, oid);
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "  Updated: {s} -> {s}\n", .{ task.title, target }) catch unreachable;
                        out.writeAll(msg) catch {};
                    }
                }
                break;
            }
        }

        if (!found) {
            const item_id = try createProjectItem(allocator, owner, number, task.title);
            defer allocator.free(item_id);

            const target = mapStatusToProject(task.status);
            const opt_id = findOptionId(field_info.options, target);
            if (opt_id) |oid| {
                try setItemStatus(allocator, project_id, item_id, field_info.field_id, oid);
            }

            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "  Created: {s} [{s}]\n", .{ task.title, target }) catch unreachable;
            out.writeAll(msg) catch {};
        }
    }

    out.writeAll("Sync push complete.\n") catch {};
}

pub fn syncPull(allocator: std.mem.Allocator, s: *store.Store, owner: []const u8, number: []const u8) !void {
    const out = std.fs.File.stdout();

    const items = try listProjectItems(allocator, owner, number);
    defer {
        for (items) |item| {
            allocator.free(item.id);
            allocator.free(item.title);
            allocator.free(item.status);
        }
        allocator.free(items);
    }

    for (s.tasks.items) |task| {
        allocator.free(task.title);
    }
    s.tasks.clearRetainingCapacity();

    for (items) |item| {
        const status = mapStatusFromProject(item.status);
        const title = try allocator.dupe(u8, item.title);
        try s.tasks.append(allocator, .{
            .id = s.nextId(),
            .status = status,
            .title = title,
        });
    }

    try s.save();

    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Pulled {d} items from project.\n", .{items.len}) catch unreachable;
    out.writeAll(msg) catch {};
}

fn mapStatusToProject(status: store.Status) []const u8 {
    return switch (status) {
        .todo => "Todo",
        .doing => "In Progress",
        .done => "Done",
    };
}

fn mapStatusFromProject(status: []const u8) store.Status {
    if (std.mem.eql(u8, status, "In Progress")) return .doing;
    if (std.mem.eql(u8, status, "Done")) return .done;
    return .todo;
}

const ProjectItem = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
};

const StatusOption = struct {
    id: []const u8,
    name: []const u8,
};

const FieldInfo = struct {
    field_id: []const u8,
    options: []StatusOption,
};

fn listProjectItems(allocator: std.mem.Allocator, owner: []const u8, number: []const u8) ![]ProjectItem {
    const args = [_][]const u8{ "project", "item-list", number, "--owner", owner, "--format", "json", "--limit", "100" };
    const result = try execGhCmd(allocator, &args);
    defer allocator.free(result);

    var items: std.ArrayList(ProjectItem) = .empty;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch return try items.toOwnedSlice(allocator);
    defer parsed.deinit();

    const root = parsed.value.object;
    const json_items = root.get("items") orelse return try items.toOwnedSlice(allocator);
    for (json_items.array.items) |item| {
        const obj = item.object;
        const id = obj.get("id") orelse continue;
        const title = obj.get("title") orelse continue;
        const status_val = obj.get("status");
        const status_str = if (status_val) |sv| switch (sv) {
            .string => |ss| ss,
            else => "",
        } else "";

        try items.append(allocator, .{
            .id = try allocator.dupe(u8, id.string),
            .title = try allocator.dupe(u8, title.string),
            .status = try allocator.dupe(u8, status_str),
        });
    }

    return try items.toOwnedSlice(allocator);
}

fn getProjectId(allocator: std.mem.Allocator, owner: []const u8, number: []const u8) ![]const u8 {
    const args = [_][]const u8{ "project", "view", number, "--owner", owner, "--format", "json" };
    const result = try execGhCmd(allocator, &args);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    const id = parsed.value.object.get("id") orelse return error.NoProjectId;
    return try allocator.dupe(u8, id.string);
}

fn getStatusFieldInfo(allocator: std.mem.Allocator, owner: []const u8, number: []const u8) !FieldInfo {
    const args = [_][]const u8{ "project", "field-list", number, "--owner", owner, "--format", "json" };
    const result = try execGhCmd(allocator, &args);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    const fields = parsed.value.object.get("fields") orelse return error.NoFields;
    for (fields.array.items) |field| {
        const obj = field.object;
        const name = obj.get("name") orelse continue;
        if (!std.mem.eql(u8, name.string, "Status")) continue;

        const field_id = obj.get("id") orelse continue;
        const options_val = obj.get("options") orelse continue;

        var options: std.ArrayList(StatusOption) = .empty;
        for (options_val.array.items) |opt| {
            const opt_obj = opt.object;
            const opt_id = opt_obj.get("id") orelse continue;
            const opt_name = opt_obj.get("name") orelse continue;
            try options.append(allocator, .{
                .id = try allocator.dupe(u8, opt_id.string),
                .name = try allocator.dupe(u8, opt_name.string),
            });
        }

        return .{
            .field_id = try allocator.dupe(u8, field_id.string),
            .options = try options.toOwnedSlice(allocator),
        };
    }
    return error.NoStatusField;
}

fn createProjectItem(allocator: std.mem.Allocator, owner: []const u8, number: []const u8, title: []const u8) ![]const u8 {
    const args = [_][]const u8{ "project", "item-create", number, "--owner", owner, "--title", title, "--format", "json" };
    const result = try execGhCmd(allocator, &args);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    const id = parsed.value.object.get("id") orelse return error.NoItemId;
    return try allocator.dupe(u8, id.string);
}

fn setItemStatus(allocator: std.mem.Allocator, project_id: []const u8, item_id: []const u8, field_id: []const u8, option_id: []const u8) !void {
    const args = [_][]const u8{ "project", "item-edit", "--project-id", project_id, "--id", item_id, "--field-id", field_id, "--single-select-option-id", option_id };
    const result = try execGhCmd(allocator, &args);
    allocator.free(result);
}

fn findOptionId(options: []const StatusOption, name: []const u8) ?[]const u8 {
    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, name)) return opt.id;
    }
    return null;
}

fn execGhCmd(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "gh");
    for (args) |arg| try argv.append(allocator, arg);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_data: std.ArrayList(u8) = .empty;
    errdefer stdout_data.deinit(allocator);

    const stdout_file = child.stdout.?;
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = stdout_file.read(&buf) catch break;
        if (n == 0) break;
        try stdout_data.appendSlice(allocator, buf[0..n]);
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                stdout_data.deinit(allocator);
                return error.GhCommandFailed;
            }
        },
        else => {
            stdout_data.deinit(allocator);
            return error.GhCommandFailed;
        },
    }

    return try stdout_data.toOwnedSlice(allocator);
}
