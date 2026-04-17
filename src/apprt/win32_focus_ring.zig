//! Keyboard-focus-ring state tracker and ring-rect layout math for
//! Win32 chrome elements.
//!
//! Pure Zig module -- no HWND, no paint calls, no Win32 externs.
//!
//! **Keyboard-vs-mouse convention.**  Every interactive chrome element
//! (caption buttons, tab buttons, `+` new-tab, overflow menu, palette
//! rows, settings controls) shows a focus ring ONLY when the user is
//! keyboard-navigating.  Mouse movement or clicks flip the tracker to
//! mouse mode and the ring disappears.  A subsequent keydown restores
//! keyboard mode and the ring reappears.  This matches the standard
//! Windows shell behaviour (Explorer, Settings, Terminal).
//!
//! **Why inset, not outside?**  The focus ring is painted as a 2 px
//! stroke inset from the control's outer bounding rect.  Painting
//! outside would require controls to reserve extra margin and would
//! bleed into adjacent elements in a tight tab bar.  Insetting keeps
//! controls pixel-tight while the ring stays fully inside the hit-test
//! area.
//!
//! This module owns the mode flag and rect math.  Actual painting lives
//! in each control's WM_PAINT handler, which calls `shouldShowRing()`
//! and `ringRect()` to decide whether and where to stroke.

const std = @import("std");

// ---------------------------------------------------------------------------
// Mode + FocusRingTracker
// ---------------------------------------------------------------------------

pub const Mode = enum {
    mouse,
    keyboard,
};

pub const FocusRingTracker = struct {
    mode: Mode = .mouse,

    /// Timestamp (ms since epoch) of the last mode transition.
    /// Paint layers may fade rings in when the flag flips to keyboard,
    /// but the fade itself lives in a separate animation module.  This
    /// timestamp is for debugging and potential future fade-gating.
    last_transition_ms: u64 = 0,

    pub fn init() FocusRingTracker {
        return .{};
    }

    /// Called on WM_KEYDOWN / WM_SYSKEYDOWN.  Flips to keyboard mode;
    /// no-op if already keyboard.  Returns true when the state actually
    /// transitioned (caller uses this to schedule a chrome repaint).
    pub fn onKeyDown(self: *FocusRingTracker, now_ms: u64) bool {
        if (self.mode == .keyboard) return false;
        self.mode = .keyboard;
        self.last_transition_ms = now_ms;
        return true;
    }

    /// Called on WM_MOUSEMOVE / WM_LBUTTONDOWN / WM_RBUTTONDOWN /
    /// mouse wheel.  Flips to mouse mode; no-op if already mouse.
    pub fn onMouseInput(self: *FocusRingTracker, now_ms: u64) bool {
        if (self.mode == .mouse) return false;
        self.mode = .mouse;
        self.last_transition_ms = now_ms;
        return true;
    }

    /// True when the focus ring should be visible.  Convenience
    /// accessor for the paint layer.
    pub fn shouldShowRing(self: FocusRingTracker) bool {
        return self.mode == .keyboard;
    }
};

// ---------------------------------------------------------------------------
// Rect + ring-rect layout helpers
// ---------------------------------------------------------------------------

pub const Rect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

/// Default inset in pixels for the focus ring stroke centre line.
pub const default_inset_px: i32 = 2;

/// Given a control's outer bounding rect, return the inner rect where
/// the focus ring stroke CENTRE line sits.  The stroke is 2 px wide,
/// so the inset places the outer edge of the stroke 1 px inside the
/// outer rect edge and the inner edge 1 px further in.
///
/// When the control is too small for the requested inset the result
/// collapses to a degenerate rect at the centre of the outer rect.
pub fn ringRect(outer: Rect, inset_px: i32) Rect {
    if (inset_px <= 0) return outer;

    const cx = @divTrunc(outer.left + outer.right, 2);
    const cy = @divTrunc(outer.top + outer.bottom, 2);

    const half_w = @divTrunc(outer.width(), 2);
    const half_h = @divTrunc(outer.height(), 2);

    if (half_w <= inset_px or half_h <= inset_px) {
        // Degenerate: collapse to centre point.
        return .{ .left = cx, .top = cy, .right = cx, .bottom = cy };
    }

    return .{
        .left = outer.left + inset_px,
        .top = outer.top + inset_px,
        .right = outer.right - inset_px,
        .bottom = outer.bottom - inset_px,
    };
}

/// True when the outer rect has at least `min_dim` pixels on each
/// axis.  Below that the ring would collapse visually and callers
/// should skip the paint.
pub fn isDrawable(outer: Rect, min_dim: i32) bool {
    return outer.width() >= min_dim and outer.height() >= min_dim;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init is mouse mode" {
    const t = FocusRingTracker.init();
    try std.testing.expectEqual(Mode.mouse, t.mode);
    try std.testing.expect(!t.shouldShowRing());
}

test "onKeyDown transitions to keyboard" {
    var t = FocusRingTracker.init();
    const changed = t.onKeyDown(100);
    try std.testing.expect(changed);
    try std.testing.expectEqual(Mode.keyboard, t.mode);
    try std.testing.expect(t.shouldShowRing());
}

test "onMouseInput transitions to mouse" {
    var t = FocusRingTracker.init();
    _ = t.onKeyDown(100);
    const changed = t.onMouseInput(200);
    try std.testing.expect(changed);
    try std.testing.expectEqual(Mode.mouse, t.mode);
    try std.testing.expect(!t.shouldShowRing());
}

test "same-mode calls return false" {
    var t = FocusRingTracker.init();
    // Already mouse -- no transition.
    try std.testing.expect(!t.onMouseInput(50));
    _ = t.onKeyDown(100);
    // Already keyboard -- no transition.
    try std.testing.expect(!t.onKeyDown(150));
}

test "transition flips last_transition_ms" {
    var t = FocusRingTracker.init();
    try std.testing.expectEqual(@as(u64, 0), t.last_transition_ms);
    _ = t.onKeyDown(1000);
    try std.testing.expectEqual(@as(u64, 1000), t.last_transition_ms);
    _ = t.onMouseInput(2000);
    try std.testing.expectEqual(@as(u64, 2000), t.last_transition_ms);
}

test "keyboard mode persists across multiple keydowns" {
    var t = FocusRingTracker.init();
    try std.testing.expect(t.onKeyDown(100));
    try std.testing.expect(!t.onKeyDown(200));
    try std.testing.expect(!t.onKeyDown(300));
    try std.testing.expectEqual(Mode.keyboard, t.mode);
    // Timestamp stays at first transition.
    try std.testing.expectEqual(@as(u64, 100), t.last_transition_ms);
}

test "mouse mode persists across movements" {
    var t = FocusRingTracker.init();
    _ = t.onKeyDown(100);
    try std.testing.expect(t.onMouseInput(200));
    try std.testing.expect(!t.onMouseInput(300));
    try std.testing.expect(!t.onMouseInput(400));
    try std.testing.expectEqual(Mode.mouse, t.mode);
    try std.testing.expectEqual(@as(u64, 200), t.last_transition_ms);
}

test "ringRect small inset" {
    const outer = Rect{ .left = 0, .top = 0, .right = 40, .bottom = 40 };
    const r = ringRect(outer, 2);
    try std.testing.expectEqual(@as(i32, 2), r.left);
    try std.testing.expectEqual(@as(i32, 2), r.top);
    try std.testing.expectEqual(@as(i32, 38), r.right);
    try std.testing.expectEqual(@as(i32, 38), r.bottom);
}

test "ringRect degenerate outer" {
    const outer = Rect{ .left = 0, .top = 0, .right = 2, .bottom = 2 };
    const r = ringRect(outer, 2);
    // half_w=1 <= inset=2 → collapses to centre (1,1,1,1).
    try std.testing.expectEqual(@as(i32, 1), r.left);
    try std.testing.expectEqual(@as(i32, 1), r.top);
    try std.testing.expectEqual(@as(i32, 1), r.right);
    try std.testing.expectEqual(@as(i32, 1), r.bottom);
}

test "ringRect negative inset no-op" {
    const outer = Rect{ .left = 5, .top = 10, .right = 50, .bottom = 60 };
    const r = ringRect(outer, 0);
    try std.testing.expectEqual(outer.left, r.left);
    try std.testing.expectEqual(outer.top, r.top);
    try std.testing.expectEqual(outer.right, r.right);
    try std.testing.expectEqual(outer.bottom, r.bottom);
}

test "isDrawable true" {
    const outer = Rect{ .left = 0, .top = 0, .right = 30, .bottom = 30 };
    try std.testing.expect(isDrawable(outer, 20));
}

test "isDrawable false" {
    const outer = Rect{ .left = 0, .top = 0, .right = 10, .bottom = 10 };
    try std.testing.expect(!isDrawable(outer, 20));
}
