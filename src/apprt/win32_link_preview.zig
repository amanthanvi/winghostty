//! Link-hover dwell tracker and tooltip content model.
//!
//! Implements a three-state machine (idle -> dwelling -> shown) that governs
//! when the terminal should display a preview tooltip for hovered hyperlinks.
//! After ~500 ms of cursor dwell without significant movement, the tracker
//! emits `.show`; it emits `.hide` on cursor departure, click/keypress
//! dismissal, or a 5 s display timeout.
//!
//! Allocation-free: the tracker borrows URL and title slices from the
//! caller (terminal surface / OSC 8 storage). The tooltip HWND paint path
//! copies `displayText()` into its own buffer at render time, so the
//! tracker never needs to own string memory.

const std = @import("std");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Milliseconds the cursor must dwell over a link before showing the tooltip.
pub const dwell_threshold_ms: u64 = 500;

/// Pixel radius within which cursor movement does not cancel the dwell timer.
pub const dwell_cancel_radius_px: i32 = 3;

/// Milliseconds the tooltip remains visible before auto-dismissing.
pub const tooltip_timeout_ms: u64 = 5000;

// ---------------------------------------------------------------------------
// Content model
// ---------------------------------------------------------------------------

pub const LinkKind = enum {
    /// OSC 8 hyperlink (with or without a title parameter).
    explicit,
    /// URL detected by the terminal's regex matcher.
    implicit,
};

pub const LinkHover = struct {
    kind: LinkKind,
    url: []const u8,
    title: ?[]const u8 = null,
    cursor_x: i32,
    cursor_y: i32,
    entered_at_ms: u64,
};

/// Returns the borrowed slice most suitable for tooltip display.
/// OSC 8 with title -> title; everything else -> url.
pub fn displayText(link: LinkHover) []const u8 {
    if (link.kind == .explicit) {
        if (link.title) |t| return t;
    }
    return link.url;
}

// ---------------------------------------------------------------------------
// Tracker state machine
// ---------------------------------------------------------------------------

pub const State = enum {
    idle,
    dwelling,
    shown,
};

pub const Action = enum { none, show, hide };

pub const HoverTracker = struct {
    state: State,
    current: ?LinkHover,
    last_move_x: i32,
    last_move_y: i32,
    shown_at_ms: u64,

    pub fn init() HoverTracker {
        return .{
            .state = .idle,
            .current = null,
            .last_move_x = 0,
            .last_move_y = 0,
            .shown_at_ms = 0,
        };
    }

    /// Called every mouse-move. `link` is null when the cursor is not
    /// over any recognized hyperlink.
    pub fn onMouseMove(
        self: *HoverTracker,
        x: i32,
        y: i32,
        link: ?LinkHover,
        now_ms: u64,
    ) Action {
        switch (self.state) {
            .idle => {
                if (link) |lk| {
                    self.state = .dwelling;
                    self.current = lk;
                    self.current.?.entered_at_ms = now_ms;
                    self.last_move_x = x;
                    self.last_move_y = y;
                }
                return .none;
            },
            .dwelling => {
                if (link == null) {
                    self.reset();
                    return .none; // was never shown; nothing to hide
                }
                if (beyondRadius(self.last_move_x, self.last_move_y, x, y)) {
                    // Significant movement -- restart the dwell timer.
                    self.current.?.entered_at_ms = now_ms;
                    self.last_move_x = x;
                    self.last_move_y = y;
                } else {
                    self.last_move_x = x;
                    self.last_move_y = y;
                }
                return .none;
            },
            .shown => {
                if (link == null) {
                    self.reset();
                    return .hide;
                }
                if (beyondRadius(self.last_move_x, self.last_move_y, x, y)) {
                    self.reset();
                    return .hide;
                }
                self.last_move_x = x;
                self.last_move_y = y;
                return .none;
            },
        }
    }

    /// Unconditional dismissal (click, keypress, etc.).
    pub fn dismiss(self: *HoverTracker) Action {
        if (self.state == .idle) return .none;
        const was_shown = self.state == .shown;
        self.reset();
        return if (was_shown) .hide else .none;
    }

    /// Periodic tick. Advances dwelling -> shown and enforces the display
    /// timeout on the shown state.
    pub fn tick(self: *HoverTracker, now_ms: u64) Action {
        switch (self.state) {
            .idle => return .none,
            .dwelling => {
                if (self.current) |cur| {
                    if (now_ms >= cur.entered_at_ms + dwell_threshold_ms) {
                        self.state = .shown;
                        self.shown_at_ms = now_ms;
                        return .show;
                    }
                }
                return .none;
            },
            .shown => {
                if (now_ms >= self.shown_at_ms + tooltip_timeout_ms) {
                    self.reset();
                    return .hide;
                }
                return .none;
            },
        }
    }

    fn reset(self: *HoverTracker) void {
        self.state = .idle;
        self.current = null;
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn beyondRadius(ax: i32, ay: i32, bx: i32, by: i32) bool {
    const dx = bx - ax;
    const dy = by - ay;
    return dx * dx + dy * dy > dwell_cancel_radius_px * dwell_cancel_radius_px;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testLink(kind: LinkKind, url: []const u8, title: ?[]const u8) LinkHover {
    return .{
        .kind = kind,
        .url = url,
        .title = title,
        .cursor_x = 0,
        .cursor_y = 0,
        .entered_at_ms = 0,
    };
}

test "idle to dwelling on move over link" {
    var t = HoverTracker.init();
    const link = testLink(.explicit, "https://example.com", null);
    const act = t.onMouseMove(10, 20, link, 100);
    try std.testing.expectEqual(Action.none, act);
    try std.testing.expectEqual(State.dwelling, t.state);
}

test "dwelling to shown after threshold" {
    var t = HoverTracker.init();
    const link = testLink(.explicit, "https://example.com", null);
    _ = t.onMouseMove(10, 20, link, 100);
    try std.testing.expectEqual(State.dwelling, t.state);

    // Before threshold -- still dwelling.
    try std.testing.expectEqual(Action.none, t.tick(500));
    try std.testing.expectEqual(State.dwelling, t.state);

    // At threshold boundary.
    try std.testing.expectEqual(Action.show, t.tick(600));
    try std.testing.expectEqual(State.shown, t.state);
}

test "shown stays shown while cursor within radius" {
    var t = HoverTracker.init();
    const link = testLink(.implicit, "https://example.com", null);
    _ = t.onMouseMove(10, 20, link, 0);
    _ = t.tick(600);
    try std.testing.expectEqual(State.shown, t.state);

    // Small move within the 3 px radius.
    const act = t.onMouseMove(12, 21, link, 700);
    try std.testing.expectEqual(Action.none, act);
    try std.testing.expectEqual(State.shown, t.state);
}

test "shown to hide on move beyond radius" {
    var t = HoverTracker.init();
    const link = testLink(.implicit, "https://example.com", null);
    _ = t.onMouseMove(10, 20, link, 0);
    _ = t.tick(600);
    try std.testing.expectEqual(State.shown, t.state);

    const act = t.onMouseMove(25, 20, link, 700);
    try std.testing.expectEqual(Action.hide, act);
    try std.testing.expectEqual(State.idle, t.state);
}

test "shown to hide on timeout" {
    var t = HoverTracker.init();
    const link = testLink(.explicit, "https://example.com", null);
    _ = t.onMouseMove(10, 20, link, 0);
    _ = t.tick(600);
    try std.testing.expectEqual(State.shown, t.state);

    // Before timeout.
    try std.testing.expectEqual(Action.none, t.tick(5500));
    // At/past timeout.
    try std.testing.expectEqual(Action.hide, t.tick(5600));
    try std.testing.expectEqual(State.idle, t.state);
}

test "dwelling resets on move beyond radius onto same link" {
    var t = HoverTracker.init();
    const link = testLink(.explicit, "https://example.com", null);
    _ = t.onMouseMove(10, 20, link, 100);
    try std.testing.expectEqual(State.dwelling, t.state);

    // Move beyond radius at t=200 -- dwell timer resets.
    _ = t.onMouseMove(20, 30, link, 200);
    try std.testing.expectEqual(State.dwelling, t.state);
    try std.testing.expectEqual(@as(u64, 200), t.current.?.entered_at_ms);

    // tick at t=500: only 300 ms since reset -- still dwelling.
    try std.testing.expectEqual(Action.none, t.tick(500));
    try std.testing.expectEqual(State.dwelling, t.state);

    // tick at t=700: 500 ms since reset -- now shown.
    try std.testing.expectEqual(Action.show, t.tick(700));
    try std.testing.expectEqual(State.shown, t.state);
}

test "cursor leaves link returns to idle" {
    var t = HoverTracker.init();
    const link = testLink(.explicit, "https://example.com", null);
    _ = t.onMouseMove(10, 20, link, 0);
    try std.testing.expectEqual(State.dwelling, t.state);

    const act = t.onMouseMove(10, 20, null, 100);
    try std.testing.expectEqual(Action.none, act);
    try std.testing.expectEqual(State.idle, t.state);
}

test "dismiss from shown returns hide" {
    var t = HoverTracker.init();
    const link = testLink(.explicit, "https://example.com", null);
    _ = t.onMouseMove(10, 20, link, 0);
    _ = t.tick(600);
    try std.testing.expectEqual(State.shown, t.state);

    const act = t.dismiss();
    try std.testing.expectEqual(Action.hide, act);
    try std.testing.expectEqual(State.idle, t.state);
}

test "displayText picks title then url" {
    const with_title = testLink(.explicit, "https://example.com", "Example Site");
    try std.testing.expectEqualStrings("Example Site", displayText(with_title));

    const without_title = testLink(.explicit, "https://example.com", null);
    try std.testing.expectEqualStrings("https://example.com", displayText(without_title));

    const implicit = testLink(.implicit, "https://example.com/path", null);
    try std.testing.expectEqualStrings("https://example.com/path", displayText(implicit));
}
