const std = @import("std");
const List = @import("linked_list.zig").SinglyLinkedList(*Node);
const MemoryPool = std.heap.MemoryPool;
const Topic = @import("../mqtt.zig").Topic;

const Node = struct {
    chr: u8,
    children: List = undefined,
    data: ?*Topic = null,

    pub fn deinit(self: *Node, pool: *MemoryPool(Node)) void {
        if (self.children.len == 0) {
            self.children.deinit();
            pool.destroy(self);
            return;
        }

        var cur = self.children.list.first;
        while (cur) |current_node| {
            current_node.data.deinit(pool);
            cur = current_node.next;
        }

        self.children.deinit();
        pool.destroy(self);
    }
};

root: *Node,
size: usize,
pool: MemoryPool(Node),
allocator: std.mem.Allocator,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !*Self {
    const trie = try allocator.create(Self);
    trie.* = .{
        .root = undefined,
        .size = 0,
        .pool = MemoryPool(Node).init(allocator),
        .allocator = allocator,
    };

    trie.root = try trie.createNode(' ');

    return trie;
}

pub fn deinit(self: *Self) void {
    self.root.deinit(&self.pool);
    self.pool.deinit();
    self.allocator.destroy(self);
}

fn linearSearch(list: *const List, value: u8) ?*List.ListType.Node {
    if (list.len == 0) return null;

    var cur = list.list.first;
    while (cur) |current_node| {
        if (current_node.data.chr == value) {
            return current_node;
        } else if (current_node.data.chr > value) return null;

        cur = current_node.next;
    }

    return null;
}

fn withChar(arg1: *Node, arg2: *Node) isize {
    if (arg1.chr == arg2.chr) return 0;
    return 1;
}

pub fn createNode(self: *Self, chr: u8) !*Node {
    const node = try self.pool.create();
    node.* = .{
        .chr = chr,
        .children = List.init(self.allocator),
        .data = null,
    };

    return node;
}

pub fn find(node: *const Node, prefix: []const u8) ?*Node {
    var return_node: *const Node = node;

    for (prefix) |char| {
        if (linearSearch(&return_node.children, char)) |child| {
            return_node = child.data;
        } else {
            return null;
        }
    }

    return @constCast(return_node);
}

pub fn prefixDelete(self: *Self, prefix: []const u8) void {

    var cursor = find(self.root, prefix);
    if (cursor == null) return;

    if (cursor.?.children.len == 0) {
        _ = self.delete(prefix);
        return;
    }

    var cur = cursor.?.children.list.first;
    while (cur) |c| {
        cur = c.next;
        self.deinitNode(c.data);
        cursor.?.children.remove(c.data, withChar);
    }

    _ = self.delete(prefix);
}

pub fn deinitNode(self: *Self, node: *Node) void {

    var cur = node.children.list.first;
    while (cur) |n| {
        self.deinitNode(n.data);
        cur = n.next;
    }

    node.children.deinit();

    if (node.data) |_| {
        if (self.size > 0) self.size -= 1;
    }

    self.pool.destroy(node);
}

pub fn delete(self: *Self, key: []const u8) bool {
    var found = false;
    if (key.len > 0) {
        _ = recursiveDelete(&self.pool, self.root, key, &self.size, &found);
    }

    return found;
}

pub fn recursiveDelete(pool: *MemoryPool(Node), node: ?*Node, key: []const u8, size: *usize, found: *bool) bool {

    if (node == null) return false;

    if (key.len == 0) {
        if (node.?.data) |_| {
            found.* = true;

            // TODO: FREE DATA
            node.?.data = null;

            if (size.* > 0) {
                size.* = size.* - 1;
            }

            return node.?.children.len == 0;
        } else {
            found.* = true;

            if (size.* > 0) {
                size.* = size.* - 1;
            }

            return node.?.children.len == 0;
        }
    } else {

        const cur = linearSearch(&node.?.children, key[0]);
        if (cur == null) return false;

        var child = cur.?.data;
        if (recursiveDelete(pool, child, key[1..], size, found)) {

            var n_rem = Node{.chr = key[0]};
            node.?.children.remove(&n_rem, withChar);

            child.deinit(pool);

            return (node.?.data == null and node.?.children.len == 0);
        }
    }

    return false;
}

pub fn insert(self: *Self, key: []const u8, data: *Topic) !void {
    var cursor = self.root;
    var cur_node: ?*Node = null;
    var tmp_node: ?*List.ListType.Node = null;

    for (key) |chr| {
        tmp_node = linearSearch(&cursor.children, chr);

        if (tmp_node == null) {
            cur_node = try self.createNode(chr);
            _ = try cursor.children.push(cur_node.?);
            mergeSort(&cursor.children);
        } else {
            cur_node = tmp_node.?.data;
        }

        cursor = cur_node.?;
    }

    if (cursor.data == null) {
        self.size += 1;
    }

    cursor.data = data;
}

test "Trie insert" {
    var trie = try init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("hello", undefined);
    try trie.insert("happy", undefined);
    try trie.insert("hanna", undefined);

    try std.testing.expectEqual(trie.size, 3);

    const found = find(trie.root, "ha");
    try std.testing.expect(found != null);
}

test "Trie delete" {
    var trie = try init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("hello", undefined);
    try trie.insert("heappy", undefined);
    try trie.insert("lanna", undefined);

    try std.testing.expectEqual(trie.size, 3);

    _ = trie.delete("hello");
}

test "Trie prefix delete" {
    var trie = try init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("hello", undefined);
    try trie.insert("heappy", undefined);
    try trie.insert("lanna", undefined);

    _ = trie.prefixDelete("he");

    //try std.testing.expectEqual(0, trie.size);

    try trie.print(std.io.getStdOut().writer());
}

pub fn print(self: *const Self, writer: anytype) !void {
    // Print the root node itself (optional, could start from children)
    // try writer.print("{c} (root)\n", .{self.root.chr}); // Assuming root is ' ' or similar

    // Iterate through the direct children of the root
    var cur = self.root.children.list.first;
    while (cur) |list_node| {
        const child = list_node.data;
        const next_sibling = list_node.next;
        // Start recursion for each child of the root.
        // The initial prefix is empty "".
        // Pass whether this root-level child is the last one.
        try printNodeRecursive(child, writer, "", next_sibling == null);
        cur = next_sibling;
    }
}

fn printNodeRecursive(
    node: *const Node,
    writer: anytype, // Use anytype for flexibility (stdout, stderr, file)
    prefix: []const u8, // String prefix for indentation and lines
    is_last: bool, // Is this the last node among its siblings?
) !void {
    // Print the current node's line
    try writer.print("{s}", .{prefix}); // Print the accumulated prefix (indentation + lines)

    if (is_last) {
        try writer.print("└── ", .{}); // Last child connector
    } else {
        try writer.print("├── ", .{}); // Mid-child connector
    }

    // Print the character. Use '{c}' for u8. Add '*' if it holds data.
    try writer.print("{c}{s}\n", .{ node.chr, if (node.data != null) "*" else "" });

    // Prepare the prefix for the children
    var child_prefix_buf: [1024]u8 = undefined; // Adjust buffer size if needed
    var child_prefix_fbs = std.io.fixedBufferStream(&child_prefix_buf);
    const child_writer = child_prefix_fbs.writer();

    try child_writer.print("{s}", .{prefix}); // Start with the parent's prefix
    if (is_last) {
        try child_writer.print("    ", .{}); // Indent without vertical line if last
    } else {
        try child_writer.print("│   ", .{}); // Add vertical line and indent if not last
    }
    const child_prefix = child_prefix_fbs.getWritten();

    // Iterate through children and recurse
    var cur = node.children.list.first;
    while (cur) |list_node| {
        const child = list_node.data;
        const next_sibling = list_node.next;
        // The child is the last one if its 'next' is null
        try printNodeRecursive(child, writer, child_prefix, next_sibling == null);
        cur = next_sibling;
    }
}

fn mergeSort(list: *List) void {
    if (list.len <= 1) return;

    var right_half = list.bisect();
    defer right_half.list = .{};

    mergeSort(list);
    mergeSort(&right_half);

    merge(list, &right_half);
}

fn merge(list: *List, other: *List) void {
    if (other.list.first == null) return;

    if (list.list.first == null) {
        list.list = other.list;
        list.len = other.len;
        other.list = .{};
        other.len = 0;
        return;
    }

    var left_ptr = list.list.first;
    var right_ptr = other.list.first;
    var new_head: ?*List.ListType.Node = null;
    var tail: ?*List.ListType.Node = null;

    if (left_ptr.?.data.chr <= right_ptr.?.data.chr) {
        new_head = left_ptr;
        left_ptr = left_ptr.?.next;
    } else {
        new_head = right_ptr;
        right_ptr = right_ptr.?.next;
    }

    tail = new_head;

    while (left_ptr != null and right_ptr != null) {
        if (left_ptr.?.data.chr <= right_ptr.?.data.chr) {
            tail.?.next = left_ptr;
            tail = left_ptr;
            left_ptr = left_ptr.?.next;
        } else {
            tail.?.next = right_ptr;
            tail = right_ptr;
            right_ptr = right_ptr.?.next;
        }
    }

    if (left_ptr != null) {
        tail.?.next = left_ptr;
    } else {
        tail.?.next = right_ptr;
    }

    list.list.first = new_head;
    list.len += other.len;

    other.list = .{};
    other.len = 0;
}

test "Merge sort" {
    var list = List.init(std.testing.allocator);
    defer list.deinit();

    const values_ordered = [_]u8{ 1, 1, 2, 6, 10, 21 };
    const values = [_]Node{ .{ .chr = 10 }, .{ .chr = 6 }, .{ .chr = 2 }, .{ .chr = 21 }, .{ .chr = 1 }, .{ .chr = 1 } };
    for (0..values.len) |idx| {
        _ = try list.push(@constCast(&values[idx]));
    }

    mergeSort(&list);

    var it = list.list.first;
    var i: usize = 0;
    while (it) |node| {
        try std.testing.expectEqual(values_ordered[i], node.data.chr);
        it = node.next;
        i += 1;
    }
}
