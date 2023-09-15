const std = @import("std");
const Interner = @import("interner.zig").Interner;

pub const TokenKind = union(enum) {
    /// Just a source span, used to indicate "this section shouldn't be parsed,
    /// just put it in as is."
    RawInput,
    /// This is the only context-sensitive token. The reason we don't just use
    /// RawInput is because we care about the value of the identifier, and
    /// RawInput only tracks the source code span. If we know at lexer time
    /// that this is an identifier, we can intern its value.
    Identifier,
    command,

    Begin,
    End,

    Newline,

    Dollar,
    double_dollar,
    Backslash,
    LBrace,
    RBrace,
    LBracket,
    RBracket,

    eof,
    invalid,

    pub fn format(
        self: TokenKind,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}", .{@tagName(self)});
    }
};

pub const Token = struct {
    kind: TokenKind,
    span: SourceSpan,

    pub const SourceSpan = struct {
        start: usize,
        end: usize,
    };

    pub fn format(
        self: Token,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Token( kind: {}, span: {}-{} )", .{ self.kind, self.span.start, self.span.end });
    }
};

pub const Lexer = struct {
    source: [:0]const u8,
    current_source_index: usize,
    state: LexerState,

    const LexerState = enum {
        start,
        expecting_identifier,
        started_identifier,
        prev_was_backslash,
        accepting_raw_input,
        prev_was_dollar,
    };

    const Self = @This();

    /// The caller is responsible for ensuring the source is valid for the
    /// lifetime of an instance of this type.
    pub fn init(source: [:0]const u8) Self {
        return Self{
            .source = source,
            .current_source_index = 0,
            .state = .start,
        };
    }

    /// Returns `null` if the end of the stream is reached.
    pub fn eat_token(self: *Self) Token {
        var start = self.current_source_index;
        var end: usize = undefined;

        self.state = .start;
        var token_kind: TokenKind = undefined;

        while (true) {
            const c = self.source[self.current_source_index];

            if (self.state == .prev_was_dollar and c != '$') {
                end = self.current_source_index;

                return .{
                    .kind = .Dollar,
                    .span = .{
                        .start = start,
                        .end = end,
                    },
                };
            }

            switch (c) {
                0 => {
                    if (self.current_source_index == self.source.len) {
                        end = self.current_source_index;

                        return .{
                            .kind = .eof,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.current_source_index += 1;
                    end = self.current_source_index;

                    return .{
                        .kind = .invalid,
                        .span = .{
                            .start = start,
                            .end = end,
                        },
                    };
                },

                '\\' => {
                    if (self.state == .accepting_raw_input) {
                        end = self.current_source_index;

                        return .{
                            .kind = .RawInput,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.state = .prev_was_backslash;
                    self.current_source_index += 1;
                },

                'a'...'z', 'A'...'Z' => {
                    if (self.state == .prev_was_backslash) {
                        token_kind = .command;
                        self.state = .started_identifier;
                        self.current_source_index += 1;
                        continue;
                    }

                    if (self.state == .started_identifier) {
                        self.current_source_index += 1;
                        continue;
                    }

                    token_kind = .RawInput;
                    self.state = .accepting_raw_input;
                    self.current_source_index += 1;
                },

                '0'...'9', '=', '.', ',', '!', '/' => {
                    token_kind = .RawInput;
                    self.state = .accepting_raw_input;
                    self.current_source_index += 1;
                },

                '[' => {
                    if (self.state != .start) {
                        end = self.current_source_index;

                        return .{
                            .kind = token_kind,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.current_source_index += 1;
                    end = self.current_source_index;
                    return .{
                        .kind = .LBracket,
                        .span = .{
                            .start = start,
                            .end = end,
                        },
                    };
                },

                ']' => {
                    if (self.state != .start) {
                        end = self.current_source_index;

                        return .{
                            .kind = token_kind,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.current_source_index += 1;
                    end = self.current_source_index;
                    return .{
                        .kind = .RBracket,
                        .span = .{
                            .start = start,
                            .end = end,
                        },
                    };
                },

                '{' => {
                    if (self.state != .start) {
                        end = self.current_source_index;

                        return .{
                            .kind = token_kind,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.current_source_index += 1;
                    end = self.current_source_index;
                    return .{
                        .kind = .LBrace,
                        .span = .{
                            .start = start,
                            .end = end,
                        },
                    };
                },

                '}' => {
                    if (self.state != .start) {
                        end = self.current_source_index;

                        return .{
                            .kind = token_kind,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.current_source_index += 1;
                    end = self.current_source_index;
                    return .{
                        .kind = .RBrace,
                        .span = .{
                            .start = start,
                            .end = end,
                        },
                    };
                },

                '\n', '\t', ' ' => {
                    if (self.state == .start) {
                        start += 1;
                        self.current_source_index += 1;
                        continue;
                    }

                    if (self.state != .accepting_raw_input) {
                        end = self.current_source_index;

                        return .{
                            .kind = token_kind,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.current_source_index += 1;
                },

                '$' => {
                    if (self.state == .prev_was_dollar) {
                        self.current_source_index += 1;
                        end = self.current_source_index;

                        return .{ .kind = .double_dollar, .span = .{
                            .start = start,
                            .end = end,
                        } };
                    }

                    if (self.state != .start) {
                        end = self.current_source_index;

                        return .{
                            .kind = token_kind,
                            .span = .{
                                .start = start,
                                .end = end,
                            },
                        };
                    }

                    self.state = .prev_was_dollar;
                    self.current_source_index += 1;
                },

                else => {
                    self.current_source_index += 1;
                    end = self.current_source_index;

                    return .{
                        .kind = .invalid,
                        .span = .{
                            .start = start,
                            .end = end,
                        },
                    };
                },
            }
        }
    }
};

test "print tokens" {
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

    var lexer = Lexer.init(source);

    while (true) {
        const token = lexer.eat_token();
        if (token.kind == .eof) {
            break;
        }

        std.debug.print("{}\n", .{token});
    }
}
