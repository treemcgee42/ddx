const std = @import("std");
const Ast = @import("parser/Ast.zig");

pub const State = enum {
    start,
    /// Print the LaTeX as it was when parsed.
    literal,
    /// Don't print surrounding `<p>` and `</p>`.
    raw_input_suppress_p,
    /// For printing a grouping, don't print the surrounding braces.
    grouping_of_section,
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

            if (state == .literal or state == .raw_input_suppress_p or state == .no_surround) {
                try writer.print(" {s} ", .{source});
            } else {
                try writer.print("<p>{s}</p>\n", .{source});
            }
        },

        .inline_math => {
            const full_node = Ast.FullNode.InlineMath.init(current_node, ast);
            const children = ast.extra_data.items[full_node.extra_data_range_start..full_node.extra_data_range_end];

            try writer.print(" <InlineMath str={{String.raw`", .{});

            for (children) |child| {
                try walk(ast, child, .literal, indent_level, writer);
            }

            try writer.print("`}} /> ", .{});
        },

        .command => {
            const full_node = Ast.FullNode.Command.init(current_node, ast);

            const command_name_span = ast.tokens.items(.span)[full_node.token];
            const command_name = ast.source[command_name_span.start + 1 .. command_name_span.end];

            if (state == .literal) {
                try writer.print("\\{s}", .{command_name});

                // BRACE ARGS.

                var brace_i = full_node.brace_args.lhs;
                while (brace_i < full_node.brace_args.rhs) : (brace_i += 1) {
                    const brace_arg_node = ast.extra_data.items[brace_i];
                    const brace_arg_full_node = Ast.FullNode.Grouping.init(brace_arg_node, ast);

                    try writer.print("{{", .{});

                    const children = ast.extra_data.items[brace_arg_full_node.lhs..brace_arg_full_node.rhs];
                    for (children) |child| {
                        try walk(ast, child, .literal, indent_level, writer);
                    }

                    try writer.print("}}", .{});
                }

                // BRACKET ARGS.

                var bracket_i = full_node.bracket_args.lhs;
                while (bracket_i < full_node.bracket_args.rhs) : (bracket_i += 1) {
                    const bracket_arg_node = ast.extra_data.items[bracket_i];
                    const bracket_arg_full_node = Ast.FullNode.Grouping.init(bracket_arg_node, ast);

                    try writer.print("[", .{});

                    const children = ast.extra_data.items[bracket_arg_full_node.lhs..bracket_arg_full_node.rhs];
                    for (children) |child| {
                        try walk(ast, child, .literal, indent_level, writer);
                    }

                    try writer.print("]", .{});
                }

                try writer.print(" ", .{});
                return;
            }

            const braces_node = ast.nodes.items(.lhs)[current_node];
            var pending = "     ".*;

            if (std.mem.eql(u8, command_name, "section")) {
                try writer.print("<h1>", .{});
                pending = "</h1>".*;
            } else if (std.mem.eql(u8, command_name, "subsection")) {
                try writer.print("<h2>", .{});
                pending = "</h2>".*;
            }

            try walk(ast, braces_node, .grouping_of_section, 0, writer);

            try writer.print("{s}\n\n", .{pending[0..]});
        },

        .environment => {
            const full_node = Ast.FullNode.Environment.init(current_node, ast);
            const env_name_span = ast.tokens.items(.span)[full_node.token];
            const env_name = ast.source[env_name_span.start..env_name_span.end];

            var children_state: State = .start;

            const LocalState = enum {
                start,
                display_mode,
                gather,
                align_,
                para,
                definition,
                remark,
                proposition,
                proof,
            };

            var local_state: LocalState = .start;

            if (state != .no_surround) {
                if (std.mem.eql(u8, env_name, "equation") or
                    std.mem.eql(u8, env_name, "equation*"))
                {
                    local_state = .display_mode;
                } else if (std.mem.eql(u8, env_name, "align") or
                    std.mem.eql(u8, env_name, "align*"))
                {
                    local_state = .align_;
                } else if (std.mem.eql(u8, env_name, "gather") or
                    std.mem.eql(u8, env_name, "gather*"))
                {
                    local_state = .gather;
                } else if (std.mem.eql(u8, env_name, "para")) {
                    local_state = .para;
                } else if (std.mem.eql(u8, env_name, "definition")) {
                    local_state = .definition;
                } else if (std.mem.eql(u8, env_name, "remark")) {
                    local_state = .remark;
                } else if (std.mem.eql(u8, env_name, "proposition")) {
                    local_state = .proposition;
                } else if (std.mem.eql(u8, env_name, "proof")) {
                    local_state = .proof;
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
                .align_ => {
                    try writer.print("<Align str={{String.raw`", .{});
                    children_state = .literal;
                },
                .gather => {
                    try writer.print("<Gather str={{String.raw`", .{});
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
                .remark => {
                    try writer.print("\n<Remark num={{getAndIncrement()}}>\n", .{});
                    children_state = .raw_input_suppress_p;
                },
                .proposition => {
                    try writer.print("\n<Proposition num={{getAndIncrement()}}>\n", .{});
                    children_state = .raw_input_suppress_p;
                },
                .proof => {
                    try writer.print("\n<Proof>\n", .{});
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
                .align_ => {
                    try writer.print("`}} />\n", .{});
                },
                .gather => {
                    try writer.print("`}} />\n", .{});
                },
                .para => {
                    try writer.print("</Para>\n", .{});
                },
                .definition => {
                    try writer.print("</Definition>\n\n", .{});
                },
                .remark => {
                    try writer.print("</Remark>\n\n", .{});
                },
                .proposition => {
                    try writer.print("</Proposition>\n\n", .{});
                },
                .proof => {
                    try writer.print("</Proof>\n\n", .{});
                },
            }
        },

        .underscore => {
            try writer.print("_", .{});

            const full_node = Ast.FullNode.Underscore.init(current_node, ast);
            try walk(ast, full_node.arg, state, indent_level, writer);
        },

        .grouping => {
            const full_node = Ast.FullNode.Grouping.init(current_node, ast);

            const LocalState = enum {
                start,
                brace,
                bracket,
            };
            var local_state: LocalState = .start;

            if (state != .grouping_of_section and state != .no_surround) {
                switch (ast.tokens.items(.kind)[full_node.token]) {
                    .LBrace => {
                        local_state = .brace;
                        try writer.print("{{", .{});
                    },

                    .LBracket => {
                        local_state = .bracket;
                        try writer.print("[", .{});
                    },

                    .underscore => {},

                    else => {
                        unreachable;
                    },
                }
            }

            var child_state = state;
            if (state == .grouping_of_section) {
                child_state = .no_surround;
            }

            var i = full_node.lhs;
            while (i < full_node.rhs) : (i += 1) {
                const node = ast.extra_data.items[i];
                try walk(ast, node, child_state, indent_level, writer);
            }

            switch (local_state) {
                .brace => {
                    try writer.print("}}", .{});
                },

                .bracket => {
                    try writer.print("]]", .{});
                },

                else => {},
            }
        },

        .caret => {
            try writer.print("^", .{});

            const full_node = Ast.FullNode.Caret.init(current_node, ast);
            try walk(ast, full_node.arg, state, indent_level, writer);
        },

        else => {
            std.debug.print("unimplemented: {}\n", .{ast.nodes.items(.kind)[current_node]});
        },
    }
}
