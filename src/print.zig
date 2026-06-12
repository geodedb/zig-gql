const std = @import("std");
const ast = @import("ast.zig");
const temporal = @import("temporal.zig");

// Known limitations:
// - Temporal normalization does not walk into InSubquery/NotInSubquery expressions
// - printProgramHumanWith has an else => {} catch-all for unhandled statement types

pub const PrintOptions = struct {
    normalize_temporals: bool = false,
    clamp_frac_digits: ?u8 = null,
    /// P2-3: Allocator for temporary allocations during printing (required when normalize_temporals=true)
    allocator: ?std.mem.Allocator = null,
};

pub fn printProgramHuman(w: anytype, prog: ast.Program) !void {
    return printProgramHumanWith(w, prog, .{});
}

pub fn printProgramHumanWith(w: anytype, prog: ast.Program, opts: PrintOptions) !void {
    try w.print("Program:\n", .{});
    for (prog.statements, 0..) |st, i| {
        try w.print("  [{d}] {s}\n", .{ i, tagName(st) });
        switch (st) {
            .Query => |q| try printQueryWith(w, q, 4, opts),
            .Union => |u| {
                try w.print("    Union:\n", .{});
                try w.print("      First ->\n", .{});
                try printQueryWith(w, u.first, 8, opts);
                for (u.tails, 0..) |p, j| {
                    try w.print("      Tail[{d}] all={any} distinct={any} ->\n", .{ j, p.all, p.distinct });
                    try printQueryWith(w, p.query, 8, opts);
                }
            },
            else => {},
        }
    }
}

pub const PrintJsonOptions = struct { verbose_temporals: bool = false, session_offset_minutes: ?i16 = null };

/// P2-3: Static GPA for convenience wrapper
var print_gpa: std.heap.DebugAllocator(.{}) = .init;
var print_gpa_init = false;
/// Mutex guarding the global GPA to ensure thread-safe access when
/// printProgramJson is called concurrently from parallel pipelines.
var print_gpa_mutex: std.Thread.Mutex = .{};

pub fn printProgramJson(w: anytype, prog: ast.Program) !void {
    // Guard GPA initialization and allocator retrieval with a mutex so
    // concurrent callers do not race on the lazy-init flag or the GPA
    // internal state.
    print_gpa_mutex.lock();
    if (!print_gpa_init) {
        print_gpa_init = true;
    }
    const alloc = print_gpa.allocator();
    print_gpa_mutex.unlock();
    return printProgramJsonWith(alloc, w, prog, .{});
}

/// P2-3: Now accepts allocator parameter for temporary allocations
pub fn printProgramJsonWith(allocator: std.mem.Allocator, w: anytype, prog: ast.Program, jopts: PrintJsonOptions) !void {
    try w.writeByte('{');

    var first = true;
    if (jopts.session_offset_minutes) |som| {
        try w.print("\"session_offset_minutes\":{d}", .{som});
        first = false;
    }

    if (!first) try w.writeByte(',');
    try w.writeAll("\"statements\":[");
    for (prog.statements, 0..) |st, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"kind\":\"{s}\"}}", .{tagName(st)});
    }
    try w.writeByte(']');

    if (jopts.verbose_temporals) {
        try w.writeAll(",\"temporals\":[");
        // P2-3: Use provided allocator instead of page_allocator
        var list = try collectTemporalsList(allocator, prog);
        defer list.deinit(allocator);

        for (list.items, 0..) |ent, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('{');

            // Write kind
            try w.writeAll("\"kind\":\"");
            switch (ent) {
                .Date => try w.writeAll("Date"),
                .Time => try w.writeAll("Time"),
                .DateTime => try w.writeAll("DateTime"),
                .LocalDateTime => try w.writeAll("LocalDateTime"),
            }
            try w.writeAll("\",");

            // Write raw
            try w.writeAll("\"raw\":\"");
            switch (ent) {
                .Date => |d| try w.writeAll(d.raw),
                .Time => |t| try w.writeAll(t.raw),
                .DateTime => |dt| try w.writeAll(dt.raw),
                .LocalDateTime => |ldt| try w.writeAll(ldt.raw),
            }
            try w.writeAll("\",");

            // Write parsed
            try w.writeAll("\"parsed\":{");
            switch (ent) {
                .Date => |d| {
                    try w.print("\"y\":{d},\"m\":{d},\"d\":{d}", .{ d.y, d.m, d.d });
                },
                .Time => |t| {
                    try w.print("\"h\":{d},\"min\":{d},\"s\":{d},", .{ t.h, t.min, t.s });
                    try w.print("\"has_seconds\":{},\"has_fraction\":{},", .{ t.has_seconds, t.has_fraction });
                    try w.print("\"frac_nanos\":{d},\"frac_digits\":{d},", .{ t.frac_nanos, t.frac_digits });
                    try w.writeAll("\"offset_minutes\":");
                    if (t.offset_minutes) |om| {
                        try w.print("{d}", .{om});
                    } else {
                        try w.writeAll("null");
                    }
                },
                .DateTime => |dt| {
                    try w.writeAll("\"date\":{");
                    try w.print("\"y\":{d},\"m\":{d},\"d\":{d}", .{ dt.date.y, dt.date.m, dt.date.d });
                    try w.writeAll("},\"time\":{");
                    try w.print("\"h\":{d},\"min\":{d},\"s\":{d},", .{ dt.time.h, dt.time.min, dt.time.s });
                    try w.print("\"has_seconds\":{},\"has_fraction\":{},", .{ dt.time.has_seconds, dt.time.has_fraction });
                    try w.print("\"frac_nanos\":{d},\"frac_digits\":{d},", .{ dt.time.frac_nanos, dt.time.frac_digits });
                    try w.writeAll("\"offset_minutes\":");
                    if (dt.time.offset_minutes) |om| {
                        try w.print("{d}", .{om});
                    } else {
                        try w.writeAll("null");
                    }
                    try w.writeByte('}');
                },
                .LocalDateTime => |ldt| {
                    try w.writeAll("\"date\":{");
                    try w.print("\"y\":{d},\"m\":{d},\"d\":{d}", .{ ldt.date.y, ldt.date.m, ldt.date.d });
                    try w.writeAll("},\"time\":{");
                    try w.print("\"h\":{d},\"min\":{d},\"s\":{d},", .{ ldt.time.h, ldt.time.min, ldt.time.s });
                    try w.print("\"has_seconds\":{},\"has_fraction\":{},", .{ ldt.time.has_seconds, ldt.time.has_fraction });
                    try w.print("\"frac_nanos\":{d},\"frac_digits\":{d},", .{ ldt.time.frac_nanos, ldt.time.frac_digits });
                    try w.writeAll("\"offset_minutes\":");
                    if (ldt.time.offset_minutes) |om| {
                        try w.print("{d}", .{om});
                    } else {
                        try w.writeAll("null");
                    }
                    try w.writeByte('}');
                },
            }
            try w.writeAll("}}");
        }
        try w.writeByte(']');
    }

    try w.writeByte('}');
}

fn tagName(st: ast.Statement) []const u8 {
    return switch (st) {
        .Query => "Query",
        .Union => "Union",
        .Intersect => "Intersect",
        .Except => "Except",
        .SessionSet => "SessionSet",
        .SessionReset => "SessionReset",
        .SessionClose => "SessionClose",
        .StartTransaction => "StartTransaction",
        .Commit => "Commit",
        .Rollback => "Rollback",
        .InsertValue => "InsertValue",
        .Insert => "Insert",
        .ScanValues => "ScanValues",
        .Create => "Create",
        .Delete => "Delete",
        .Merge => "Merge",
        .Call => "Call",
        .CreateIndex => "CreateIndex",
        .DropIndex => "DropIndex",
        .CreateConstraint => "CreateConstraint",
        .DropConstraint => "DropConstraint",
        .Show => "Show",
        .Backup => "Backup",
        .Restore => "Restore",
        .CreateSchema => "CreateSchema",
        .DropSchema => "DropSchema",
        .CreateGraph => "CreateGraph",
        .DropGraph => "DropGraph",
        .CreateGraphType => "CreateGraphType",
        .DropGraphType => "DropGraphType",
        .UseGraph => "UseGraph",
        .Explain => "Explain",
        .Profile => "Profile",
        .For => "For",
        .Values => "Values",
    };
}

fn indent(w: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeByte(' ');
}

const TemporalEntry = union(enum) {
    Date: temporal.Date,
    Time: temporal.Time,
    DateTime: temporal.DateTime,
    LocalDateTime: temporal.DateTime,
};

fn collectTemporalsList(allocator: std.mem.Allocator, prog: ast.Program) !std.ArrayList(TemporalEntry) {
    var list = std.ArrayList(TemporalEntry).initCapacity(allocator, 0) catch return error.OutOfMemory;
    const self = struct {
        fn walkStmt(ally_inner: std.mem.Allocator, dst: *std.ArrayList(TemporalEntry), st: ast.Statement) !void {
            switch (st) {
                .Query => |q| try walkQuery(ally_inner, dst, q),
                .Union => |u| {
                    try walkQuery(ally_inner, dst, u.first);
                    for (u.tails) |p| try walkQuery(ally_inner, dst, p.query);
                },
                else => {},
            }
        }
        fn walkQuery(ally_inner: std.mem.Allocator, dst: *std.ArrayList(TemporalEntry), q: ast.Query) !void {
            if (q.where_clause) |e| try walkExpr(ally_inner, dst, e);
            if (q.filter_clause) |e| try walkExpr(ally_inner, dst, e);
            if (q.with_clause) |wth| for (wth.items) |it| try walkExpr(ally_inner, dst, it.expr);
            if (q.group_by) |gb| for (gb.keys) |k| try walkExpr(ally_inner, dst, k);
            if (q.having) |hv| try walkExpr(ally_inner, dst, hv);
            for (q.ret.items) |it| try walkExpr(ally_inner, dst, it.expr);
            if (q.order_by) |ob| for (ob.keys) |k| try walkExpr(ally_inner, dst, k.expr);
        }
        fn walkExpr(ally_inner: std.mem.Allocator, dst: *std.ArrayList(TemporalEntry), e: ast.Expr) !void {
            switch (e) {
                .Date => |d| try dst.append(ally_inner, .{ .Date = d.parsed }),
                .Time => |t| try dst.append(ally_inner, .{ .Time = t.parsed }),
                .DateTime => |dt| try dst.append(ally_inner, .{ .DateTime = dt.parsed }),
                .LocalDateTime => |ldt| try dst.append(ally_inner, .{ .LocalDateTime = ldt.parsed }),
                .Unary => |u| try walkExpr(ally_inner, dst, u.expr.*),
                .Binary => |b| {
                    try walkExpr(ally_inner, dst, b.left.*);
                    try walkExpr(ally_inner, dst, b.right.*);
                },
                .Member => |m| try walkExpr(ally_inner, dst, m.target.*),
                .PropertyAccess => {}, // No nested expressions to walk
                .Index => |idx| {
                    try walkExpr(ally_inner, dst, idx.target.*);
                    try walkExpr(ally_inner, dst, idx.index.*);
                },
                .Slice => |slice| {
                    try walkExpr(ally_inner, dst, slice.target.*);
                    if (slice.start) |start| try walkExpr(ally_inner, dst, start.*);
                    if (slice.end) |end| try walkExpr(ally_inner, dst, end.*);
                },
                .Call => |c| {
                    try walkExpr(ally_inner, dst, c.callee.*);
                    for (c.args) |a| try walkExpr(ally_inner, dst, a.*);
                },
                .List => |items| for (items) |it| try walkExpr(ally_inner, dst, it.*),
                .In => |inn| {
                    try walkExpr(ally_inner, dst, inn.value.*);
                    for (inn.set) |it| try walkExpr(ally_inner, dst, it.*);
                },
                .InSubquery => |isq| {
                    try walkExpr(ally_inner, dst, isq.value.*);
                    // Note: subquery walking not implemented yet
                },
                .InListExpr => |ile| {
                    try walkExpr(ally_inner, dst, ile.value.*);
                    try walkExpr(ally_inner, dst, ile.list_expr.*);
                },
                .NotIn => |nin| {
                    try walkExpr(ally_inner, dst, nin.value.*);
                    for (nin.set) |it| try walkExpr(ally_inner, dst, it.*);
                },
                .NotInSubquery => |nisq| {
                    try walkExpr(ally_inner, dst, nisq.value.*);
                    // Note: subquery walking not implemented yet
                },
                .NotInListExpr => |nile| {
                    try walkExpr(ally_inner, dst, nile.value.*);
                    try walkExpr(ally_inner, dst, nile.list_expr.*);
                },
                .IsNull => |nz| try walkExpr(ally_inner, dst, nz.target.*),
                .Case => |c| {
                    if (c.operand) |op| try walkExpr(ally_inner, dst, op.*);
                    for (c.whens) |wh| {
                        try walkExpr(ally_inner, dst, wh.when.*);
                        try walkExpr(ally_inner, dst, wh.then_expr.*);
                    }
                    if (c.else_expr) |el| try walkExpr(ally_inner, dst, el.*);
                },
                .PatternComp => |pc| {
                    if (pc.where) |we| try walkExpr(ally_inner, dst, we.*);
                    try walkExpr(ally_inner, dst, pc.map.*);
                },
                .Exists => |ex| {
                    // Walk through the EXISTS where clause if present
                    if (ex.where) |we| try walkExpr(ally_inner, dst, we.*);
                },
                .HasLabel => |hl| {
                    // Label test doesn't contain sub-expressions
                    _ = hl;
                },
                else => {},
            }
        }
    };
    for (prog.statements) |st| try self.walkStmt(allocator, &list, st);
    return list;
}

pub fn printQueryWith(w: anytype, q: ast.Query, pad: usize, opts: PrintOptions) !void {
    try indent(w, pad);
    try w.print("Match optional={any}\n", .{q.optional_match});
    try printGraphPattern(w, q.match, pad + 2);
    if (q.where_clause) |we| {
        try indent(w, pad);
        try w.print("Where: ", .{});
        try printExprWith(w, we, 0, opts);
        try w.writeByte('\n');
    }
    if (q.filter_clause) |fe| {
        try indent(w, pad);
        try w.print("Filter: ", .{});
        try printExprWith(w, fe, 0, opts);
        try w.writeByte('\n');
    }
    if (q.with_clause) |wc| {
        try indent(w, pad);
        try w.print("With: ", .{});
        for (wc.items, 0..) |it, i| {
            if (i > 0) try w.print(", ", .{});
            try printExprWith(w, it.expr, 0, opts);
            if (it.alias) |a| try w.print(" AS {s}", .{a});
        }
        try w.writeByte('\n');
    }
    if (q.group_by) |gb| {
        try indent(w, pad);
        try w.print("GroupBy: ", .{});
        for (gb.keys, 0..) |k, i| {
            if (i > 0) try w.print(", ", .{});
            try printExprWith(w, k, 0, opts);
        }
        try w.writeByte('\n');
    }
    if (q.having) |hv| {
        try indent(w, pad);
        try w.print("Having: ", .{});
        try printExprWith(w, hv, 0, opts);
        try w.writeByte('\n');
    }
    try indent(w, pad);
    try w.print("Return{any}: ", .{q.ret.distinct});
    for (q.ret.items, 0..) |it, i| {
        if (i > 0) try w.print(", ", .{});
        try printExprWith(w, it.expr, 0, opts);
        if (it.alias) |a| try w.print(" AS {s}", .{a});
    }
    try w.writeByte('\n');
    if (q.order_by) |ob| {
        try indent(w, pad);
        try w.print("OrderBy: ", .{});
        for (ob.keys, 0..) |k, i| {
            if (i > 0) try w.print(", ", .{});
            try printExprWith(w, k.expr, 0, opts);
            try w.print(" {s}", .{if (k.desc) "DESC" else "ASC"});
            if (k.nulls != .default) {
                try w.print(" NULLS {s}", .{switch (k.nulls) {
                    .first => "FIRST",
                    .last => "LAST",
                    .default => "",
                }});
            }
        }
        try w.writeByte('\n');
    }
    if (q.limit) |lim| {
        try indent(w, pad);
        try w.print("Limit: {d}\n", .{lim});
    }
    if (q.offset) |ofs| {
        try indent(w, pad);
        try w.print("Offset: {d}\n", .{ofs});
    }
}

fn printGraphPattern(w: anytype, gp: ast.GraphPattern, pad: usize) !void {
    try indent(w, pad);
    try w.print("GraphPattern chains={d}\n", .{gp.chains.len});
    for (gp.chains, 0..) |ch, i| {
        try indent(w, pad + 2);
        try w.print("Chain[{d}]{s}{s}\n", .{ i, if (ch.name != null) ":" else "", if (ch.name) |n| n else "" });
        for (ch.hops, 0..) |hp, j| {
            try indent(w, pad + 4);
            try w.print("Hop[{d}] ", .{j});
            try printNode(w, hp.left);
            try w.print(" -", .{});
            try printRel(w, hp.rel);
            try w.print("-> ", .{});
            try printNode(w, hp.right);
            try w.writeByte('\n');
        }
    }
}

fn printNode(w: anytype, n: ast.NodePattern) !void {
    try w.writeByte('(');
    if (n.name) |nm| try w.print("{s}", .{nm});
    for (n.labels) |l| try w.print(":{s}", .{l});
    if (n.props != null) try w.print(" {{…}}", .{});
    try w.writeByte(')');
}

fn printRel(w: anytype, r: ast.RelPattern) !void {
    try w.writeByte('[');
    if (r.name) |nm| try w.print("{s}", .{nm});
    for (r.types) |t| try w.print(":{s}", .{t});
    // quantifier
    if (r.min_len != null or r.max_len != null) {
        try w.writeByte('*');
        if (r.min_len) |mn| try w.print("{d}", .{mn});
        if (r.max_len != null and (r.min_len == null or r.max_len.? != r.min_len.?)) {
            try w.print("..", .{});
            if (r.max_len) |mx| try w.print("{d}", .{mx});
        } else if (r.max_len == null and r.min_len != null) {
            try w.print("..", .{});
        }
    }
    if (r.props != null) try w.print(" {{…}}", .{});
    try w.writeByte(']');
}

pub fn printExpr(w: anytype, e: ast.Expr, prec: u8) !void {
    return printExprWith(w, e, prec, .{});
}

// Helper to stringify a single expression with options, for granular tests and utilities.
pub fn stringifyExprAlloc(allocator: std.mem.Allocator, e: ast.Expr, opts: PrintOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try printExprWith(&aw.writer, e, 0, opts);
    return aw.toOwnedSlice();
}

pub fn printExprWith(w: anytype, e: ast.Expr, prec: u8, opts: PrintOptions) !void {
    _ = prec;
    switch (e) {
        .Ident => |id| try w.print("{s}", .{id.orig}),
        .String => |s| try w.print("\"{s}\"", .{s}),
        .Int => |n| try w.print("{d}", .{n}),
        .Decimal => |d| blk_dec: {
            const neg = d.coeff < 0;
            const abs: i128 = if (neg) -d.coeff else d.coeff;
            var whole: i128 = abs;
            var frac: i128 = 0;
            if (d.scale > 0) {
                var i: u8 = 0;
                var p: i128 = 1;
                while (i < d.scale) : (i += 1) p *= 10;
                whole = @divTrunc(abs, p);
                frac = @mod(abs, p);
            }
            try w.print("{s}{d}", .{ if (neg) "-" else "", whole });
            if (d.scale > 0) {
                try w.writeByte('.');
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{frac}) catch unreachable;
                if (s.len < d.scale) {
                    var pad_i: u8 = 0;
                    while (pad_i < d.scale - s.len) : (pad_i += 1) try w.writeByte('0');
                }
                try w.print("{s}", .{s});
            }
            break :blk_dec;
        },
        .Bool => |b| try w.print("{any}", .{b}),
        .Null => try w.print("null", .{}),
        .Date => |d| if (!opts.normalize_temporals) {
            try w.print("DATE\"{s}\"", .{d.raw});
        } else {
            // P2-3: Use provided allocator instead of page_allocator
            const alloc = opts.allocator orelse return error.AllocatorRequired;
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            try temporal.formatDate(&aw.writer, d.parsed);
            try w.print("DATE\"{s}\"", .{aw.written()});
        },
        .DateTime => |dt| if (!opts.normalize_temporals) {
            try w.print("DATETIME\"{s}\"", .{dt.raw});
        } else {
            // P2-3: Use provided allocator instead of page_allocator
            const alloc = opts.allocator orelse return error.AllocatorRequired;
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            try temporal.formatDateTime(&aw.writer, dt.parsed, .{ .clamp_frac_digits = opts.clamp_frac_digits });
            try w.print("DATETIME\"{s}\"", .{aw.written()});
        },
        .Time => |t| if (!opts.normalize_temporals) {
            try w.print("TIME\"{s}\"", .{t.raw});
        } else {
            // P2-3: Use provided allocator instead of page_allocator
            const alloc = opts.allocator orelse return error.AllocatorRequired;
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            try temporal.formatTime(&aw.writer, t.parsed, .{ .clamp_frac_digits = opts.clamp_frac_digits });
            try w.print("TIME\"{s}\"", .{aw.written()});
        },
        .LocalDateTime => |ldt| if (!opts.normalize_temporals) {
            try w.print("LOCAL DATETIME\"{s}\"", .{ldt.raw});
        } else {
            // P2-3: Use provided allocator instead of page_allocator
            const alloc = opts.allocator orelse return error.AllocatorRequired;
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            try temporal.formatDateTime(&aw.writer, ldt.parsed, .{ .clamp_frac_digits = opts.clamp_frac_digits });
            try w.print("LOCAL DATETIME\"{s}\"", .{aw.written()});
        },
        .StartsWith => |sw| {
            try printExprWith(w, sw.value.*, 0, opts);
            try w.print(" STARTS WITH ", .{});
            try printExprWith(w, sw.prefix.*, 0, opts);
        },
        .EndsWith => |ew| {
            try printExprWith(w, ew.value.*, 0, opts);
            try w.print(" ENDS WITH ", .{});
            try printExprWith(w, ew.suffix.*, 0, opts);
        },
        .Contains => |co| {
            try printExprWith(w, co.value.*, 0, opts);
            try w.print(" CONTAINS ", .{});
            try printExprWith(w, co.needle.*, 0, opts);
        },
        .Param => |pname| {
            try w.print("${s}", .{pname});
        },
        .Case => |c| {
            try w.print("CASE ", .{});
            if (c.operand) |op| {
                try printExprWith(w, op.*, 0, opts);
                try w.writeByte(' ');
            }
            for (c.whens) |wh| {
                try w.print("WHEN ", .{});
                try printExprWith(w, wh.when.*, 0, opts);
                try w.print(" THEN ", .{});
                try printExprWith(w, wh.then_expr.*, 0, opts);
                try w.writeByte(' ');
            }
            if (c.else_expr) |el| {
                try w.print("ELSE ", .{});
                try printExprWith(w, el.*, 0, opts);
                try w.writeByte(' ');
            }
            try w.print("END", .{});
        },
        .Member => |m| {
            try printExprWith(w, m.target.*, 0, opts);
            try w.print(".{s}", .{m.field});
        },
        .PropertyAccess => |pa| {
            try w.print("{s}.{s}", .{ pa.object, pa.property });
        },
        .Index => |idx| {
            try printExprWith(w, idx.target.*, 0, opts);
            try w.print("[", .{});
            try printExprWith(w, idx.index.*, 0, opts);
            try w.print("]", .{});
        },
        .Slice => |slice| {
            try printExprWith(w, slice.target.*, 0, opts);
            try w.print("[", .{});
            if (slice.start) |start| {
                try printExprWith(w, start.*, 0, opts);
            }
            try w.print("..", .{});
            if (slice.end) |end| {
                try printExprWith(w, end.*, 0, opts);
            }
            try w.print("]", .{});
        },
        .Unary => |u| {
            switch (u.op) {
                .Not => try w.print("NOT ", .{}),
                .Neg => try w.print("-", .{}),
                .Pos => try w.print("+", .{}),
            }
            try printExprWith(w, u.expr.*, 0, opts);
        },
        .Binary => |b| {
            try printExprWith(w, b.left.*, 0, opts);
            const op = switch (b.op) {
                .And => " AND ",
                .Or => " OR ",
                .Xor => " XOR ",
                .Eq => " = ",
                .Ne => " <> ",
                .Lt => " < ",
                .Le => " <= ",
                .Gt => " > ",
                .Ge => " >= ",
                .Add => " + ",
                .Sub => " - ",
                .Mul => " * ",
                .Div => " / ",
                .Mod => " % ",
                .Power => " ^ ",
                .Concat => " || ",
                .RegexMatch => " =~ ",
                .RegexNotMatch => " !~ ",
            };
            try w.print("{s}", .{op});
            try printExprWith(w, b.right.*, 0, opts);
        },
        .Call => |c| {
            try printExprWith(w, c.callee.*, 0, opts);
            try w.writeByte('(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, a.*, 0, opts);
            }
            try w.writeByte(')');
        },
        .List => |items| {
            try w.writeByte('[');
            for (items, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, it.*, 0, opts);
            }
            try w.writeByte(']');
        },
        .In => |inn| {
            try printExprWith(w, inn.value.*, 0, opts);
            try w.print(" IN ", .{});
            try w.writeByte('[');
            for (inn.set, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, it.*, 0, opts);
            }
            try w.writeByte(']');
        },
        .InSubquery => |isq| {
            try printExprWith(w, isq.value.*, 0, opts);
            try w.print(" IN (subquery)", .{});
        },
        .InListExpr => |ile| {
            try printExprWith(w, ile.value.*, 0, opts);
            try w.print(" IN ", .{});
            try printExprWith(w, ile.list_expr.*, 0, opts);
        },
        .NotIn => |nin| {
            try printExprWith(w, nin.value.*, 0, opts);
            try w.print(" NOT IN ", .{});
            try w.writeByte('[');
            for (nin.set, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, it.*, 0, opts);
            }
            try w.writeByte(']');
        },
        .NotInSubquery => |nisq| {
            try printExprWith(w, nisq.value.*, 0, opts);
            try w.print(" NOT IN (subquery)", .{});
        },
        .NotInListExpr => |nile| {
            try printExprWith(w, nile.value.*, 0, opts);
            try w.print(" NOT IN ", .{});
            try printExprWith(w, nile.list_expr.*, 0, opts);
        },
        .IsNull => |nz| {
            try printExprWith(w, nz.target.*, 0, opts);
            if (nz.negated) {
                try w.print(" IS NOT NULL", .{});
            } else {
                try w.print(" IS NULL", .{});
            }
        },
        .IsUnknown => |uz| {
            try printExprWith(w, uz.target.*, 0, opts);
            if (uz.negated) {
                try w.print(" IS NOT UNKNOWN", .{});
            } else {
                try w.print(" IS UNKNOWN", .{});
            }
        },
        .Map => try w.print("{{…}}", .{}),
        .PatternComp => |pc| {
            if (pc.alias) |al| try w.print("{s} = ", .{al});
            try w.writeByte('[');
            try printGraphPattern(w, pc.pattern.*, 0);
            if (pc.where) |we| {
                try w.print(" WHERE ", .{});
                try printExprWith(w, we.*, 0, opts);
            }
            try w.print(" | ", .{});
            try printExprWith(w, pc.map.*, 0, opts);
            try w.writeByte(']');
        },
        .Exists => |ex| {
            try w.print("EXISTS {{ ", .{});
            try printGraphPattern(w, ex.pattern.*, 0);
            if (ex.where) |we| {
                try w.print(" WHERE ", .{});
                try printExprWith(w, we.*, 0, opts);
            }
            try w.print(" }}", .{});
        },
        .HasLabel => |hl| try w.print("{s}:{s}", .{ hl.node, hl.label }),
        .SmallIntLit => |i| try w.print("{d}", .{i}),
        .BigIntLit => |i| try w.print("{d}", .{i}),
        .RealLit => |f| try w.print("{d}", .{f}),
        .DoubleLit => |f| try w.print("{d}", .{f}),
        .CharLit => |c| try w.print("CHAR({d})\"{s}\"", .{ c.n, c.text }),
        .VarcharLit => |v| try w.print("VARCHAR({d})\"{s}\"", .{ v.n, v.text }),
        .TextLit => |t| try w.print("\"{s}\"", .{t}),
        .ByteaLit => |b| try w.print("BYTEA\"{s}\"", .{b}),
        .JsonLit => |j| try w.print("JSON\"{s}\"", .{j}),
        .JsonbLit => |j| try w.print("JSONB\"{s}\"", .{j}),
        .XmlLit => |x| try w.print("XML\"{s}\"", .{x}),
        .UrlLit => |u| try w.print("URL\"{s}\"", .{u}),
        .DomainLit => |d| try w.print("DOMAIN\"{s}\"", .{d}),
        .UuidLit => |u| try w.print("UUID\"{s}\"", .{u}),
        .EnumLit => |en| try w.print("{s}::{s}", .{ en.type_name, en.value }),
        .ArrayLit => |items| {
            try w.writeByte('[');
            for (items, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, it.*, 0, opts);
            }
            try w.writeByte(']');
        },
        .BitLit => |bits| try w.print("B\"{s}\"", .{bits}),
        .VarBitLit => |bits| try w.print("VARBIT\"{s}\"", .{bits}),
        .ShortestPath => |sp| {
            if (sp.all) {
                try w.print("allShortestPaths(", .{});
            } else {
                try w.print("shortestPath(", .{});
            }
            try printGraphPattern(w, sp.pattern.*, 0);
            try w.print(")", .{});
        },
        .PatternCount => |pc| {
            try w.print("COUNT {{ ", .{});
            try printGraphPattern(w, pc.pattern.*, 0);
            if (pc.where) |where_expr| {
                try w.print(" WHERE ", .{});
                try printExprWith(w, where_expr.*, 0, opts);
            }
            try w.print(" }}", .{});
        },
        .MapProjection => |mp| {
            try printExprWith(w, mp.source.*, 0, opts);
            try w.print(" {{", .{});
            for (mp.fields, 0..) |field, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print(".{s}", .{field});
            }
            try w.print("}}", .{});
        },
        // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Printing; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=print; UPDATED=2025-10-14
        .ListComprehension => |lc| {
            try w.print("{s} IN ", .{lc.variable});
            try printExprWith(w, lc.source.*, 0, opts);
            if (lc.filter) |filter| {
                try w.print(" WHERE ", .{});
                try printExprWith(w, filter.*, 0, opts);
            }
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "printProgramHuman produces output for empty program" {
    const prog = ast.Program{ .statements = &.{} };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printProgramHuman(&aw.writer, prog);
    try std.testing.expect(aw.written().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Program:") != null);
}

test "printProgramJsonWith produces valid JSON for empty program" {
    const prog = ast.Program{ .statements = &.{} };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printProgramJsonWith(std.testing.allocator, &aw.writer, prog, .{});
    const out = aw.written();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"statements\"") != null);
    // Verify it starts with { and ends with }
    try std.testing.expectEqual(@as(u8, '{'), out[0]);
    try std.testing.expectEqual(@as(u8, '}'), out[out.len - 1]);
}

test "printProgramHuman outputs Commit statement" {
    var stmts = [_]ast.Statement{.Commit};
    const prog = ast.Program{ .statements = &stmts };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printProgramHuman(&aw.writer, prog);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Program:") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "[0]") != null);
}

test "printProgramHuman outputs Rollback statement" {
    var stmts = [_]ast.Statement{.Rollback};
    const prog = ast.Program{ .statements = &stmts };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printProgramHuman(&aw.writer, prog);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Program:") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Rollback") != null);
}

test "printProgramJsonWith outputs Commit and Rollback in JSON" {
    var stmts = [_]ast.Statement{ .Commit, .Rollback };
    const prog = ast.Program{ .statements = &stmts };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printProgramJsonWith(std.testing.allocator, &aw.writer, prog, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"statements\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"Commit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"Rollback\"") != null);
}
