//! Shared Win32-compatible geometry types for apprt helper modules.

/// Layout-compatible with Win32 RECT.
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

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }
};

/// Layout-compatible with Win32 POINT / POINTL.
pub const Point = extern struct {
    x: i32,
    y: i32,
};

pub const PointL = Point;

test "win32 geometry Rect helpers" {
    const testing = @import("std").testing;
    const r: Rect = .{ .left = 10, .top = 20, .right = 30, .bottom = 45 };

    try testing.expectEqual(@as(i32, 20), r.width());
    try testing.expectEqual(@as(i32, 25), r.height());
    try testing.expect(r.contains(10, 20));
    try testing.expect(r.contains(29, 44));
    try testing.expect(!r.contains(30, 44));
    try testing.expect(!r.contains(29, 45));
}
