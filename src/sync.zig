const std = @import("std");
const store = @import("store.zig");

pub fn push(allocator: std.mem.Allocator, s: *store.Store, owner: []const u8, number: []const u8) void {
    const out = std.fs.File.stdout();

    const project_id = getProjectId(allocator, owner, number);
    defer allocator.free(project_id);

    const field_info = getStatusFieldInfo(allocator, owner, number);
    defer allocator.free(field_info.field_id);
    defer {
        for (field_info.options) |opt| {
            allocator.free(opt.id);
            allocator.free(opt.name);
        }
        allocator.free(field_info.options);
    }

    const existing = listProjectItems(allocator, owner, number);
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
                if (!std.mem.eql(u8, item.status, task.status)) {
                    if (findOptionId(field_info.options, task.status)) |oid| {
                        setItemStatus(allocator, project_id, item.id, field_info.field_id, oid);
                        writeMsg(out, "  Updated: {s} -> {s}\n", .{ task.title, task.status });
                    }
                }
                break;
            }
        }

        if (!found) {
            const item_id = createProjectItem(allocator, owner, number, task.title);
            defer allocator.free(item_id);

            if (findOptionId(field_info.options, task.status)) |oid| {
                setItemStatus(allocator, project_id, item_id, field_info.field_id, oid);
            }
            writeMsg(out, "  Created: {s} [{s}]\n", .{ task.title, task.status });
        }
    }

    out.writeAll("Push complete.\n") catch {};
}

pub fn pull(allocator: std.mem.Allocator, s: *store.Store, owner: []const u8, number: []const u8) void {
    const out = std.fs.File.stdout();

    // Get project columns to set up TASKS.md sections
    const field_info = getStatusFieldInfo(allocator, owner, number);
    defer allocator.free(field_info.field_id);
    defer {
        for (field_info.options) |opt| {
            allocator.free(opt.id);
            allocator.free(opt.name);
        }
        allocator.free(field_info.options);
    }

    const items = listProjectItems(allocator, owner, number);
    defer {
        for (items) |item| {
            allocator.free(item.id);
            allocator.free(item.title);
            allocator.free(item.status);
        }
        allocator.free(items);
    }

    // Clear existing
    for (s.tasks.items) |task| {
        allocator.free(task.title);
        allocator.free(task.status);
    }
    s.tasks.clearRetainingCapacity();

    for (s.columns.items) |col| allocator.free(col);
    s.columns.clearRetainingCapacity();

    // Set columns from project
    for (field_info.options) |opt| {
        s.columns.append(allocator, allocator.dupe(u8, opt.name) catch fatal("Out of memory")) catch fatal("Out of memory");
    }

    // Add tasks
    for (items) |item| {
        const status_str = if (item.status.len > 0) item.status else s.firstColumn();
        s.tasks.append(allocator, .{
            .id = s.nextId(),
            .status = allocator.dupe(u8, status_str) catch fatal("Out of memory"),
            .title = allocator.dupe(u8, item.title) catch fatal("Out of memory"),
            .checked = std.mem.eql(u8, status_str, s.columns.items[s.columns.items.len - 1]),
        }) catch fatal("Out of memory");
    }

    s.save() catch fatal("Failed to write TASKS.md");

    writeMsg(out, "Pulled {d} items ({d} columns) from project.\n", .{ items.len, field_info.options.len });
}

// --- helpers ---

fn writeMsg(file: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    file.writeAll(msg) catch {};
}

fn fatal(msg: []const u8) noreturn {
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}

const ProjectItem = struct { id: []const u8, title: []const u8, status: []const u8 };
const StatusOption = struct { id: []const u8, name: []const u8 };
const FieldInfo = struct { field_id: []const u8, options: []StatusOption };

fn listProjectItems(allocator: std.mem.Allocator, owner: []const u8, number: []const u8) []ProjectItem {
    const result = ghExec(allocator, &.{ "project", "item-list", number, "--owner", owner, "--format", "json", "--limit", "100" });
    defer allocator.free(result);

    var items: std.ArrayList(ProjectItem) = .empty;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch return items.toOwnedSlice(allocator) catch &.{};
    defer parsed.deinit();

    const json_items = parsed.value.object.get("items") orelse return items.toOwnedSlice(allocator) catch &.{};
    for (json_items.array.items) |item| {
        const obj = item.object;
        const id = obj.get("id") orelse continue;
        const title = obj.get("title") orelse continue;
        const status_val = obj.get("status");
        const status_str = if (status_val) |sv| switch (sv) {
            .string => |ss| ss,
            else => "",
        } else "";

        items.append(allocator, .{
            .id = allocator.dupe(u8, id.string) catch continue,
            .title = allocator.dupe(u8, title.string) catch continue,
            .status = allocator.dupe(u8, status_str) catch continue,
        }) catch continue;
    }

    return items.toOwnedSlice(allocator) catch &.{};
}

fn getProjectId(allocator: std.mem.Allocator, owner: []const u8, number: []const u8) []const u8 {
    const result = ghExec(allocator, &.{ "project", "view", number, "--owner", owner, "--format", "json" });
    defer allocator.free(result);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch fatal("Failed to parse project response");
    defer parsed.deinit();

    const id = parsed.value.object.get("id") orelse fatal("Project has no id field");
    return allocator.dupe(u8, id.string) catch fatal("Out of memory");
}

fn getStatusFieldInfo(allocator: std.mem.Allocator, owner: []const u8, number: []const u8) FieldInfo {
    const result = ghExec(allocator, &.{ "project", "field-list", number, "--owner", owner, "--format", "json" });
    defer allocator.free(result);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch fatal("Failed to parse field list response");
    defer parsed.deinit();

    const fields = parsed.value.object.get("fields") orelse fatal("No fields in project");
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
            options.append(allocator, .{
                .id = allocator.dupe(u8, opt_id.string) catch continue,
                .name = allocator.dupe(u8, opt_name.string) catch continue,
            }) catch continue;
        }

        return .{
            .field_id = allocator.dupe(u8, field_id.string) catch fatal("Out of memory"),
            .options = options.toOwnedSlice(allocator) catch fatal("Out of memory"),
        };
    }
    fatal("No Status field found in project");
}

fn createProjectItem(allocator: std.mem.Allocator, owner: []const u8, number: []const u8, title: []const u8) []const u8 {
    const result = ghExec(allocator, &.{ "project", "item-create", number, "--owner", owner, "--title", title, "--format", "json" });
    defer allocator.free(result);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch fatal("Failed to parse item-create response");
    defer parsed.deinit();

    const id = parsed.value.object.get("id") orelse fatal("Created item has no id");
    return allocator.dupe(u8, id.string) catch fatal("Out of memory");
}

fn setItemStatus(allocator: std.mem.Allocator, project_id: []const u8, item_id: []const u8, field_id: []const u8, option_id: []const u8) void {
    const result = ghExec(allocator, &.{ "project", "item-edit", "--project-id", project_id, "--id", item_id, "--field-id", field_id, "--single-select-option-id", option_id });
    allocator.free(result);
}

fn findOptionId(options: []const StatusOption, name: []const u8) ?[]const u8 {
    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, name)) return opt.id;
    }
    return null;
}

fn ghExec(allocator: std.mem.Allocator, args: []const []const u8) []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "gh") catch fatal("Out of memory");
    for (args) |arg| argv.append(allocator, arg) catch fatal("Out of memory");

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch fatal("Failed to spawn gh command");

    var stdout_data: std.ArrayList(u8) = .empty;
    const stdout_file = child.stdout.?;
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = stdout_file.read(&buf) catch break;
        if (n == 0) break;
        stdout_data.appendSlice(allocator, buf[0..n]) catch fatal("Out of memory");
    }

    const term = child.wait() catch fatal("Failed to wait for gh command");
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                stdout_data.deinit(allocator);
                fatal("gh command failed");
            }
        },
        else => {
            stdout_data.deinit(allocator);
            fatal("gh command terminated abnormally");
        },
    }

    return stdout_data.toOwnedSlice(allocator) catch fatal("Out of memory");
}
