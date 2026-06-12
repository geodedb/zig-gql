const std = @import("std");
const t = @import("token.zig");
const temporal = @import("temporal.zig");

pub const Lexer = struct {
    src: []const u8,
    idx: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    has_double_solidus_comment: bool = false,
    has_double_dash_comment: bool = false,
    unterminated_comment: bool = false,

    pub fn next(self: *Lexer) t.Token {
        self.skipSeparators();
        if (self.unterminated_comment) {
            self.unterminated_comment = false;
            return self.mkTok(.invalid, 0);
        }
        if (self.idx >= self.src.len) return self.mkTok(.eof, 0);

        const c = self.peek();

        // Handle quotes first before other matching to avoid issues
        if (c == '\'') return self.scanStringAny(c);
        if (c == '"') {
            // For now, treat double quotes same as single quotes to avoid hangs
            // This is a temporary fix until proper double quote handling is implemented
            return self.scanStringAny('"');
        }

        if (self.matchMulti()) |tokv| return tokn(tokv);

        // Check for Unicode identifier start (or ASCII)
        if (c < 128) {
            if (t.isIdentifierStart(@intCast(c))) return self.scanIdentifierOrKeyword();
            if (t.isDigit(c)) return self.scanNumeric();
        } else {
            // Potential Unicode identifier - decode manually to avoid std lib assertions
            const cp = decodeUtf8Codepoint(self.src, self.idx) orelse {
                // Invalid UTF-8, treat as invalid token
                self.advance();
                return self.mkTok(.invalid, 1);
            };
            if (t.isIdentifierStart(cp)) return self.scanIdentifierOrKeyword();
            if (t.isUnicodeDigit(cp)) return self.scanNumeric();
        }

        if (self.matchSingle()) |tokv| return tokn(tokv);

        // invalid byte
        self.advance();
        return self.mkTok(.invalid, 1);
    }

    fn tokn(tokv: t.Token) t.Token {
        return tokv;
    }

    fn peek(self: *Lexer) u8 {
        return self.src[self.idx];
    }

    fn advance(self: *Lexer) void {
        const c = self.src[self.idx];
        self.idx += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else self.col += 1;
    }

    fn mkTok(self: *Lexer, kind: t.TokenKind, len: usize) t.Token {
        const start = self.idx;
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        self.idx += len;
        self.col += @as(u32, @intCast(len));
        return .{ .kind = kind, .lexeme = self.src[start .. start + len], .loc = loc };
    }

    fn skipSeparators(self: *Lexer) void {
        while (self.idx < self.src.len) {
            const c = self.src[self.idx];
            // whitespace
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.advance();
                continue;
            }
            // multi-line comment: /* ... */
            if (c == '/' and self.idx + 1 < self.src.len and self.src[self.idx + 1] == '*') {
                self.idx += 2;
                self.col += 2;
                var found_end = false;
                while (self.idx + 1 < self.src.len) {
                    if (self.src[self.idx] == '*' and self.src[self.idx + 1] == '/') {
                        self.idx += 2;
                        self.col += 2;
                        found_end = true;
                        break;
                    }
                    self.advance();
                }
                if (!found_end) {
                    // Consume any remaining byte so we reach EOF
                    if (self.idx < self.src.len) self.advance();
                    self.unterminated_comment = true;
                    return;
                }
                continue;
            }
            // single-line comment: // ...
            if (c == '/' and self.idx + 1 < self.src.len and self.src[self.idx + 1] == '/') {
                self.has_double_solidus_comment = true;
                while (self.idx < self.src.len and self.src[self.idx] != '\n') self.advance();
                continue;
            }
            // double-dash comment: -- ...
            if (c == '-' and self.idx + 1 < self.src.len and self.src[self.idx + 1] == '-') {
                // If pattern context (e.g. "--(" or "--["), do not treat as comment
                if (self.idx + 2 < self.src.len and (self.src[self.idx + 2] == '(' or self.src[self.idx + 2] == '[')) {
                    break;
                }
                // Mark that we found a double-dash comment (which is disabled per GB02)
                self.has_double_dash_comment = true;
                while (self.idx < self.src.len and self.src[self.idx] != '\n') self.advance();
                continue;
            }

            break;
        }
    }

    fn matchMulti(self: *Lexer) ?t.Token {
        const remain = self.src[self.idx..];
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        // ->
        if (remain.len >= 2 and remain[0] == '-' and remain[1] == '>') {
            const tokv: t.Token = .{ .kind = .arrow_r, .lexeme = remain[0..2], .loc = loc };
            self.idx += 2;
            self.col += 2;
            return tokv;
        }
        // <-
        if (remain.len >= 2 and remain[0] == '<' and remain[1] == '-') {
            const tokv: t.Token = .{ .kind = .arrow_l, .lexeme = remain[0..2], .loc = loc };
            self.idx += 2;
            self.col += 2;
            return tokv;
        }
        // =>
        if (remain.len >= 2 and remain[0] == '=' and remain[1] == '>') {
            const tokv: t.Token = .{ .kind = .double_arrow, .lexeme = remain[0..2], .loc = loc };
            self.idx += 2;
            self.col += 2;
            return tokv;
        }
        // ||
        if (remain.len >= 2 and remain[0] == '|' and remain[1] == '|') {
            const tokv: t.Token = .{ .kind = .concat, .lexeme = remain[0..2], .loc = loc };
            self.idx += 2;
            self.col += 2;
            return tokv;
        }
        // <=, >=, <>, !=, ..
        if (remain.len >= 2) switch (remain[0]) {
            '<' => switch (remain[1]) {
                '=' => {
                    const tokv: t.Token = .{ .kind = .le, .lexeme = remain[0..2], .loc = loc };
                    self.idx += 2;
                    self.col += 2;
                    return tokv;
                },
                '>' => {
                    const tokv: t.Token = .{ .kind = .ne, .lexeme = remain[0..2], .loc = loc };
                    self.idx += 2;
                    self.col += 2;
                    return tokv;
                },
                else => {},
            },
            '>' => if (remain[1] == '=') {
                const tokv: t.Token = .{ .kind = .ge, .lexeme = remain[0..2], .loc = loc };
                self.idx += 2;
                self.col += 2;
                return tokv;
            },
            '=' => if (remain[1] == '~') {
                const tokv: t.Token = .{ .kind = .regex_match, .lexeme = remain[0..2], .loc = loc };
                self.idx += 2;
                self.col += 2;
                return tokv;
            },
            '!' => switch (remain[1]) {
                '=' => {
                    const tokv: t.Token = .{ .kind = .ne, .lexeme = remain[0..2], .loc = loc };
                    self.idx += 2;
                    self.col += 2;
                    return tokv;
                },
                '~' => {
                    const tokv: t.Token = .{ .kind = .regex_not_match, .lexeme = remain[0..2], .loc = loc };
                    self.idx += 2;
                    self.col += 2;
                    return tokv;
                },
                else => {},
            },
            '.' => if (remain[1] == '.') {
                const tokv: t.Token = .{ .kind = .dotdot, .lexeme = remain[0..2], .loc = loc };
                self.idx += 2;
                self.col += 2;
                return tokv;
            },
            else => {},
        };
        return null;
    }

    fn matchSingle(self: *Lexer) ?t.Token {
        const c = self.peek();
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const tokv: t.Token = switch (c) {
            '|' => .{ .kind = .bar, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '$' => .{ .kind = .dollar, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '(' => .{ .kind = .l_paren, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ')' => .{ .kind = .r_paren, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '[' => .{ .kind = .l_bracket, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ']' => .{ .kind = .r_bracket, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '{' => .{ .kind = .l_brace, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '}' => .{ .kind = .r_brace, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ',' => .{ .kind = .comma, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ':' => .{ .kind = .colon, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ';' => .{ .kind = .semicolon, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '.' => .{ .kind = .dot, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '+' => .{ .kind = .plus, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '-' => .{ .kind = .minus, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '*' => .{ .kind = .star, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '/' => .{ .kind = .slash, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '%' => .{ .kind = .percent, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '<' => .{ .kind = .lt, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '>' => .{ .kind = .gt, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '=' => .{ .kind = .eq, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '@' => .{ .kind = .at, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '^' => .{ .kind = .caret, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            else => return null,
        };
        self.idx += 1;
        self.col += 1;
        return tokv;
    }

    fn scanIdentifierOrKeyword(self: *Lexer) t.Token {
        const start = self.idx;
        const loc: t.Location = .{ .line = self.line, .column = self.col };

        // Handle Unicode identifiers - read UTF-8 code points. The iterator
        // already advances by each codepoint's byte length, so derive the
        // consumed-byte count from `iter.i` rather than re-decoding the lead
        // byte's sequence length on every codepoint (PERF-107).
        var iter = std.unicode.Utf8Iterator{ .bytes = self.src[self.idx..], .i = 0 };
        var first = true;
        var consumed: usize = 0;

        while (iter.nextCodepoint()) |cp| {
            const ok = if (first) t.isIdentifierStart(cp) else t.isIdentifierContinue(cp);
            if (!ok) break;
            first = false;
            consumed = iter.i; // bytes confirmed as part of the identifier so far
            self.col += 1;
        }
        self.idx += consumed;
        const slice = self.src[start..self.idx];
        // case-insensitive keyword mapping
        const kind = t.keywordKind(slice);
        // Special handling for typed temporal literals: DATE"..." / DATETIME"..." / TIME"..." / LOCAL DATETIME"..."
        if (kind == .DATE or kind == .DATETIME or kind == .TIME) {
            const save_idx = self.idx;
            const save_line = self.line;
            const save_col = self.col;
            self.skipSeparators();
            if (self.idx < self.src.len and (self.src[self.idx] == '"' or self.src[self.idx] == '\'')) {
                const quote = self.src[self.idx];
                const str = self.scanStringAny(quote);
                if (kind == .DATE and !temporal.isDateStrict(str.lexeme)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                if (kind == .DATETIME and !temporal.isDateTimeIso(str.lexeme, true)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                if (kind == .TIME and !temporal.isTimeIso(str.lexeme, true)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                // Return the literal type (not the keyword type) for temporal literals
                const lit_kind: t.TokenKind = if (kind == .DATE) .date_lit else if (kind == .DATETIME) .datetime_lit else .time_lit;
                return .{ .kind = lit_kind, .lexeme = str.lexeme, .loc = str.loc };
            }
            // No following string: not a typed literal; return as keyword
            self.idx = save_idx;
            self.line = save_line;
            self.col = save_col;
            return .{ .kind = kind, .lexeme = slice, .loc = loc };
        }
        if (kind == .LOCAL) {
            // Check for LOCAL DATETIME"..." pattern
            const save_idx = self.idx;
            const save_line = self.line;
            const save_col = self.col;
            self.skipSeparators();
            // This fast path only ever needs to match the ASCII keyword
            // "DATETIME". The identifier predicates take a u21 codepoint, so
            // gate on ASCII (< 128) before passing a raw byte — otherwise a
            // multi-byte UTF-8 lead byte would be misread as a Latin-1 letter
            // and advanced one byte mid-codepoint (GQL-APPSEC-07).
            if (self.idx < self.src.len and self.src[self.idx] < 128 and t.isIdentifierStart(self.src[self.idx])) {
                const ident_start = self.idx;
                self.idx += 1;
                self.col += 1;
                while (self.idx < self.src.len and self.src[self.idx] < 128 and t.isIdentifierContinue(self.src[self.idx])) : (self.col += 1) self.idx += 1;
                const w = self.src[ident_start..self.idx];
                if (std.ascii.eqlIgnoreCase(w, "DATETIME")) {
                    self.skipSeparators();
                    if (self.idx < self.src.len and (self.src[self.idx] == '"' or self.src[self.idx] == '\'')) {
                        const ldt_quote = self.src[self.idx];
                        const str = self.scanStringAny(ldt_quote);
                        if (!temporal.isDateTimeIso(str.lexeme, false)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                        return .{ .kind = .local_datetime_lit, .lexeme = str.lexeme, .loc = str.loc };
                    }
                }
            }
            // Fallback: not a LOCAL DATETIME literal, return LOCAL as keyword
            self.idx = save_idx;
            self.line = save_line;
            self.col = save_col;
            return .{ .kind = .LOCAL, .lexeme = slice, .loc = loc };
        }
        // Special handling for KEYS/LABELS: if followed by '(', treat as function call (identifier)
        // Note: VALUES removed from this check as it's needed as a keyword for VALUES statements
        if (kind == .KEYS or kind == .LABELS) {
            const save_idx = self.idx;
            const save_line = self.line;
            const save_col = self.col;
            self.skipSeparators();
            if (self.idx < self.src.len and self.src[self.idx] == '(') {
                // Followed by '(' is a function call, treat as identifier
                self.idx = save_idx;
                self.line = save_line;
                self.col = save_col;
                return .{ .kind = .identifier, .lexeme = slice, .loc = loc };
            }
            // Not followed by '(', restore and treat as keyword
            self.idx = save_idx;
            self.line = save_line;
            self.col = save_col;
        }
        return .{ .kind = kind, .lexeme = slice, .loc = loc };
    }

    fn scanNumeric(self: *Lexer) t.Token {
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;
        // Scan integer part
        while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
            self.idx += 1;
            self.col += 1;
        }
        var kind: t.TokenKind = .integer_lit;

        // Check for decimal point (not part of .. range operator)
        if (self.idx < self.src.len and self.src[self.idx] == '.' and !(self.idx + 1 < self.src.len and self.src[self.idx + 1] == '.')) {
            // Scan decimal part
            self.idx += 1;
            self.col += 1;
            while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
                self.idx += 1;
                self.col += 1;
            }
            kind = .float_lit;
        }

        // Check for scientific notation (e/E followed by optional +/- and digits)
        // This applies to both integer and decimal numbers
        if (self.idx < self.src.len and (self.src[self.idx] == 'e' or self.src[self.idx] == 'E')) {
            const saved_idx = self.idx;
            const saved_col = self.col;

            self.idx += 1;
            self.col += 1;

            // Optional +/- sign after e/E
            if (self.idx < self.src.len and (self.src[self.idx] == '+' or self.src[self.idx] == '-')) {
                self.idx += 1;
                self.col += 1;
            }

            // Must have at least one digit after e/E for valid scientific notation
            if (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
                while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
                    self.idx += 1;
                    self.col += 1;
                }
                kind = .float_lit; // Scientific notation is always a float
            } else {
                // No digits after e/E, backtrack to exclude it from the number
                self.idx = saved_idx;
                self.col = saved_col;
            }
        }

        return .{ .kind = kind, .lexeme = self.src[start..self.idx], .loc = loc };
    }

    // Dead functions scanQuotedIdentifier, scanStringLiteral, scanDoubleQuoted,
    // scanDoubleQuoted_OLD removed (GAP-QUAL-003): zero call sites, superseded by scanStringAny.

    fn scanStringAny(self: *Lexer, quote: u8) t.Token {
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;

        // Ensure we're at a quote character
        if (self.idx >= self.src.len or self.src[self.idx] != quote) {
            return .{ .kind = .invalid, .lexeme = "", .loc = loc };
        }

        self.idx += 1; // Skip opening quote
        self.col += 1;

        const content_start = self.idx;
        var escaped = false;

        while (self.idx < self.src.len) {
            const c = self.src[self.idx];

            if (escaped) {
                // We're processing an escaped character
                escaped = false;
                if (c == '\n') {
                    self.line += 1;
                    self.col = 1;
                } else {
                    self.col += 1;
                }
                self.idx += 1;
                continue;
            }

            if (c == '\\') {
                // Start escape sequence
                escaped = true;
                self.col += 1;
                self.idx += 1;
                continue;
            }

            if (c == quote) {
                // Check for doubled quote escape ('' or "")
                if (self.idx + 1 < self.src.len and self.src[self.idx + 1] == quote) {
                    // Doubled quote - treat as escaped quote within string
                    self.idx += 2; // Skip both quotes
                    self.col += 2;
                    continue;
                }
                // Found closing quote
                const content = self.src[content_start..self.idx];
                self.idx += 1; // Skip closing quote
                self.col += 1;
                // Return appropriate token type based on quote character
                // In GQL, both single and double quotes can be used for string literals
                // Double quotes can also be used for quoted identifiers in certain contexts
                // For now, treat both as string literals to avoid parser hangs
                const token_kind = t.TokenKind.string_lit;
                return .{ .kind = token_kind, .lexeme = content, .loc = loc };
            }

            // Regular character
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.idx += 1;
        }

        // Unterminated string
        return .{ .kind = .invalid, .lexeme = self.src[start..self.idx], .loc = loc };
    }
};

/// Safely decode a UTF-8 codepoint without assertions.
/// Returns null for invalid UTF-8 sequences.
fn decodeUtf8Codepoint(src: []const u8, idx: usize) ?u21 {
    if (idx >= src.len) return null;

    const b0 = src[idx];

    // ASCII (single byte)
    if (b0 < 0x80) return @intCast(b0);

    // Determine sequence length from first byte
    const len: usize = if (b0 & 0xE0 == 0xC0) 2 // 110xxxxx
        else if (b0 & 0xF0 == 0xE0) 3 // 1110xxxx
        else if (b0 & 0xF8 == 0xF0) 4 // 11110xxx
        else return null; // Invalid start byte (10xxxxxx or 11111xxx)

    // Check we have enough bytes
    if (idx + len > src.len) return null;

    // Validate and decode
    var cp: u21 = switch (len) {
        2 => @as(u21, b0 & 0x1F),
        3 => @as(u21, b0 & 0x0F),
        4 => @as(u21, b0 & 0x07),
        else => unreachable,
    };

    // Process continuation bytes
    for (src[idx + 1 .. idx + len]) |b| {
        if (b & 0xC0 != 0x80) return null; // Invalid continuation byte
        cp = (cp << 6) | @as(u21, b & 0x3F);
    }

    // Check for overlong encodings and invalid ranges
    const min_cp: u21 = switch (len) {
        2 => 0x80,
        3 => 0x800,
        4 => 0x10000,
        else => unreachable,
    };
    if (cp < min_cp) return null; // Overlong encoding
    if (cp > 0x10FFFF) return null; // Beyond Unicode range
    if (cp >= 0xD800 and cp <= 0xDFFF) return null; // Surrogate pair

    return cp;
}

// Unit tests for UTF-8 decoding
test "decodeUtf8Codepoint - valid ASCII" {
    const src = "Hello";
    try std.testing.expectEqual(@as(?u21, 'H'), decodeUtf8Codepoint(src, 0));
    try std.testing.expectEqual(@as(?u21, 'e'), decodeUtf8Codepoint(src, 1));
    try std.testing.expectEqual(@as(?u21, 'l'), decodeUtf8Codepoint(src, 2));
}

test "decodeUtf8Codepoint - valid 2-byte UTF-8" {
    const src = "é"; // U+00E9 = 0xC3 0xA9
    try std.testing.expectEqual(@as(?u21, 0x00E9), decodeUtf8Codepoint(src, 0));
}

test "decodeUtf8Codepoint - valid 3-byte UTF-8" {
    const src = "中"; // U+4E2D = 0xE4 0xB8 0xAD
    try std.testing.expectEqual(@as(?u21, 0x4E2D), decodeUtf8Codepoint(src, 0));
}

test "decodeUtf8Codepoint - valid 4-byte UTF-8" {
    const src = "𝄞"; // U+1D11E = 0xF0 0x9D 0x84 0x9E
    try std.testing.expectEqual(@as(?u21, 0x1D11E), decodeUtf8Codepoint(src, 0));
}

test "decodeUtf8Codepoint - invalid start byte (continuation)" {
    const src = [_]u8{ 0x80, 0x41 }; // 0x80 is a continuation byte, not valid start
    try std.testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(&src, 0));
}

test "decodeUtf8Codepoint - invalid continuation byte" {
    const src = [_]u8{ 0xC3, 0x41 }; // 0xC3 expects continuation, but 0x41 is ASCII
    try std.testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(&src, 0));
}

test "decodeUtf8Codepoint - truncated sequence" {
    const src = [_]u8{0xE4}; // 3-byte start but only 1 byte available
    try std.testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(&src, 0));
}

test "decodeUtf8Codepoint - overlong encoding" {
    // Overlong encoding of 'A' (0x41) as 2 bytes: 0xC1 0x81
    const src = [_]u8{ 0xC1, 0x81 };
    try std.testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(&src, 0));
}

test "decodeUtf8Codepoint - surrogate pair (invalid)" {
    // U+D800 is a surrogate, encoded as: 0xED 0xA0 0x80
    const src = [_]u8{ 0xED, 0xA0, 0x80 };
    try std.testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(&src, 0));
}

test "decodeUtf8Codepoint - empty input" {
    const src = "";
    try std.testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(src, 0));
}

test "decodeUtf8Codepoint - index out of bounds" {
    const src = "Hi";
    try std.testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(src, 10));
}

// Unit tests for lexer with invalid UTF-8
test "lexer - handles invalid UTF-8 gracefully" {
    // Invalid UTF-8 sequence followed by valid GQL
    const src = [_]u8{ 0x80, 0x80, 'R', 'E', 'T', 'U', 'R', 'N' };
    var lexer = Lexer{ .src = &src };

    // Should get invalid token(s) for bad UTF-8, then RETURN keyword
    const tok1 = lexer.next();
    try std.testing.expectEqual(t.TokenKind.invalid, tok1.kind);

    // The lexer may consume consecutive invalid bytes as a single token
    const tok2 = lexer.next();
    if (tok2.kind == .invalid) {
        const tok3 = lexer.next();
        try std.testing.expectEqual(t.TokenKind.RETURN, tok3.kind);
    } else {
        try std.testing.expectEqual(t.TokenKind.RETURN, tok2.kind);
    }
}

test "lexer - scientific notation float literals" {
    // Standard scientific notation
    var lex1 = Lexer{ .src = "1.23e-7" };
    const tok1 = lex1.next();
    try std.testing.expectEqual(t.TokenKind.float_lit, tok1.kind);
    try std.testing.expectEqualStrings("1.23e-7", tok1.lexeme);

    // Positive exponent
    var lex2 = Lexer{ .src = "1.5E+2" };
    const tok2 = lex2.next();
    try std.testing.expectEqual(t.TokenKind.float_lit, tok2.kind);
    try std.testing.expectEqualStrings("1.5E+2", tok2.lexeme);

    // Integer with exponent
    var lex3 = Lexer{ .src = "5e3" };
    const tok3 = lex3.next();
    try std.testing.expectEqual(t.TokenKind.float_lit, tok3.kind);
    try std.testing.expectEqualStrings("5e3", tok3.lexeme);

    // Very small exponent
    var lex4 = Lexer{ .src = "4.85e-33" };
    const tok4 = lex4.next();
    try std.testing.expectEqual(t.TokenKind.float_lit, tok4.kind);
    try std.testing.expectEqualStrings("4.85e-33", tok4.lexeme);
}

test "lexer - != operator tokenized as ne" {
    var lx = Lexer{ .src = "1 != 2" };
    const tok1 = lx.next();
    try std.testing.expectEqual(t.TokenKind.integer_lit, tok1.kind);
    const tok2 = lx.next();
    try std.testing.expectEqual(t.TokenKind.ne, tok2.kind);
    try std.testing.expectEqualStrings("!=", tok2.lexeme);
    const tok3 = lx.next();
    try std.testing.expectEqual(t.TokenKind.integer_lit, tok3.kind);
}

test "lexer - != in WHERE clause context" {
    var lx = Lexer{ .src = "WHERE n.x != 'hello'" };
    const tok1 = lx.next();
    try std.testing.expectEqual(t.TokenKind.WHERE, tok1.kind);
    const tok2 = lx.next(); // n
    try std.testing.expectEqual(t.TokenKind.identifier, tok2.kind);
    const tok3 = lx.next(); // .
    try std.testing.expectEqual(t.TokenKind.dot, tok3.kind);
    const tok4 = lx.next(); // x
    try std.testing.expectEqual(t.TokenKind.identifier, tok4.kind);
    const tok5 = lx.next(); // !=
    try std.testing.expectEqual(t.TokenKind.ne, tok5.kind);
    try std.testing.expectEqualStrings("!=", tok5.lexeme);
    const tok6 = lx.next(); // 'hello'
    try std.testing.expectEqual(t.TokenKind.string_lit, tok6.kind);
}

test "lexer - unterminated multi-line comment returns invalid" {
    // Comment that never closes
    var lx = Lexer{ .src = "/* unterminated comment" };
    const tok1 = lx.next();
    try std.testing.expectEqual(t.TokenKind.invalid, tok1.kind);
    // After the invalid token, next call should return eof
    const tok2 = lx.next();
    try std.testing.expectEqual(t.TokenKind.eof, tok2.kind);
}

test "lexer - unterminated comment with trailing code returns invalid then eof" {
    // Comment that never closes, followed by what looks like real code
    var lx = Lexer{ .src = "/* open comment RETURN" };
    const tok1 = lx.next();
    try std.testing.expectEqual(t.TokenKind.invalid, tok1.kind);
    const tok2 = lx.next();
    try std.testing.expectEqual(t.TokenKind.eof, tok2.kind);
}

test "lexer - terminated multi-line comment works normally" {
    // Properly closed comment should not produce invalid
    var lx = Lexer{ .src = "/* comment */ RETURN" };
    const tok1 = lx.next();
    try std.testing.expectEqual(t.TokenKind.RETURN, tok1.kind);
    const tok2 = lx.next();
    try std.testing.expectEqual(t.TokenKind.eof, tok2.kind);
}

test "lexer - LOCAL DATETIME typed literal still tokenizes" {
    var lx = Lexer{ .src = "LOCAL DATETIME\"2020-01-01T00:00:00\"" };
    const tok1 = lx.next();
    try std.testing.expectEqual(t.TokenKind.local_datetime_lit, tok1.kind);
}

test "lexer - non-ASCII identifier after LOCAL falls back to LOCAL keyword" {
    // Regression for GQL-APPSEC-07: a multi-byte UTF-8 lead byte after LOCAL
    // must not be misread by the ASCII DATETIME fast path. LOCAL should fall
    // back to a plain keyword token and the lexer must not crash or desync.
    var lx = Lexer{ .src = "LOCAL café" };
    const tok1 = lx.next();
    try std.testing.expectEqual(t.TokenKind.LOCAL, tok1.kind);
    // The next token starts exactly at the 'c' of café (no mid-codepoint skew).
    const tok2 = lx.next();
    try std.testing.expectEqualStrings("café", tok2.lexeme);
}
