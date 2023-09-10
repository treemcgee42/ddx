const std = @import("std");
const SourceSpan = @import("source.zig").SourceSpan;
const Interner = @import("interner.zig").Interner;

pub const TokenKind = union(enum) {
    Unknown,
    Eof,

    /// Just a source span, used to indicate "this section shouldn't be parsed,
    /// just put it in as is."
    RawInput,
    /// This is the only context-sensitive token. The reason we don't just use
    /// RawInput is because we care about the value of the identifier, and
    /// RawInput only tracks the source code span. If we know at lexer time
    /// that this is an identifier, we can intern its value.
    Identifier: []const u8,

    Begin,
    End,

    Newline,

    Dollar,
    Backslash,
    LBrace,
    RBrace,
    LBracket,
    RBracket,

    pub fn format(
        self: TokenKind,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        if (self == .Identifier) {
            try writer.print("Identifier({s})", .{self.Identifier});
            return;
        }

        try writer.print("{s}", .{@tagName(self)});
    }
};

pub const Token = struct {
    kind: TokenKind,
    span: SourceSpan,

    pub fn format(
        self: Token,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Token( kind: {}, span: {} )", .{
            self.kind,
            self.span,
        });
    }
};

pub const TokenStream = struct {
    tokens: std.ArrayList(Token),

    pub fn format(
        self: TokenStream,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("TokenStream( tokens:", .{});

        for (self.tokens.items) |token| {
            try writer.print("\n\t{}", .{token});
        }

        try writer.print("\n)", .{});
    }

    pub fn deinit(self: *TokenStream) void {
        self.tokens.deinit();
    }
};

pub fn Lexer(comptime SourceReaderType: type) type {
    return struct {
        source: *SourceReaderType,
        interner: *Interner,
        prev_token: ?Token,
        expecting_identifier: bool,

        const Self = @This();

        pub fn init(source: *SourceReaderType, interner: *Interner) Self {
            return Self{
                .source = source,
                .interner = interner,
                .prev_token = null,
                .expecting_identifier = false,
            };
        }

        fn eat_raw_input(self: *Self) Token {
            const start_pos = self.source.current_source_position;
            var end_pos = start_pos;

            while (true) {
                const next_c = self.source.peek() orelse break;

                if (next_c == '\\' or next_c == '\n' or next_c == '$' or next_c == '{' or next_c == '}') {
                    break;
                }

                _ = self.source.next();
                end_pos = self.source.current_source_position;
            }

            return Token{
                .kind = .RawInput,
                .span = .{
                    .start = start_pos,
                    .end = end_pos,
                },
            };
        }

        fn eat_identifier(self: *Self) Token {
            const start_pos = self.source.current_source_position;
            var end_pos = start_pos;

            var buf = [_]u8{0} ** 512;
            var buf_len: usize = 0;

            while (true) {
                const next_c = self.source.peek() orelse break;

                if (next_c == '{' or next_c == '}') {
                    break;
                }

                if (self.prev_token.?.kind == .Backslash) {
                    if (next_c == ' ' or next_c == '\n' or next_c == '\t' or next_c == '[' or next_c == ']') {
                        break;
                    }
                }

                _ = self.source.next();
                end_pos = self.source.current_source_position;

                const bytes_written = std.unicode.utf8Encode(next_c, buf[buf_len..]) catch {
                    @panic("Identifier too long.");
                };
                buf_len += bytes_written;
            }

            const interned_str = self.interner.intern(buf[0..buf_len]) catch |err| {
                std.debug.panic("interner error: {}", .{err});
            };
            return Token{
                .kind = .{ .Identifier = interned_str },
                .span = .{
                    .start = start_pos,
                    .end = end_pos,
                },
            };
        }

        /// Returns `null` if the end of the stream is reached.
        fn eat_token(self: *Self) ?Token {
            const first_c = self.source.peek() orelse {
                return null;
            };

            if (first_c == '\n') {
                _ = self.source.next();
                const start_pos = self.source.current_source_position;
                var end_pos = start_pos;

                // Eat remaining newlines.
                while (true) {
                    if (self.source.peek() != '\n') {
                        break;
                    }

                    _ = self.source.next();
                    end_pos = self.source.current_source_position;
                }

                return Token{ .kind = .Newline, .span = .{
                    .start = start_pos,
                    .end = end_pos,
                } };
            }

            if (first_c == '$') {
                _ = self.source.next();
                const start_pos = self.source.current_source_position;

                return Token{
                    .kind = .Dollar,
                    .span = .{
                        .start = start_pos,
                        .end = start_pos,
                    },
                };
            }

            if (first_c == '\\') {
                _ = self.source.next();
                const start_pos = self.source.current_source_position;

                self.expecting_identifier = true;

                return Token{
                    .kind = .Backslash,
                    .span = .{
                        .start = start_pos,
                        .end = start_pos,
                    },
                };
            }

            if (first_c == '{') {
                _ = self.source.next();
                const start_pos = self.source.current_source_position;

                self.expecting_identifier = true;

                return Token{
                    .kind = .LBrace,
                    .span = .{
                        .start = start_pos,
                        .end = start_pos,
                    },
                };
            }

            if (first_c == '}') {
                _ = self.source.next();
                const start_pos = self.source.current_source_position;

                return Token{
                    .kind = .RBrace,
                    .span = .{
                        .start = start_pos,
                        .end = start_pos,
                    },
                };
            }

            if (first_c == '[') {
                _ = self.source.next();
                const start_pos = self.source.current_source_position;

                return Token{
                    .kind = .LBracket,
                    .span = .{
                        .start = start_pos,
                        .end = start_pos,
                    },
                };
            }

            if (first_c == ']') {
                _ = self.source.next();
                const start_pos = self.source.current_source_position;

                return Token{
                    .kind = .RBracket,
                    .span = .{
                        .start = start_pos,
                        .end = start_pos,
                    },
                };
            }

            if (self.expecting_identifier) {
                self.expecting_identifier = false;

                return self.eat_identifier();
            }

            return self.eat_raw_input();
        }

        /// Caller is responsible for calling `deinit()` on the token stream when done.
        pub fn tokenize(self: *Self, allocator: std.mem.Allocator) !TokenStream {
            var tokens = std.ArrayList(Token).init(allocator);

            while (true) {
                const token = self.eat_token() orelse break;
                self.prev_token = token;
                try tokens.append(token);
            }

            return TokenStream{
                .tokens = tokens,
            };
        }
    };
}
