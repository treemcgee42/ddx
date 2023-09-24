const std = @import("std");
const Token = @import("../lexer/lexer.zig").Token;
const TokenStream = @import("../lexer/lexer.zig").TokenStream;
const Parser = @import("./Parser.zig");
const Lexer = @import("../lexer/lexer.zig").Lexer;

allocator: std.mem.Allocator,

source: [:0]const u8,
tokens: std.MultiArrayList(Token),

errors: std.ArrayList(Parser.Error),
nodes: std.MultiArrayList(Node),
extra_data: std.ArrayList(NodeHandle),

const Ast = @This();
const Self = @This();

/// Essentially an index into the `nodes` array.
pub const NodeHandle = usize;
/// Index into either the `nodes` or `extra_data` array. The specific
/// struct should know which array it belongs to.
pub const NodeOrExtraDataHandle = usize;
/// Essentially an index into the `tokens` array.
pub const TokenHandle = usize;

const Error = error{LexerError};

pub fn init_parse(gpa: std.mem.Allocator, source: [:0]const u8) !Self {
    var tokens = std.MultiArrayList(Token){};

    var lexer = Lexer.init(source);
    var lexer_errors: u8 = 0;
    while (true) {
        const token = lexer.eat_token();
        if (token.kind == .eof) {
            break;
        }

        try tokens.append(gpa, token);

        if (token.kind == .invalid) {
            std.debug.print("tokens trace:\n", .{});
            var j: usize = @intCast(@max(0, @as(i32, @intCast(tokens.len)) - 10));
            while (j < tokens.len) : (j += 1) {
                std.debug.print("{}\t{}\n", .{ tokens.items(.kind)[j], tokens.items(.span)[j] });
            }
            const printable_error: Parser.PrintableError = .{
                .err = .{
                    .kind = .invalid_token,
                    .token = tokens.len - 1,
                    .extra = undefined,
                },
                .source = source,
                .tokens = tokens,
            };
            std.debug.print("{}\n", .{printable_error});
            lexer_errors += 1;

            if (lexer_errors > 3) {
                break;
            }
        }
    }

    if (lexer_errors > 0) {
        tokens.deinit(gpa);
        return error.LexerError;
    }

    // var i: usize = 0;
    // while (i < tokens.len) : (i += 1) {
    //     std.debug.print("{}\t{}\n", .{ tokens.items(.kind)[i], tokens.items(.span)[i] });
    // }

    var errors = std.ArrayList(Parser.Error).init(gpa);
    var extra_data = std.ArrayList(NodeHandle).init(gpa);

    var parser: Parser = .{
        .allocator = gpa,

        .source = source,
        .tokens = tokens,
        .current_token_idx = 0,

        .errors = errors,
        .nodes = .{},
        .extra_data = extra_data,
    };

    try parser.parse_root();

    std.debug.print("Finished parsing.\n", .{});

    var printable_error: Parser.PrintableError = undefined;
    for (parser.errors.items) |err| {
        printable_error = .{
            .err = err,
            .source = source,
            .tokens = tokens,
        };
        std.debug.print("{}\n", .{printable_error});
    }

    return .{
        .allocator = gpa,

        .source = source,
        .tokens = tokens,

        .errors = parser.errors,
        .nodes = parser.nodes,
        .extra_data = parser.extra_data,
    };
}

pub fn deinit(self: *Self) void {
    self.tokens.deinit(self.allocator);
    self.errors.deinit();
    self.nodes.deinit(self.allocator);
    self.extra_data.deinit();
}

pub fn format(
    self: Self,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var i: usize = 0;
    var working_node_kind: NodeKind = undefined;
    while (i < self.nodes.len) : (i += 1) {
        working_node_kind = self.nodes.items(.kind)[i];

        switch (working_node_kind) {
            .root => {
                const full_node = FullNode.Root.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .header => {
                const full_node = FullNode.Header.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .document => {
                const full_node = FullNode.Document.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .raw_input => {
                const full_node = FullNode.RawInput.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .command => {
                const full_node = FullNode.Command.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .inline_math => {
                const full_node = FullNode.InlineMath.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .environment => {
                const full_node = FullNode.Environment.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .underscore => {
                const full_node = FullNode.Underscore.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .caret => {
                const full_node = FullNode.Caret.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },

            .grouping => {
                const full_node = FullNode.Grouping.init(i, &self);
                try writer.print("\n{}: {}\n", .{ i, full_node });
            },
        }
    }
}

pub const NodeKind = enum {
    /// The top level node.
    ///
    /// - `lhs`: the header.
    /// - `rhs`: the document.
    root,
    /// Anything before `\begin{document}`.
    /// At this point, we don't care about the header.
    ///
    /// - `lhs`: ignored
    /// - `rhs`: ignored
    header,
    /// Anything between `\begin{document}` and `\end{document}`.
    ///
    /// `extra_data[lhs..rhs]` yields the indices of the nodes making up the
    /// things inside the document environment.
    document,

    /// - `lhs`: ignored
    /// - `rhs`: ignored
    raw_input,
    /// `extra_data[lhs..rhs]` yields the indices of the nodes making up the things
    /// inside the math environment.
    inline_math,
    /// - `token`: the identifier representing the command name.
    /// - `lhs`: grouping node, representing the brace arguments. Each of the nodes
    /// in the grouping node is itself a grouping node, representing a single brace
    /// argument.
    /// - `rhs`: grouping node, representing the bracket arguments. Each of the nodes
    /// in the grouping node is itself a grouping node, representing a single bracket
    /// argument.
    command,
    /// - `token`: the identifier representing the environment name.
    ///
    /// `extra_data[lhs..rhs]` yields the indices of the nodes making up the
    /// environment.
    environment,
    /// - `token`: the underscore.
    /// - `lhs`: the argument to the underscore.
    /// - `rhs`: ignored
    underscore,
    /// - `token`: the caret.
    /// - `lhs`: the argument to the caret.
    /// - `rhs`: ignored
    caret,

    /// Simply a collection of nodes to be considered consecutively.
    ///
    /// - `token`: the first token in the grouping.
    /// - `lhs`: index into extra data.
    /// - `rhs`: index into extra data.
    ///
    /// `extra_data[lhs..rhs]` yields the indices of the nodes making up the
    /// grouping.
    grouping,
};

pub const Node = struct {
    kind: NodeKind,
    token: TokenHandle,
    lhs: NodeHandle,
    rhs: NodeOrExtraDataHandle,
};

pub const FullNode = struct {
    pub const Root = struct {
        header: NodeHandle,
        document: NodeHandle,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Root {
            return .{
                .header = ast.nodes.items(.lhs)[handle],
                .document = ast.nodes.items(.rhs)[handle],
                .ast = ast,
            };
        }

        pub fn format(
            self: Root,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("Root (\n\theader: {}\n\tdocument: {}\n)", .{ self.header, self.document });
        }
    };

    pub const Header = struct {
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Header {
            _ = handle;

            return .{ .ast = ast };
        }

        pub fn format(
            self: Header,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = self;
            _ = fmt;
            _ = options;

            try writer.print("Header", .{});
        }
    };

    pub const Document = struct {
        extra_data_range_start: NodeOrExtraDataHandle,
        extra_data_range_end: NodeOrExtraDataHandle,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Document {
            return .{
                .extra_data_range_start = ast.nodes.items(.lhs)[handle],
                .extra_data_range_end = ast.nodes.items(.rhs)[handle],
                .ast = ast,
            };
        }

        pub fn format(
            self: Document,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("Document (\n\tchildren: {d}\n)", .{self.ast.extra_data.items[self.extra_data_range_start..self.extra_data_range_end]});
        }
    };

    pub const RawInput = struct {
        span_start: usize,
        span_end: usize,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) RawInput {
            const token_handle = ast.nodes.items(.token)[handle];
            return .{
                .span_start = ast.tokens.items(.span)[token_handle].start,
                .span_end = ast.tokens.items(.span)[token_handle].end,
                .ast = ast,
            };
        }

        pub fn format(
            self: RawInput,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("RawInput (\n\tpreview: \"", .{});

            const span_length = self.span_end - self.span_start;
            if (span_length > 50) {
                // Print the first 25 chars and the last 25 chars, separated by
                // a ....
                try writer.print("{s}....{s}", .{
                    self.ast.source[self.span_start .. self.span_start + 25],
                    self.ast.source[self.span_end - 25 .. self.span_end],
                });
            } else {
                try writer.print("{s}", .{self.ast.source[self.span_start..self.span_end]});
            }

            try writer.print("\"\n)", .{});
        }
    };

    pub const Command = struct {
        token: TokenHandle,
        brace_args: Grouping,
        bracket_args: Grouping,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Command {
            const lhs = ast.nodes.items(.lhs)[handle];
            const rhs = ast.nodes.items(.rhs)[handle];

            return .{
                .token = ast.nodes.items(.token)[handle],
                .brace_args = Grouping.init(lhs, ast),
                .bracket_args = Grouping.init(rhs, ast),
                .ast = ast,
            };
        }

        pub fn format(
            self: Command,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const name_span = self.ast.tokens.items(.span)[self.token];
            const name = self.ast.source[name_span.start + 1 .. name_span.end];

            try writer.print("Command (\n\tname: {s}\n\tbracket_args: {}\n\tbrace_args: {}\n)", .{ name, self.bracket_args, self.brace_args });
        }
    };

    pub const InlineMath = struct {
        extra_data_range_start: NodeOrExtraDataHandle,
        extra_data_range_end: NodeOrExtraDataHandle,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) InlineMath {
            return .{
                .extra_data_range_start = ast.nodes.items(.lhs)[handle],
                .extra_data_range_end = ast.nodes.items(.rhs)[handle],
                .ast = ast,
            };
        }

        pub fn format(
            self: InlineMath,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("InlineMath (\n\tchildren: {d}\n)", .{self.ast.extra_data.items[self.extra_data_range_start..self.extra_data_range_end]});
        }
    };

    pub const Environment = struct {
        token: TokenHandle,
        extra_data_range_start: NodeOrExtraDataHandle,
        extra_data_range_end: NodeOrExtraDataHandle,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Environment {
            return .{
                .token = ast.nodes.items(.token)[handle],
                .extra_data_range_start = ast.nodes.items(.lhs)[handle],
                .extra_data_range_end = ast.nodes.items(.rhs)[handle],
                .ast = ast,
            };
        }

        pub fn format(
            self: Environment,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const env_name_span = self.ast.tokens.items(.span)[self.token];
            const env_name = self.ast.source[env_name_span.start..env_name_span.end];

            try writer.print("Environment (\n\tname: {s}\n\tchildren: {d}\n)", .{ env_name, self.ast.extra_data.items[self.extra_data_range_start..self.extra_data_range_end] });
        }
    };

    pub const Underscore = struct {
        token: TokenHandle,
        arg: NodeHandle,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Underscore {
            return .{
                .token = ast.nodes.items(.token)[handle],
                .arg = ast.nodes.items(.lhs)[handle],
                .ast = ast,
            };
        }

        pub fn format(
            self: Underscore,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("Underscore (\n\targ: {d}\n)", .{self.arg});
        }
    };

    pub const Caret = struct {
        token: TokenHandle,
        arg: NodeHandle,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Caret {
            return .{
                .token = ast.nodes.items(.token)[handle],
                .arg = ast.nodes.items(.lhs)[handle],
                .ast = ast,
            };
        }

        pub fn format(
            self: Caret,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("Caret (\n\tchildren: {d}\n)", .{self.arg});
        }
    };

    pub const Grouping = struct {
        token: TokenHandle,
        lhs: NodeHandle,
        rhs: NodeHandle,
        ast: *const Ast,

        pub fn init(handle: NodeHandle, ast: *const Ast) Grouping {
            if (ast.nodes.items(.kind)[handle] != .grouping) {
                unreachable;
            }

            return .{
                .token = ast.nodes.items(.token)[handle],
                .lhs = ast.nodes.items(.lhs)[handle],
                .rhs = ast.nodes.items(.rhs)[handle],
                .ast = ast,
            };
        }

        pub fn format(
            self: Grouping,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("Grouping (\n\tchildren: {d}\n)", .{self.ast.extra_data.items[self.lhs..self.rhs]});
        }
    };
};
