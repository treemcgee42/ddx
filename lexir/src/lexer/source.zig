const std = @import("std");

/// Describes a position in the source code.
pub const SourcePosition = struct {
    line: usize,
    column: usize,

    const Self = @This();

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{d}:{d}", .{
            self.line,
            self.column,
        });
    }
};

/// Describes a range of source code.
pub const SourceSpan = struct {
    /// This is the position of the first character in the span.
    start: SourcePosition,
    /// This is the position of the last character in the span.
    end: SourcePosition,

    const Self = @This();

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{}-{}", .{
            self.start,
            self.end,
        });
    }
};

/// Handles reading a source line-by-line, keeping track of positions and accounting
/// for UTF-8 encoding. Interaction with the source code should be done through
/// this interface.
///
/// To define a concrete type all you need to do is pass the reader type, for example
/// the reader of a file. It is the caller's responsibility to ensure the reader is
/// valid for the lifetime of an instance of this type. For example, the file must
/// not be closed while the SourceReader is in use.
pub fn SourceReader(comptime ReaderType: type) type {
    return struct {
        /// This is the position of the previously read character, if any.
        current_source_position: SourcePosition,

        reader: ReaderType,
        buffer: std.ArrayList(u8),
        iterator: std.unicode.Utf8Iterator,

        /// These exist for the `peek()` functionality.
        next_char: ?u21 = null,
        eof: bool = false,

        const Self = @This();

        pub fn init(reader: ReaderType, allocator: std.mem.Allocator) !@This() {
            var buffer = std.ArrayList(u8).init(allocator);
            try reader.streamUntilDelimiter(buffer.writer(), '\n', null);

            var utf8_view = try std.unicode.Utf8View.init(buffer.items);

            return .{
                .current_source_position = .{
                    .line = 1,
                    .column = 0,
                },

                .reader = reader,
                .buffer = buffer,
                .iterator = utf8_view.iterator(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        fn load_next_line(self: *Self) !void {
            self.buffer.items.len = 0;
            self.reader.streamUntilDelimiter(self.buffer.writer(), '\n', null) catch |err| {
                if (err == error.EndOfStream) {
                    return err;
                }

                unreachable;
            };
            var utf8_view = std.unicode.Utf8View.init(self.buffer.items) catch unreachable;
            self.iterator = utf8_view.iterator();

            self.current_source_position.line += 1;
            self.current_source_position.column = 0;
        }

        pub fn next(self: *Self) ?u21 {
            if (self.eof) {
                return null;
            }

            if (self.next_char != null) {
                const to_return = self.next_char.?;
                self.next_char = null;
                return to_return;
            }

            var next_cp = self.iterator.nextCodepoint();
            if (next_cp != null) {
                self.current_source_position.column += 1;
                return next_cp.?;
            }

            self.load_next_line() catch |err| {
                if (err == error.EndOfStream) {
                    return null;
                }
            };

            return '\n';
        }

        pub fn peek(self: *Self) ?u21 {
            if (self.eof) {
                return null;
            }

            if (self.next_char != null) {
                return self.next_char.?;
            }

            var next_cp = self.iterator.peek(1);
            if (next_cp.len != 0) {
                return std.unicode.utf8Decode(next_cp) catch unreachable;
            }

            self.load_next_line() catch |err| {
                if (err == error.EndOfStream) {
                    self.eof = true;
                    return null;
                }
            };

            self.next_char = '\n';

            return '\n';
        }
    };
}
