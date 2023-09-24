const std = @import("std");

pub const Interner = struct {
    allocator: std.heap.ArenaAllocator,
    map: std.StringHashMap([]u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = std.heap.ArenaAllocator.init(allocator),
            .map = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
        self.allocator.deinit();
    }

    pub fn intern(self: *Self, str: []const u8) ![]u8 {
        if (self.map.contains(str)) {
            // Return the slice backed by interner memory.
            return self.map.get(str).?;
        } else {
            // Allocate memory in the arena for the string.
            const interned_str = try self.allocator.allocator().alloc(u8, str.len);
            std.mem.copy(u8, interned_str, str);

            // Add the new string to the map.
            try self.map.put(interned_str, interned_str);

            // Return the new, interned string.
            return interned_str;
        }
    }
};
