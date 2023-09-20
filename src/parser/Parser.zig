const std = @import("std");
const Token = @import("../lexer/lexer.zig").Token;
const TokenKind = @import("../lexer/lexer.zig").TokenKind;
const Ast = @import("./Ast.zig");
const Lexer = @import("../lexer/lexer.zig").Lexer;

allocator: std.mem.Allocator,

source: [:0]const u8,
tokens: std.MultiArrayList(Token),
current_token_idx: usize,

errors: std.ArrayList(Error),
nodes: std.MultiArrayList(Ast.Node),
extra_data: std.ArrayList(Ast.NodeHandle),

pub const Error = struct {
    kind: ParseError,
    token: Ast.TokenHandle,
    extra: ExtraData,

    pub const ExtraData = union {
        expected: TokenKind,
    };

    const ParseError = enum {
        invalid_token,
        out_of_bounds_token,
        expected_found,
    };
};

pub const PrintableError = struct {
    err: Error,
    source: [:0]const u8,
    tokens: std.MultiArrayList(Token),

    pub fn format(
        self: PrintableError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        if (self.err.kind == .out_of_bounds_token) {
            try writer.print("out of bounds token\n", .{});
            try writer.print("token trace:\n", .{});
            var j: usize = self.tokens.len - 5;
            while (j < self.tokens.len) : (j += 1) {
                try writer.print("\t{}\t{}\n", .{ self.tokens.items(.kind)[j], self.tokens.items(.span)[j] });
            }
            return;
        }

        const token_kind = self.tokens.items(.kind)[self.err.token];
        const span = self.tokens.items(.span)[self.err.token];

        // Compute the line and column.

        var line: usize = 1;
        var idx_of_line_start: usize = undefined;
        var i: usize = 0;
        while (i < span.start) : (i += 1) {
            if (self.source[i] == '\n') {
                line += 1;
                idx_of_line_start = i + 1;
            }
        }

        const column_minus_1 = std.unicode.utf8CountCodepoints(self.source[idx_of_line_start..span.start]) catch unreachable;
        const column = column_minus_1 + 1;

        // Printing stuff.

        var idx_of_next_newline: usize = undefined;
        i = span.end;
        while (i < self.source.len) : (i += 1) {
            if (self.source[i] == '\n') {
                idx_of_next_newline = i;
                break;
            }
        }

        const source_view = self.source[idx_of_line_start..idx_of_next_newline];

        try writer.print("error at {}:{}: ", .{ line, column });
        switch (self.err.kind) {
            .invalid_token => try writer.print("invalid token ({s})\n", .{@tagName(token_kind)}),
            .expected_found => try writer.print("expected {} but found {}\n", .{ self.err.extra.expected, token_kind }),
            else => unreachable,
        }

        i = 0;
        while (true) : (i += 1) {
            const c = source_view[i];
            if (c == '\t' or c == ' ') {
                continue;
            }

            break;
        }

        try writer.print("{s}\n", .{source_view[i..]});

        while (i < column - 1) : (i += 1) {
            try writer.print(" ", .{});
        }
        try writer.print("^\n", .{});
    }
};

const Self = @This();

/// Leaving this function, `self.current_token_idx` will be pointing to the command
/// beginning `\begin{document}`.
pub fn parse_header(self: *Self) !void {
    while (true) : (self.current_token_idx += 1) {
        switch (self.tokens.items(.kind)[self.current_token_idx]) {
            .eof => {
                try self.errors.append(.{
                    .kind = .invalid_token,
                    .token = self.current_token_idx,
                    .extra = undefined,
                });
            },

            .command => {
                const span = self.tokens.items(.span)[self.current_token_idx];

                if (!std.mem.eql(u8, self.source[span.start + 1 .. span.end], "begin")) {
                    continue;
                }

                const idx_of_command = self.current_token_idx;

                while (true) {
                    self.current_token_idx += 1;

                    if (self.tokens.items(.kind)[self.current_token_idx] == .LBrace) {
                        break;
                    }
                }

                self.current_token_idx += 1;
                const command_name_span = self.tokens.items(.span)[self.current_token_idx];
                if (std.mem.eql(u8, self.source[command_name_span.start..command_name_span.end], "document")) {
                    self.current_token_idx = idx_of_command;
                    break;
                }
            },

            else => {},
        }
    }

    try self.nodes.append(self.allocator, .{
        .kind = .header,
        .token = 0,
        .lhs = 0,
        .rhs = 0,
    });
}

/// Assumes `self.current_token_idx` is pointing to a `RawInput` token.
///
/// Leaves pointing to the next token.
pub fn parse_raw_input(self: *Self) !void {
    try self.nodes.append(self.allocator, .{
        .kind = .raw_input,
        .token = self.current_token_idx,
        .lhs = 0,
        .rhs = 0,
    });

    self.current_token_idx += 1;
}

/// Assumes `self.current_token_idx` is pointing to the first token of the
/// interior of the inline math, e.g. the first token after '$'.
///
/// On leaving, `self.current_token_idx` will be pointing to the first token
/// after the closing `$`.
pub fn parse_inline_math(self: *Self) !void {
    var nodes = std.ArrayList(Ast.NodeHandle).init(self.allocator);
    defer nodes.deinit();

    while (true) {
        switch (self.tokens.items(.kind)[self.current_token_idx]) {
            .Dollar => {
                self.current_token_idx += 1;
                break;
            },

            else => {
                try self.eat_node();
                try nodes.append(self.nodes.len - 1);
            },
        }
    }

    const extra_data_start_idx = self.extra_data.items.len;
    try self.extra_data.appendSlice(nodes.items);
    const extra_data_end_idx = self.extra_data.items.len;

    try self.nodes.append(self.allocator, .{
        .kind = .inline_math,
        .token = 0,
        .lhs = extra_data_start_idx,
        .rhs = extra_data_end_idx,
    });
}

/// - `bracket_or_brace` is `true` if we should parse a bracket arg, `false`
/// if we should parse a brace arg.
///
/// This will simply append the nodes constituting the command argument to
/// the nodes and extra data lists. So, to get the nodes making up the command
/// argument, the caller can look at the nodes that were most recently appended
/// the extra data list.
pub fn parse_command_argument(self: *Self, bracket_or_brace: bool) !void {
    const extra_data_start_idx = self.extra_data.items.len;
    const tok = self.current_token_idx - 1;

    while (true) {
        if (self.current_token_idx >= self.tokens.len) {
            try self.errors.append(.{
                .kind = .out_of_bounds_token,
                .token = 0,
                .extra = undefined,
            });
            self.current_token_idx = self.tokens.len - 1;
            break;
        }

        switch (self.tokens.items(.kind)[self.current_token_idx]) {
            .RBrace => {
                if (!bracket_or_brace) {
                    self.current_token_idx += 1;
                    break;
                }
            },

            .RBracket => {
                if (bracket_or_brace) {
                    self.current_token_idx += 1;
                    break;
                }
            },

            else => {
                try self.eat_node();
                try self.extra_data.append(self.nodes.len - 1);
            },
        }
    }

    const extra_data_end_idx = self.extra_data.items.len;
    try self.nodes.append(self.allocator, .{
        .kind = .grouping,
        .token = tok,
        .lhs = extra_data_start_idx,
        .rhs = extra_data_end_idx,
    });
}

/// Assumes `self.current_token_idx` is pointing to the command token.
pub fn parse_command(self: *Self) !void {
    const command_token_idx = self.current_token_idx;
    const command_span = self.tokens.items(.span)[command_token_idx];
    const command_name = self.source[command_span.start + 1 .. command_span.end];
    if (std.mem.eql(u8, command_name, "begin")) {
        return self.parse_environment();
    }

    self.current_token_idx += 1;

    var brace_arg_token: usize = 0;
    var brace_args = std.ArrayList(Ast.NodeHandle).init(self.allocator);
    defer brace_args.deinit();
    var bracket_arg_token: usize = 0;
    var bracket_args = std.ArrayList(Ast.NodeHandle).init(self.allocator);
    defer bracket_args.deinit();

    while (true) {
        if (self.current_token_idx >= self.tokens.len) {
            try self.errors.append(.{
                .kind = .out_of_bounds_token,
                .token = 0,
                .extra = undefined,
            });
            self.current_token_idx = self.tokens.len - 1;
            break;
        }

        switch (self.tokens.items(.kind)[self.current_token_idx]) {
            .LBrace => {
                self.current_token_idx += 1;

                const brace_tok = self.current_token_idx;
                if (brace_arg_token != 0) {
                    brace_arg_token = brace_tok;
                }

                try self.parse_command_argument(false);
                try brace_args.append(self.nodes.len - 1);
            },

            .LBracket => {
                self.current_token_idx += 1;

                const bracket_tok = self.current_token_idx;
                if (bracket_arg_token != 0) {
                    bracket_arg_token = bracket_tok;
                }

                try self.parse_command_argument(true);
                try bracket_args.append(self.nodes.len - 1);
            },

            else => {
                break;
            },
        }
    }

    const brace_args_start = self.extra_data.items.len;
    try self.extra_data.appendSlice(brace_args.items);
    const brace_args_end = self.extra_data.items.len;

    try self.nodes.append(self.allocator, .{
        .kind = .grouping,
        .token = brace_arg_token,
        .lhs = brace_args_start,
        .rhs = brace_args_end,
    });
    const lhs = self.nodes.len - 1;

    const bracket_args_start = self.extra_data.items.len;
    try self.extra_data.appendSlice(bracket_args.items);
    const bracket_args_end = self.extra_data.items.len;

    try self.nodes.append(self.allocator, .{
        .kind = .grouping,
        .token = bracket_arg_token,
        .lhs = bracket_args_start,
        .rhs = bracket_args_end,
    });
    const rhs = self.nodes.len - 1;

    try self.nodes.append(self.allocator, .{
        .kind = .command,
        .token = command_token_idx,
        .lhs = lhs,
        .rhs = rhs,
    });
}

/// Assumes `self.current_token_idx` is pointing to the underscore token.
fn parse_underscore(self: *Self) !void {
    const underscore_token_idx = self.current_token_idx;
    self.current_token_idx += 1;

    var arg: Ast.NodeHandle = 0;
    switch (self.tokens.items(.kind)[self.current_token_idx]) {
        .LBrace => {
            self.current_token_idx += 1;
            try self.parse_command_argument(false);
            arg = self.nodes.len - 1;
        },

        .RawInput => {
            try self.parse_raw_input();
            arg = self.nodes.len - 1;
        },

        else => {
            try self.errors.append(.{
                .kind = .invalid_token,
                .token = self.current_token_idx,
                .extra = undefined,
            });
        },
    }

    try self.nodes.append(self.allocator, .{
        .kind = .underscore,
        .token = underscore_token_idx,
        .lhs = arg,
        .rhs = 0,
    });
}

/// Assumes `self.current_token_idx` is pointing to the caret token.
fn parse_caret(self: *Self) !void {
    const caret_token_idx = self.current_token_idx;
    self.current_token_idx += 1;

    var arg: Ast.NodeHandle = 0;
    switch (self.tokens.items(.kind)[self.current_token_idx]) {
        .LBrace => {
            self.current_token_idx += 1;
            try self.parse_command_argument(false);
            arg = self.nodes.len - 1;
        },

        .RawInput => {
            try self.parse_raw_input();
            arg = self.nodes.len - 1;
        },

        else => {
            try self.errors.append(.{
                .kind = .invalid_token,
                .token = self.current_token_idx,
                .extra = undefined,
            });
        },
    }

    try self.nodes.append(self.allocator, .{
        .kind = .caret,
        .token = caret_token_idx,
        .lhs = arg,
        .rhs = 0,
    });
}

/// Assumes `self.current_token_idx` is pointing to the first token of the opening
/// command, e.g. `\begin`.
fn parse_environment(self: *Self) !void {
    var nodes = std.ArrayList(Ast.NodeHandle).init(self.allocator);
    defer nodes.deinit();

    self.current_token_idx += 1;

    if (self.tokens.items(.kind)[self.current_token_idx] != .LBrace) {
        try self.errors.append(.{
            .kind = .expected_found,
            .token = self.current_token_idx,
            .extra = .{ .expected = .LBrace },
        });

        self.current_token_idx += 1;
        return;
    }

    self.current_token_idx += 1;

    if (self.tokens.items(.kind)[self.current_token_idx] != .RawInput) {
        try self.errors.append(.{
            .kind = .expected_found,
            .token = self.current_token_idx,
            .extra = .{ .expected = .RawInput },
        });

        self.current_token_idx += 1;
        return;
    }

    const env_name_token_idx = self.current_token_idx;
    const env_name_span = self.tokens.items(.span)[self.current_token_idx];
    const env_name = self.source[env_name_span.start..env_name_span.end];

    self.current_token_idx += 1;

    if (self.tokens.items(.kind)[self.current_token_idx] != .RBrace) {
        try self.errors.append(.{
            .kind = .expected_found,
            .token = self.current_token_idx,
            .extra = .{ .expected = .RBrace },
        });

        self.current_token_idx += 1;
        return;
    }

    self.current_token_idx += 1;

    while (true) {
        if (self.current_token_idx >= self.tokens.items(.span).len) {
            try self.errors.append(.{
                .kind = .out_of_bounds_token,
                .token = 0,
                .extra = undefined,
            });
            // Reset the current token index to the last token.
            self.current_token_idx = self.tokens.len - 1;
            break;
        }

        if (self.tokens.items(.kind)[self.current_token_idx] == .command) {
            const command_idx = self.current_token_idx;
            const span = self.tokens.items(.span)[self.current_token_idx];
            const command_name = self.source[span.start + 1 .. span.end];

            if (std.mem.eql(u8, command_name, "end")) {
                self.current_token_idx += 2;
                const end_env_span = self.tokens.items(.span)[self.current_token_idx];
                const end_env_name = self.source[end_env_span.start..end_env_span.end];
                if (std.mem.eql(u8, end_env_name, env_name)) {
                    self.current_token_idx += 2;
                    break;
                }

                self.current_token_idx = command_idx;
            }
        }

        try self.eat_node();
        try nodes.append(self.nodes.len - 1);
    }

    const extra_data_start_idx = self.extra_data.items.len;
    try self.extra_data.appendSlice(nodes.items);
    const extra_data_end_idx = self.extra_data.items.len;

    try self.nodes.append(self.allocator, .{
        .kind = .environment,
        .token = env_name_token_idx,
        .lhs = extra_data_start_idx,
        .rhs = extra_data_end_idx,
    });
}

fn eat_node(self: *Self) anyerror!void {
    switch (self.tokens.items(.kind)[self.current_token_idx]) {
        .RawInput => {
            return self.parse_raw_input();
        },

        .Dollar => {
            self.current_token_idx += 1;
            return self.parse_inline_math();
        },

        .command => {
            return self.parse_command();
        },

        .underscore => {
            return self.parse_underscore();
        },

        .caret => {
            return self.parse_caret();
        },

        else => {
            try self.errors.append(.{
                .kind = .invalid_token,
                .token = self.current_token_idx,
                .extra = undefined,
            });

            self.current_token_idx += 1;
            return;
        },
    }
}

pub fn parse_document(self: *Self) !void {
    var nodes = std.ArrayList(Ast.NodeHandle).init(self.allocator);
    defer nodes.deinit();

    // Eat the `\begin{document}` sequence.
    while (true) : (self.current_token_idx += 1) {
        switch (self.tokens.items(.kind)[self.current_token_idx]) {
            .RBrace => {
                self.current_token_idx += 1;
                break;
            },

            .eof => {
                try self.errors.append(.{
                    .kind = .invalid_token,
                    .token = self.current_token_idx,
                    .extra = undefined,
                });

                self.current_token_idx += 1;
                return;
            },

            else => {},
        }
    }

    while (true) {
        if (self.current_token_idx >= self.tokens.items(.span).len) {
            try self.errors.append(.{
                .kind = .out_of_bounds_token,
                .token = 0,
                .extra = undefined,
            });
            // Reset the current token index to the last token.
            self.current_token_idx = self.tokens.len - 1;
            break;
        }

        if (self.tokens.items(.kind)[self.current_token_idx] == .command) {
            // Break if it's an `\end{document}`.
            const span = self.tokens.items(.span)[self.current_token_idx];

            if (std.mem.eql(u8, self.source[span.start + 1 .. span.end], "end")) {
                const idx_of_command = self.current_token_idx;

                while (true) {
                    self.current_token_idx += 1;

                    if (self.tokens.items(.kind)[self.current_token_idx] == .LBrace) {
                        break;
                    }
                }

                self.current_token_idx += 1;
                const command_name_span = self.tokens.items(.span)[self.current_token_idx];
                if (std.mem.eql(u8, self.source[command_name_span.start..command_name_span.end], "document")) {
                    self.current_token_idx = idx_of_command;
                    break;
                }

                self.current_token_idx = idx_of_command;
            }
        }

        try self.eat_node();
        try nodes.append(self.nodes.len - 1);
    }

    const extra_data_start_idx = self.extra_data.items.len;
    try self.extra_data.appendSlice(nodes.items);
    const extra_data_end_idx = self.extra_data.items.len;

    try self.nodes.append(self.allocator, .{
        .kind = .document,
        .token = 0,
        .lhs = extra_data_start_idx,
        .rhs = extra_data_end_idx,
    });
}

pub fn parse_root(self: *Self) !void {
    // Reserve the 0 index for the root node.
    try self.nodes.append(self.allocator, .{
        .kind = .root,
        .token = 0,
        .lhs = 0,
        .rhs = 0,
    });

    try self.parse_header();
    const header_idx = self.nodes.len - 1;
    try self.parse_document();
    const document_idx = self.nodes.len - 1;

    self.nodes.items(.lhs)[0] = header_idx;
    self.nodes.items(.rhs)[0] = document_idx;
}
