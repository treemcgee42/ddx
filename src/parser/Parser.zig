const std = @import("std");
const Token = @import("../lexer/lexer.zig").Token;
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

    const ParseError = enum {
        invalid_token,
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
        }

        try writer.print("{s}\n", .{source_view});

        i = 0;
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

            .RawInput => {
                try self.parse_raw_input();
                try nodes.append(self.nodes.len - 1);
            },

            else => {
                try self.errors.append(.{
                    .kind = .invalid_token,
                    .token = self.current_token_idx,
                });

                self.current_token_idx += 1;
                return;
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

/// Assumes `self.current_token_idx` is pointing to the command token.
pub fn parse_command(self: *Self) !void {
    const command_token_idx = self.current_token_idx;
    const command_span = self.tokens.items(.span)[command_token_idx];
    const command_name = self.source[command_span.start + 1 .. command_span.end];
    if (std.mem.eql(u8, command_name, "begin")) {
        return self.parse_environment();
    }

    self.current_token_idx += 1;

    var brace_arg: Ast.NodeHandle = undefined;
    var bracket_arg: Ast.NodeHandle = undefined;

    while (true) {
        switch (self.tokens.items(.kind)[self.current_token_idx]) {
            .LBrace => {
                self.current_token_idx += 1;
                try self.parse_raw_input();
                brace_arg = self.nodes.len - 1;

                if (self.tokens.items(.kind)[self.current_token_idx] != .RBrace) {
                    try self.errors.append(.{
                        .kind = .invalid_token,
                        .token = self.current_token_idx,
                    });

                    return;
                }
            },

            .LBracket => {
                self.current_token_idx += 1;
                try self.parse_raw_input();
                bracket_arg = self.nodes.len - 1;

                if (self.tokens.items(.kind)[self.current_token_idx] != .RBracket) {
                    try self.errors.append(.{
                        .kind = .invalid_token,
                        .token = self.current_token_idx,
                    });

                    return;
                }
            },

            else => {
                brace_arg = 0;
                bracket_arg = 0;
                break;
            },
        }
    }

    try self.nodes.append(self.allocator, .{
        .kind = .command,
        .token = command_token_idx,
        .lhs = brace_arg,
        .rhs = bracket_arg,
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
            .kind = .invalid_token,
            .token = self.current_token_idx,
        });

        self.current_token_idx += 1;
        return;
    }

    self.current_token_idx += 1;

    if (self.tokens.items(.kind)[self.current_token_idx] != .RawInput) {
        try self.errors.append(.{
            .kind = .invalid_token,
            .token = self.current_token_idx,
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
            .kind = .invalid_token,
            .token = self.current_token_idx,
        });

        self.current_token_idx += 1;
        return;
    }

    self.current_token_idx += 1;

    while (true) {
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

        else => {
            try self.errors.append(.{
                .kind = .invalid_token,
                .token = self.current_token_idx,
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
                });

                self.current_token_idx += 1;
                return;
            },

            else => {},
        }
    }

    while (true) {
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
