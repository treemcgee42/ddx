const std = @import("std");
const source = @import("lexer/source.zig");
const Lexer = @import("lexer/lexer.zig").Lexer;
const Interner = @import("lexer/interner.zig").Interner;

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
    var file_reader = file.reader();

    var source_reader = try source.SourceReader(@TypeOf(file_reader)).init(file_reader, allocator);
    defer source_reader.deinit();

    var interner = Interner.init(allocator);
    defer interner.deinit();

    var lexer = Lexer(@TypeOf(source_reader)).init(&source_reader, &interner);

    var tokens = try lexer.tokenize(allocator);
    defer tokens.deinit();

    std.debug.print("{}\n", .{tokens});
}
