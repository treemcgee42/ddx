const std = @import("std");
const Ast = @import("parser/Ast.zig");

pub const State = enum {
    start,
    /// Print the LaTeX as it was when parsed.
    literal,
    /// Don't print surrounding `<p>` and `</p>`.
    raw_input_suppress_p,
    /// Do not print anything around the content of the token.
    no_surround,
};

pub fn walk(ast: *const Ast, current_node: usize, state: State, indent_level: u8, writer: anytype) !void {
    if (state != .literal) {
        var ind: u8 = 0;
        while (ind < indent_level) : (ind += 1) {
            try writer.print("  ", .{});
        }
    }

    switch (ast.nodes.items(.kind)[current_node]) {
        .root => {
            const full_node = Ast.FullNode.Root.init(current_node, ast);
            try walk(ast, full_node.document, .start, indent_level, writer);
        },

        .document => {
            const full_node = Ast.FullNode.Document.init(current_node, ast);
            const children = ast.extra_data.items[full_node.extra_data_range_start..full_node.extra_data_range_end];

            for (children) |child| {
                try walk(ast, child, .start, indent_level, writer);
            }
        },

        .raw_input => {
            const full_node = Ast.FullNode.RawInput.init(current_node, ast);
            const source = ast.source[full_node.span_start..full_node.span_end];

            if (state == .literal or state == .raw_input_suppress_p) {
                try writer.print("{s}", .{source});
            } else {
                try writer.print("<p>{s}</p>\n", .{source});
            }
        },

        .inline_math => {
            const full_node = Ast.FullNode.InlineMath.init(current_node, ast);
            const children = ast.extra_data.items[full_node.extra_data_range_start..full_node.extra_data_range_end];

            try writer.print("<InlineMath str={{String.raw`", .{});

            for (children) |child| {
                try walk(ast, child, .literal, indent_level, writer);
            }

            try writer.print("`}} />\n", .{});
        },

        .command => {
            const full_node = Ast.FullNode.Command.init(current_node, ast);
            const command_name_span = ast.tokens.items(.span)[full_node.token];
            const command_name = ast.source[command_name_span.start + 1 .. command_name_span.end];
            const bracket_arg_token = ast.nodes.items(.token)[full_node.bracket_arg];
            const bracket_arg_span = ast.tokens.items(.span)[bracket_arg_token];
            const bracket_arg = ast.source[bracket_arg_span.start..bracket_arg_span.end];
            const brace_arg_token = ast.nodes.items(.token)[full_node.brace_arg];
            const brace_arg_span = ast.tokens.items(.span)[brace_arg_token];
            const brace_arg = ast.source[brace_arg_span.start..brace_arg_span.end];

            if (state == .literal) {
                try writer.print("\\{s}", .{command_name});
                if (full_node.bracket_arg != 0) {
                    try writer.print("[{s}]", .{bracket_arg});
                }
                if (full_node.brace_arg != 0) {
                    try writer.print("{{{s}}}", .{brace_arg});
                }

                try writer.print(" ", .{});
                return;
            }

            if (std.mem.eql(u8, command_name, "section")) {
                try writer.print("<h1>{s}</h1>\n\n", .{brace_arg});
            }
            if (std.mem.eql(u8, command_name, "subsection")) {
                try writer.print("<h2>{s}</h2>\n\n", .{brace_arg});
            }
        },

        .environment => {
            const full_node = Ast.FullNode.Environment.init(current_node, ast);
            const env_name_span = ast.tokens.items(.span)[full_node.token];
            const env_name = ast.source[env_name_span.start..env_name_span.end];

            var children_state: State = .start;

            const LocalState = enum {
                start,
                display_mode,
                para,
                definition,
            };

            var local_state: LocalState = .start;

            if (state != .no_surround) {
                if (std.mem.eql(u8, env_name, "equation") or
                    std.mem.eql(u8, env_name, "equation*") or
                    std.mem.eql(u8, env_name, "align") or
                    std.mem.eql(u8, env_name, "align*"))
                {
                    local_state = .display_mode;
                } else if (std.mem.eql(u8, env_name, "para")) {
                    local_state = .para;
                } else if (std.mem.eql(u8, env_name, "definition")) {
                    local_state = .definition;
                }
            }

            switch (local_state) {
                .start => {
                    try writer.print("<p className=\"{s}\">", .{env_name});
                },
                .display_mode => {
                    try writer.print("<DisplayMath str={{String.raw`", .{});
                    children_state = .literal;
                },
                .para => {
                    try writer.print("<Para num={{getAndIncrement()}}>\n", .{});
                    children_state = .raw_input_suppress_p;
                },
                .definition => {
                    try writer.print("\n<Definition num={{getAndIncrement()}}>\n", .{});
                    children_state = .raw_input_suppress_p;
                },
            }

            const children = ast.extra_data.items[full_node.extra_data_range_start..full_node.extra_data_range_end];
            for (children) |child| {
                try walk(ast, child, children_state, indent_level + 1, writer);
            }

            switch (local_state) {
                .start => {
                    try writer.print("</p>\n", .{});
                },
                .display_mode => {
                    try writer.print("`}} />\n", .{});
                },
                .para => {
                    try writer.print("</Para>\n", .{});
                },
                .definition => {
                    try writer.print("</Definition>\n\n", .{});
                },
            }
        },

        else => {},
    }
}
