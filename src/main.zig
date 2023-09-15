const std = @import("std");
const Stat = std.fs.File.Stat;
const Lexer = @import("lexer/lexer.zig").Lexer;
const Interner = @import("lexer/interner.zig").Interner;
const Ast = @import("parser/Ast.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const filename = args.next() orelse {
        std.debug.print("Usage: lexir <filename>\n", .{});
        return std.process.exit(1);
    };
    const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
    defer file.close();

    const source = try file.readToEndAllocOptions(allocator, 1_000_000_000, null, @alignOf(u8), 0);
    defer allocator.free(source);

    var ast = try Ast.init_parse(allocator, source);
    std.debug.print("{}\n", .{ast});
    defer ast.deinit();
}
