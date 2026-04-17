//! CF_HTML clipboard format serialiser.
//!
//! Microsoft's CF_HTML clipboard format wraps an HTML fragment in a
//! fixed-width header whose byte offsets let consumers locate the
//! fragment without parsing. The four offset values are zero-padded
//! to exactly 10 decimal digits — this width is load-bearing because
//! consumers parse by fixed column position. Do not "optimise" the
//! padding away.
//!
//! Reference: https://learn.microsoft.com/en-us/windows/win32/dataxchg/html-clipboard-format

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Header template with 10-digit placeholder offsets.
/// Each line is terminated by \r\n. The header length is constant
/// regardless of the actual offset values because every field is
/// always exactly 10 digits wide.
const header_template =
    "Version:0.9\r\n" ++
    "StartHTML:0000000000\r\n" ++
    "EndHTML:0000000000\r\n" ++
    "StartFragment:0000000000\r\n" ++
    "EndFragment:0000000000\r\n";

const prefix = "<html><body>\r\n<!--StartFragment-->";
const suffix = "<!--EndFragment-->\r\n</body></html>";

/// Wrap an HTML fragment in the CF_HTML clipboard envelope.
///
/// Returns a freshly-allocated byte slice owned by `alloc` containing
/// the complete CF_HTML text ready for `SetClipboardData`. The caller
/// must free the returned slice with `alloc.free`.
pub fn wrapFragment(alloc: Allocator, html: []const u8) Allocator.Error![]u8 {
    const header_len = header_template.len;
    const start_html = header_len;
    const start_fragment = header_len + prefix.len;
    const end_fragment = start_fragment + html.len;
    const end_html = end_fragment + suffix.len;

    const total = end_html;
    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);

    // Write header with real offsets.
    var pos: usize = 0;
    pos += (std.fmt.bufPrint(buf[pos..], "Version:0.9\r\n" ++
        "StartHTML:{d:0>10}\r\n" ++
        "EndHTML:{d:0>10}\r\n" ++
        "StartFragment:{d:0>10}\r\n" ++
        "EndFragment:{d:0>10}\r\n", .{
        start_html,
        end_html,
        start_fragment,
        end_fragment,
    }) catch unreachable).len;

    // Sanity: header consumed exactly header_len bytes.
    std.debug.assert(pos == header_len);

    // Write body prefix.
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // Write fragment.
    @memcpy(buf[pos..][0..html.len], html);
    pos += html.len;

    // Write body suffix.
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    std.debug.assert(pos == total);
    return buf;
}

// ---------------------------------------------------------------------------
// Helpers for tests
// ---------------------------------------------------------------------------

fn parseOffset(output: []const u8, comptime key: []const u8) ?usize {
    const needle = key ++ ":";
    const start = std.mem.indexOf(u8, output, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfPos(u8, output, val_start, "\r\n") orelse return null;
    const digits = output[val_start..val_end];
    if (digits.len != 10) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "wrapFragment emits a valid CF_HTML header" {
    const alloc = std.testing.allocator;
    const out = try wrapFragment(alloc, "<b>test</b>");
    defer alloc.free(out);

    // Each key must be present with a 10-digit value.
    inline for (.{ "StartHTML", "EndHTML", "StartFragment", "EndFragment" }) |key| {
        const needle = key ++ ":";
        const idx = std.mem.indexOf(u8, out, needle).?;
        const val_start = idx + needle.len;
        const val_end = std.mem.indexOfPos(u8, out, val_start, "\r\n").?;
        try std.testing.expectEqual(@as(usize, 10), val_end - val_start);
    }
}

test "wrapFragment offsets point at the correct byte positions" {
    const alloc = std.testing.allocator;
    const fragment = "<em>hi</em>";
    const out = try wrapFragment(alloc, fragment);
    defer alloc.free(out);

    const sh = parseOffset(out, "StartHTML").?;
    const eh = parseOffset(out, "EndHTML").?;
    const sf = parseOffset(out, "StartFragment").?;
    const ef = parseOffset(out, "EndFragment").?;

    // StartHTML -> "<html>"
    try std.testing.expect(std.mem.startsWith(u8, out[sh..], "<html>"));

    // EndHTML -> one past "</html>"
    try std.testing.expect(eh == out.len);
    try std.testing.expect(std.mem.endsWith(u8, out[0..eh], "</html>"));

    // StartFragment -> first byte of the fragment
    try std.testing.expectEqualStrings(fragment, out[sf..ef]);

    // EndFragment -> the '<' of <!--EndFragment-->
    try std.testing.expectEqual(@as(u8, '<'), out[ef]);
    try std.testing.expect(std.mem.startsWith(u8, out[ef..], "<!--EndFragment-->"));
}

test "wrapFragment preserves the fragment bytes verbatim" {
    const alloc = std.testing.allocator;
    const fragment = "<span style=\"color:red\">hello</span>";
    const out = try wrapFragment(alloc, fragment);
    defer alloc.free(out);

    const sf = parseOffset(out, "StartFragment").?;
    const ef = parseOffset(out, "EndFragment").?;
    try std.testing.expectEqualStrings(fragment, out[sf..ef]);
}

test "wrapFragment handles empty fragment" {
    const alloc = std.testing.allocator;
    const out = try wrapFragment(alloc, "");
    defer alloc.free(out);

    const sf = parseOffset(out, "StartFragment").?;
    const ef = parseOffset(out, "EndFragment").?;
    try std.testing.expectEqual(sf, ef);

    // Still valid structure.
    const sh = parseOffset(out, "StartHTML").?;
    const eh = parseOffset(out, "EndHTML").?;
    try std.testing.expect(std.mem.startsWith(u8, out[sh..], "<html>"));
    try std.testing.expect(eh == out.len);
}

test "wrapFragment handles unicode fragment" {
    const alloc = std.testing.allocator;
    const fragment = "\xc3\xa9\xe2\x80\x93\xf0\x9f\x91\x8b"; // e-acute, en-dash, wave emoji
    const out = try wrapFragment(alloc, fragment);
    defer alloc.free(out);

    const sf = parseOffset(out, "StartFragment").?;
    const ef = parseOffset(out, "EndFragment").?;
    try std.testing.expectEqualStrings(fragment, out[sf..ef]);
}
