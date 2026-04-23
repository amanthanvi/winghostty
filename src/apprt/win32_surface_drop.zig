//! Surface-level drag-drop payload extraction and formatting.
//!
//! This module is pure logic: it takes already-extracted raw bytes from
//! CF_HDROP / CF_UNICODETEXT / CF_HTML / CFSTR_SHELLURL clipboard formats
//! plus modifier flags, and produces the final string to be typed at the
//! cursor position.
//!
//! Modifier semantics (Explorer / Windows Terminal convention):
//!   - No modifier : type the payload verbatim at cursor.
//!   - Shift       : files -> use parent directory; text -> strip trailing newline.
//!   - Ctrl        : files -> suppress quoting (raw paths).
//!   - Alt         : reserved for future use.
//!
//! The caller is responsible for routing the returned payload through
//! `Surface.pasteClipboardText`, which honours `clipboard-paste-protection`.
//! This module only produces bytes; it never touches the clipboard or COM.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cf_html = @import("win32_clipboard_html.zig");

// ---------------------------------------------------------------------------
// Modifier flags
// ---------------------------------------------------------------------------

pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    _padding: u5 = 0,
};

// ---------------------------------------------------------------------------
// File-drop formatting
// ---------------------------------------------------------------------------

/// Characters that require quoting in a shell context.
/// Includes whitespace (space, tab), double-quote, and common shell
/// metacharacters that would cause unintended expansion or piping.
/// We intentionally omit single-quote and backslash because Windows
/// paths use backslash natively and single-quote is not a metachar in
/// cmd.exe. The set covers POSIX sh/bash metachar overlap that matters
/// when pasting into a terminal running a Unix shell under WSL or
/// similar.
// `;` is a statement separator in BOTH PowerShell and POSIX shells —
// a filename like `foo; Start-Process calc.txt` dropped unquoted would
// execute a second command. Same reasoning for `^` on cmd.exe (escape
// character), `<` / `>` (redirect), `!` (POSIX history expansion),
// `'` (single-quote start in POSIX), `%` (cmd.exe env-var expansion
// that triggers even inside double quotes), `{` / `}` (zsh / bash
// brace expansion in some contexts). Accept false positives over
// false negatives; quoting an already-safe name is harmless, failing
// to quote a metachar isn't.
//
// NOTE: This list only determines whether the path NEEDS quoting.
// The surface drop callback additionally routes the payload through
// `core_surface.completeClipboardRequest(.paste, …, confirmed=false)`,
// which triggers the non-modal paste-protection overlay whenever the
// content contains shell metacharacters. That's the real defense-in-
// depth gate: quoting alone can't prevent interpolation in every
// shell (PowerShell expands `$var` inside double quotes; cmd expands
// `%VAR%` in any quoting), so the user confirmation is what keeps a
// crafted filename from silently executing on paste.
const quoting_chars = " \t\"$`|&();^<>!'%{}";

/// True when the path contains characters that require quoting.
pub fn requiresQuoting(path: []const u8) bool {
    for (path) |c| {
        if (std.mem.indexOfScalar(u8, quoting_chars, c) != null) return true;
    }
    return false;
}

/// Walk backward to find the parent directory.
///
/// Handles both `\` and `/` separators. Drive-letter roots like `C:\`
/// are preserved. Bare filenames without a separator return `"."`.
pub fn parentDir(path: []const u8) []const u8 {
    if (path.len == 0) return ".";

    // Skip trailing separators.
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) : (end -= 1) {}

    // Find the last separator before the basename.
    var i = end;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '\\' or path[i - 1] == '/') {
            // Check for drive-letter root: e.g. "C:\"
            if (i == 3 and path.len >= 3 and path[1] == ':') return path[0..3];
            // Unix root or UNC prefix: keep the separator.
            if (i == 1) return path[0..1];
            return path[0 .. i - 1];
        }
    }
    return ".";
}

/// Produce a space-separated payload string from an array of file paths.
///
/// Each path is quoted with `"..."` when it contains shell-sensitive
/// characters, with embedded `"` escaped as `\"`. Ctrl suppresses all
/// quoting. Shift replaces each path with its parent directory.
///
/// Ownership: the returned slice is owned by `alloc`.
pub fn formatFilePayload(
    alloc: Allocator,
    paths: []const []const u8,
    modifiers: Modifiers,
) Allocator.Error![]u8 {
    if (paths.len == 0) {
        return try alloc.alloc(u8, 0);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    for (paths, 0..) |raw_path, idx| {
        if (idx > 0) try buf.append(alloc, ' ');

        const path = if (modifiers.shift) parentDir(raw_path) else raw_path;
        const needs_quote = !modifiers.ctrl and requiresQuoting(path);

        if (needs_quote) try buf.append(alloc, '"');

        for (path) |c| {
            if (c == '"' and !modifiers.ctrl) {
                try buf.append(alloc, '\\');
            }
            try buf.append(alloc, c);
        }

        if (needs_quote) try buf.append(alloc, '"');
    }

    return try buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Text-drop formatting
// ---------------------------------------------------------------------------

/// Format a CF_UNICODETEXT payload.
///
/// Shift strips a single trailing line ending (`\r\n`, `\n`, or `\r`).
/// Ctrl has no effect on text.
///
/// Ownership: the returned slice is owned by `alloc`.
pub fn formatTextPayload(
    alloc: Allocator,
    text: []const u8,
    modifiers: Modifiers,
) Allocator.Error![]u8 {
    var end = text.len;
    if (modifiers.shift and end > 0) {
        if (end >= 2 and text[end - 2] == '\r' and text[end - 1] == '\n') {
            end -= 2;
        } else if (text[end - 1] == '\n' or text[end - 1] == '\r') {
            end -= 1;
        }
    }
    const result = try alloc.alloc(u8, end);
    @memcpy(result, text[0..end]);
    return result;
}

// ---------------------------------------------------------------------------
// URL extraction
// ---------------------------------------------------------------------------

/// Extract a URL from CFSTR_SHELLURL raw bytes.
///
/// The format is a null-terminated ANSI string. We trim at the first
/// null byte and strip trailing whitespace. Returns a borrowed slice.
pub fn extractShellUrl(raw: []const u8) []const u8 {
    // Trim at first null.
    var end = raw.len;
    if (std.mem.indexOfScalar(u8, raw, 0)) |null_pos| {
        end = null_pos;
    }

    // Strip trailing whitespace (including \r\n).
    while (end > 0 and std.ascii.isWhitespace(raw[end - 1])) : (end -= 1) {}

    return raw[0..end];
}

// ---------------------------------------------------------------------------
// CF_HTML fragment extraction
// ---------------------------------------------------------------------------

const start_marker = "<!--StartFragment-->";
const end_marker = "<!--EndFragment-->";

/// Extract the fragment from a CF_HTML envelope.
///
/// Extract the fragment from a CF_HTML envelope. Prefers the mandatory
/// `StartFragment` / `EndFragment` numeric byte offsets in the header
/// (per the CF_HTML spec they're REQUIRED fields); falls back to
/// `<!--StartFragment-->` / `<!--EndFragment-->` comment markers which
/// are OPTIONAL and not emitted by some apps. Returns the whole input
/// when neither the numeric offsets nor the markers can be parsed.
///
/// Before: we always used the comment markers, so spec-compliant apps
/// that omit them (e.g. some browsers + Office variants) dropped the
/// entire envelope — `Version:0.9\r\n…` — into the terminal instead
/// of the selected fragment.
pub fn extractHtmlFragment(raw: []const u8) []const u8 {
    // Numeric-offset path (spec-mandatory). Canonical CF_HTML uses
    // zero-padded 10-digit offsets, but the shared parser is lenient
    // about whitespace and digit width for drag sources that are not.
    if (cf_html.fragmentRange(raw)) |range| {
        if (range.start <= range.end and range.end <= raw.len) {
            return raw[range.start..range.end];
        }
    }
    // Fallback: comment-marker path (optional per spec).
    if (std.mem.indexOf(u8, raw, start_marker)) |sf| {
        const frag_start = sf + start_marker.len;
        if (std.mem.indexOfPos(u8, raw, frag_start, end_marker)) |ef| {
            return raw[frag_start..ef];
        }
        return raw[frag_start..];
    }
    return raw;
}

// ===========================================================================
// Tests
// ===========================================================================

test "single path with no whitespace" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{"C:\\Users\\test\\file.txt"}, .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("C:\\Users\\test\\file.txt", result);
}

test "single path with whitespace" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{"C:\\Program Files\\x"}, .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("\"C:\\Program Files\\x\"", result);
}

test "path with embedded double quote" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{"C:\\weird\\name\"escaped"}, .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("\"C:\\weird\\name\\\"escaped\"", result);
}

test "multiple paths joined with space" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{ "C:\\Program Files\\a", "C:\\Program Files\\b" }, .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("\"C:\\Program Files\\a\" \"C:\\Program Files\\b\"", result);
}

test "shift modifier substitutes parent" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{"C:\\foo\\bar.txt"}, .{ .shift = true });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("C:\\foo", result);
}

test "ctrl modifier suppresses quoting" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{"C:\\Program Files\\x"}, .{ .ctrl = true });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("C:\\Program Files\\x", result);
}

test "shift + ctrl: parent dir, no quoting" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{"C:\\Program Files\\bar.txt"}, .{ .shift = true, .ctrl = true });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("C:\\Program Files", result);
}

test "empty paths array" {
    const alloc = std.testing.allocator;
    const result = try formatFilePayload(alloc, &.{}, .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("", result);
}

// -- parentDir --

test "parentDir: windows path" {
    try std.testing.expectEqualStrings("C:\\foo", parentDir("C:\\foo\\bar.txt"));
}

test "parentDir: drive root" {
    try std.testing.expectEqualStrings("C:\\", parentDir("C:\\bar.txt"));
}

test "parentDir: bare filename" {
    try std.testing.expectEqualStrings(".", parentDir("bar.txt"));
}

test "parentDir: unix-style separator" {
    try std.testing.expectEqualStrings("/usr/local/bin", parentDir("/usr/local/bin/bash"));
}

// -- requiresQuoting --

test "requiresQuoting: plain" {
    try std.testing.expect(!requiresQuoting("plain"));
}

test "requiresQuoting: with space" {
    try std.testing.expect(requiresQuoting("with space"));
}

test "requiresQuoting: with quote" {
    try std.testing.expect(requiresQuoting("with\"quote"));
}

test "requiresQuoting: with dollar" {
    try std.testing.expect(requiresQuoting("with$dollar"));
}

test "requiresQuoting: with ampersand" {
    try std.testing.expect(requiresQuoting("with&amp"));
}

test "requiresQuoting: empty" {
    try std.testing.expect(!requiresQuoting(""));
}

test "requiresQuoting: semicolon (command separator)" {
    // Regression for command-injection via crafted filenames.
    try std.testing.expect(requiresQuoting("foo;Start-Process calc.txt"));
    try std.testing.expect(requiresQuoting("foo;bar"));
}

test "requiresQuoting: caret, redirects, bang, quote" {
    try std.testing.expect(requiresQuoting("a^b")); // cmd.exe escape
    try std.testing.expect(requiresQuoting("a<b")); // redirect
    try std.testing.expect(requiresQuoting("a>b"));
    try std.testing.expect(requiresQuoting("a!b")); // POSIX history
    try std.testing.expect(requiresQuoting("a'b")); // POSIX single-quote
}

// -- formatTextPayload --

test "text: no modifiers" {
    const alloc = std.testing.allocator;
    const result = try formatTextPayload(alloc, "hello", .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "text: shift strips trailing crlf" {
    const alloc = std.testing.allocator;
    const result = try formatTextPayload(alloc, "hello\r\n", .{ .shift = true });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "text: shift strips trailing lf" {
    const alloc = std.testing.allocator;
    const result = try formatTextPayload(alloc, "hello\n", .{ .shift = true });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "text: shift no trailing newline" {
    const alloc = std.testing.allocator;
    const result = try formatTextPayload(alloc, "hello", .{ .shift = true });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "text: no-shift preserves trailing newline" {
    const alloc = std.testing.allocator;
    const result = try formatTextPayload(alloc, "hello\r\n", .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello\r\n", result);
}

// -- extractShellUrl --

test "extractShellUrl: null terminated" {
    try std.testing.expectEqualStrings(
        "https://example.com/",
        extractShellUrl("https://example.com/\x00extra"),
    );
}

test "extractShellUrl: trailing whitespace" {
    try std.testing.expectEqualStrings(
        "https://example.com",
        extractShellUrl("https://example.com\r\n"),
    );
}

test "extractShellUrl: clean input" {
    const input = "https://example.com/path";
    try std.testing.expectEqualStrings(input, extractShellUrl(input));
}

// -- extractHtmlFragment --

test "extractHtmlFragment: real CF_HTML" {
    // Byte positions hand-computed so the `StartFragment:` /
    // `EndFragment:` header offsets point exactly at `<b>…</b>`.
    // (`Version:0.9\r\n` = 13 bytes; four `Key:value\r\n` lines total
    // 13+22+20+26+24 = 105; `<html><body>\r\n` = 14 → offset 119;
    // `<!--StartFragment-->` = 20 → offset 139 (start of `<b>`);
    // `<b>hello world</b>` = 18 → offset 157.)
    const cf =
        "Version:0.9\r\n" ++
        "StartHTML:0000000105\r\n" ++
        "EndHTML:0000000175\r\n" ++
        "StartFragment:0000000139\r\n" ++
        "EndFragment:0000000157\r\n" ++
        "<html><body>\r\n" ++
        "<!--StartFragment-->" ++
        "<b>hello world</b>" ++
        "<!--EndFragment-->\r\n" ++
        "</body></html>";
    try std.testing.expectEqualStrings("<b>hello world</b>", extractHtmlFragment(cf));
}

test "extractHtmlFragment: malformed no markers" {
    const raw = "just some random text";
    try std.testing.expectEqualStrings(raw, extractHtmlFragment(raw));
}

test "extractHtmlFragment: only start marker" {
    const raw = "prefix<!--StartFragment-->trailing content";
    try std.testing.expectEqualStrings("trailing content", extractHtmlFragment(raw));
}

test "extractHtmlFragment: numeric offsets without comment markers" {
    // Spec-compliant CF_HTML that omits the <!--StartFragment-->
    // markers (some browsers / Office apps). Header-based offsets
    // must be honoured or the entire envelope leaks into the paste.
    //
    // Header lengths: 13+22+20+26+24 = 105, then `<html>` (6) → 111.
    // `hello world` (11) spans 111..122.
    const raw =
        "Version:0.9\r\n" ++
        "StartHTML:0000000105\r\n" ++
        "EndHTML:0000000128\r\n" ++
        "StartFragment:0000000111\r\n" ++
        "EndFragment:0000000122\r\n" ++
        "<html>hello world</html>";
    const frag = extractHtmlFragment(raw);
    try std.testing.expectEqualStrings("hello world", frag);
}

test "extractHtmlFragment: header offsets take precedence over markers" {
    // When both offsets AND markers are present, offsets win (they're
    // the mandatory spec-compliant source of truth). Offsets point at
    // "hello world" (bytes 111..122); the <!--StartFragment--> marker
    // sits at byte 128 so the old comment-marker path would have
    // extracted different content.
    //
    // Header lengths: 13+22+20+26+24 = 105, then `<html>` (6) → 111.
    const raw =
        "Version:0.9\r\n" ++
        "StartHTML:0000000105\r\n" ++
        "EndHTML:0000000200\r\n" ++
        "StartFragment:0000000111\r\n" ++
        "EndFragment:0000000122\r\n" ++
        "<html>hello world</html><!--StartFragment-->wrong<!--EndFragment-->";
    const frag = extractHtmlFragment(raw);
    try std.testing.expectEqualStrings("hello world", frag);
}
