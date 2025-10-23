const std = @import("std");
const MemoryPool = std.heap.MemoryPool;

const Allocator = std.mem.Allocator;

pub fn SinglyLinkedList(comptime T: type) type {
    return struct {
        list: ListType,
        len: usize = 0,
        pool: MemoryPool(ListType.Node),
        allocator: Allocator,

        pub const ListType = std.SinglyLinkedList(T);
        pub const CompareFn = *const fn(*T, *T) isize;

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .list = .{},
                .pool = MemoryPool(ListType.Node).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var cur = self.list.first;
            while (cur) |current_node| {
                cur = current_node.next;
                self.pool.destroy(current_node);
            }

            self.pool.deinit();

            self.len = 0;
        }

        pub fn remove(self: *Self, node_data: T, cmp: *const fn(T, T) isize) void {
            var it = self.list.first;
            while (it) |n| {
                if (cmp(n.data, node_data) == 0) {
                    self.list.remove(n);
                    self.pool.destroy(n);
                    self.len -= 1;
                    return;
                }

                it = n.next;
            }
        }

        // Push at front of list
        pub fn push(self: *Self, data: T) !*ListType.Node {
            const node = try self.pool.create();
            node.* = .{ .data = data };

            self.list.prepend(node);

            self.len += 1;

            return node;
        }

        pub fn sortInstert(self: *Self, data: T, cmp_fn: CompareFn) void {
            
            const node = try self.pool.create();
            node.* = .{ .data = data };

            if (self.list.first == null or cmp_fn(self.list.first.?, node)) {
                self.list.prepend(node);
            } else {
                var cur = self.list.first.?;

                while (cur.next != null and cmp_fn(cur.next.?, node) < 0) {
                    cur = cur.next.?;
                }

                if (cur.next == null) {
                    cur.next = node;
                } else {
                    node.next = cur.next;
                    cur.next = node;
                }
            }

            self.len += 1;
        }

        //Returns a pointer to a node near the middle of the list
        pub fn bisect(self: *Self) Self {
            var fast: ?*ListType.Node = self.list.first;
            var slow: ?*ListType.Node = self.list.first;
            var prev: ?*ListType.Node = null;

            while (fast != null and fast.?.next != null) {
                fast = fast.?.next.?.next;
                prev = slow;
                slow = slow.?.next;
            }

            var result: Self = .{
                .list = .{ .first = slow },
                .pool = MemoryPool(ListType.Node).init(self.allocator),
                .allocator = self.allocator,
            };

            if (prev != null) {
                prev.?.next = null;
            }

            result.recalculateLen();
            self.recalculateLen();

            return result;
        }

        fn recalculateLen(self: *Self) void {
            var cur = self.list.first;
            var len: usize = 0;

            while (cur) |current_node| {
                len += 1;
                cur = current_node.next;
            }

            self.len = len;
        }
    };
}

test "Push" {
    var l = SinglyLinkedList(usize).init(std.testing.allocator);
    defer l.deinit();

    const data = [_]usize{5, 15, 25, 35, 45, 55, 65};
    for (data) |d| {
        _ = try l.push(d);
    }

    var cur = l.list.first;
    var i = data.len - 1;
    while (cur) |current| {

        try std.testing.expectEqual(data[i], current.data);

        cur = current.next;
        if (i == 0) {
            try std.testing.expect(cur == null);
            break;
        }
        i -= 1;
    }
}

test "Bisect" {
    var l = SinglyLinkedList(usize).init(std.testing.allocator);
    defer l.deinit();

    var data = [_]usize{5, 15, 25, 35, 45, 55, 65};
    for (data) |d| {
        _ = try l.push(d);
    }

    std.mem.reverse(usize, &data);

    var bisected = l.bisect();
    defer bisected.deinit();

    try std.testing.expectEqual(l.len, 3);
    try std.testing.expectEqual(bisected.len, 4);

    var cur = l.list.first;
    var i: usize = 0;
    while (cur) |current| {

        try std.testing.expectEqual(data[i], current.data);

        cur = current.next;
        i += 1;
    }

    cur = bisected.list.first;
    while (cur) |current| {

        try std.testing.expectEqual(data[i], current.data);

        cur = current.next;
        i += 1;
    }
}