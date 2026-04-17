//! In-app toast notification stack.
//!
//! Manages a queue of transient notification bubbles that stack from
//! the top-right of the owner window.  Up to `max_visible` toasts are
//! shown simultaneously; extras land in a `pending` queue and promote
//! when a visible slot opens (dismiss or auto-expire).
//!
//! Stacking rules:
//!   - Toast 0 is the top-most; each subsequent toast offsets downward
//!     by `toast_height_dp + toast_gap_dp`.
//!   - `target_y_offset` is recomputed on every `tick()`; the caller's
//!     tween scheduler drives the actual per-frame interpolation of
//!     `y_offset` toward that target.
//!
//! Hover-pause semantics:
//!   Hovered toasts accumulate `hover_pause_ms`.  Effective age is
//!   `(now_ms - created_ms) - hover_pause_ms`.  A toast with
//!   `auto_dismiss_ms == 0` (sticky) never expires regardless.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Severity = enum { info, warn, err, success };

pub const Toast = struct {
    title: []u8,
    body: []u8,
    severity: Severity,
    created_ms: u64,
    auto_dismiss_ms: u64,
    hovered: bool = false,
    hover_pause_ms: u64 = 0,
    /// Timestamp when the toast was last marked hovered (0 = not tracking).
    hover_start_ms: u64 = 0,
    y_offset: f32 = 0,
    target_y_offset: f32 = 0,
    id: u64,
};

// ── Stack constants ──────────────────────────────────────────────────

pub const max_visible: usize = 3;
pub const default_auto_dismiss_ms: u64 = 3000;
pub const toast_width_dp: f32 = 360;
pub const toast_height_dp: f32 = 72;
pub const toast_gap_dp: f32 = 8;
pub const stack_edge_margin_dp: f32 = 16;

// ── ToastStack ───────────────────────────────────────────────────────

pub const ToastStack = struct {
    alloc: Allocator,
    toasts: std.ArrayListUnmanaged(Toast),
    next_id: u64,
    pending: std.ArrayListUnmanaged(Toast),

    pub fn init(alloc: Allocator) ToastStack {
        return .{
            .alloc = alloc,
            .toasts = .{},
            .next_id = 1,
            .pending = .{},
        };
    }

    pub fn deinit(self: *ToastStack) void {
        for (self.toasts.items) |t| {
            self.alloc.free(t.title);
            self.alloc.free(t.body);
        }
        self.toasts.deinit(self.alloc);
        for (self.pending.items) |t| {
            self.alloc.free(t.title);
            self.alloc.free(t.body);
        }
        self.pending.deinit(self.alloc);
    }

    /// Enqueue a new toast.  Title and body are copied; the stack owns
    /// the duplicates.  Returns the assigned id for later dismiss/hover.
    pub fn push(
        self: *ToastStack,
        title: []const u8,
        body: []const u8,
        severity: Severity,
        now_ms: u64,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        const owned_title = try self.alloc.dupe(u8, title);
        errdefer self.alloc.free(owned_title);
        const owned_body = try self.alloc.dupe(u8, body);
        errdefer self.alloc.free(owned_body);

        const toast: Toast = .{
            .title = owned_title,
            .body = owned_body,
            .severity = severity,
            .created_ms = now_ms,
            .auto_dismiss_ms = default_auto_dismiss_ms,
            .id = id,
        };

        if (self.toasts.items.len < max_visible) {
            try self.toasts.append(self.alloc, toast);
        } else {
            try self.pending.append(self.alloc, toast);
        }
        return id;
    }

    /// Remove a toast by id.  Frees owned bytes and promotes one
    /// pending toast if available.
    pub fn dismiss(self: *ToastStack, id: u64, now_ms: u64) void {
        if (self.removeFromList(&self.toasts, id)) {
            self.promoteOne(now_ms);
            return;
        }
        _ = self.removeFromList(&self.pending, id);
    }

    /// Tick the stack: expire old toasts, promote pending, recompute
    /// target positions.  Returns `true` if anything changed.
    pub fn tick(self: *ToastStack, now_ms: u64) bool {
        var changed = false;

        // Expire visible toasts (iterate backwards for safe removal).
        var i: usize = self.toasts.items.len;
        while (i > 0) {
            i -= 1;
            const t = &self.toasts.items[i];
            if (isExpired(t, now_ms)) {
                self.freeToast(t);
                _ = self.toasts.orderedRemove(i);
                changed = true;
            }
        }

        // Promote pending entries into freed visible slots.
        while (self.toasts.items.len < max_visible and self.pending.items.len > 0) {
            var promoted = self.pending.orderedRemove(0);
            promoted.created_ms = now_ms;
            promoted.hover_pause_ms = 0;
            self.toasts.append(self.alloc, promoted) catch break;
            changed = true;
        }

        // Recompute target_y_offset for every visible toast.
        for (self.toasts.items, 0..) |*t, idx| {
            const fi: f32 = @floatFromInt(idx);
            const target = stack_edge_margin_dp + fi * (toast_height_dp + toast_gap_dp);
            if (t.target_y_offset != target) {
                t.target_y_offset = target;
                changed = true;
            }
        }

        return changed;
    }

    /// Mark a toast as hovered or un-hovered.  Hovered toasts accumulate
    /// pause time that extends their effective lifetime.
    pub fn setHovered(self: *ToastStack, id: u64, hovered: bool, now_ms: u64) void {
        const t = self.findById(id) orelse return;
        if (hovered and !t.hovered) {
            t.hovered = true;
            t.hover_start_ms = now_ms;
        } else if (!hovered and t.hovered) {
            t.hovered = false;
            if (t.hover_start_ms > 0) {
                t.hover_pause_ms += now_ms -| t.hover_start_ms;
                t.hover_start_ms = 0;
            }
        }
    }

    /// True if the stack has any visible or pending toasts.
    pub fn hasAny(self: *const ToastStack) bool {
        return self.toasts.items.len > 0 or self.pending.items.len > 0;
    }

    // ── internals ────────────────────────────────────────────────────

    fn isExpired(t: *const Toast, now_ms: u64) bool {
        if (t.auto_dismiss_ms == 0) return false;
        if (t.hovered) return false;
        const age = now_ms -| t.created_ms;
        const effective = age -| t.hover_pause_ms;
        return effective >= t.auto_dismiss_ms;
    }

    fn findById(self: *ToastStack, id: u64) ?*Toast {
        for (self.toasts.items) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    fn removeFromList(self: *ToastStack, list: *std.ArrayListUnmanaged(Toast), id: u64) bool {
        for (list.items, 0..) |*t, idx| {
            if (t.id == id) {
                self.freeToast(t);
                _ = list.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    fn promoteOne(self: *ToastStack, now_ms: u64) void {
        if (self.toasts.items.len >= max_visible) return;
        if (self.pending.items.len == 0) return;
        var promoted = self.pending.orderedRemove(0);
        promoted.created_ms = now_ms;
        promoted.hover_pause_ms = 0;
        self.toasts.append(self.alloc, promoted) catch {};
    }

    fn freeToast(self: *ToastStack, t: *Toast) void {
        self.alloc.free(t.title);
        self.alloc.free(t.body);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "push copies strings and assigns unique ids" {
    var stack = ToastStack.init(std.testing.allocator);
    defer stack.deinit();

    const id1 = try stack.push("Title A", "Body A", .info, 1000);
    const id2 = try stack.push("Title B", "Body B", .warn, 1001);

    try std.testing.expect(id1 != id2);
    try std.testing.expectEqualStrings("Title A", stack.toasts.items[0].title);
    try std.testing.expectEqualStrings("Body B", stack.toasts.items[1].body);

    // Deep copy — different pointers.
    try std.testing.expect(stack.toasts.items[0].title.ptr != @as([*]const u8, "Title A".ptr));
}

test "push beyond max_visible queues to pending" {
    var stack = ToastStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.push("T1", "B1", .info, 0);
    _ = try stack.push("T2", "B2", .info, 0);
    _ = try stack.push("T3", "B3", .info, 0);
    _ = try stack.push("T4", "B4", .info, 0);
    _ = try stack.push("T5", "B5", .info, 0);

    try std.testing.expectEqual(@as(usize, 3), stack.toasts.items.len);
    try std.testing.expectEqual(@as(usize, 2), stack.pending.items.len);
}

test "tick expires old toasts and promotes pending" {
    var stack = ToastStack.init(std.testing.allocator);
    defer stack.deinit();

    const id1 = try stack.push("T1", "B1", .info, 0);
    _ = try stack.push("T2", "B2", .info, 100);
    _ = try stack.push("T3", "B3", .info, 200);
    _ = try stack.push("T4", "B4", .info, 300);

    try std.testing.expectEqual(@as(usize, 3), stack.toasts.items.len);
    try std.testing.expectEqual(@as(usize, 1), stack.pending.items.len);

    // Advance past T1's expiry (created 0 + 3000 ms).
    const changed = stack.tick(3001);
    try std.testing.expect(changed);

    // T1 should be gone; T4 promoted.
    for (stack.toasts.items) |t| {
        try std.testing.expect(t.id != id1);
    }
    try std.testing.expectEqual(@as(usize, 3), stack.toasts.items.len);
    try std.testing.expectEqual(@as(usize, 0), stack.pending.items.len);
}

test "setHovered pauses auto-dismiss" {
    var stack = ToastStack.init(std.testing.allocator);
    defer stack.deinit();

    const id = try stack.push("Hov", "Body", .success, 0);

    // Hover at t=1000.
    stack.setHovered(id, true, 1000);

    // Advance well past default_auto_dismiss_ms while hovered.
    _ = stack.tick(5000);
    try std.testing.expectEqual(@as(usize, 1), stack.toasts.items.len);

    // Un-hover at t=5000 (4000 ms of pause accumulated).
    stack.setHovered(id, false, 5000);

    // At t=5000 effective age = 5000 - 4000 = 1000 — not expired yet.
    _ = stack.tick(5000);
    try std.testing.expectEqual(@as(usize, 1), stack.toasts.items.len);

    // At t=8000 effective age = 8000 - 4000 = 4000 >= 3000 — expired.
    _ = stack.tick(8000);
    try std.testing.expectEqual(@as(usize, 0), stack.toasts.items.len);
}

test "dismiss by id frees entry and promotes pending" {
    var stack = ToastStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.push("T1", "B1", .info, 0);
    const id2 = try stack.push("T2", "B2", .warn, 0);
    _ = try stack.push("T3", "B3", .err, 0);
    _ = try stack.push("T4", "B4", .success, 0);

    try std.testing.expectEqual(@as(usize, 3), stack.toasts.items.len);
    try std.testing.expectEqual(@as(usize, 1), stack.pending.items.len);

    // Dismiss the middle visible toast.
    stack.dismiss(id2, 500);

    try std.testing.expectEqual(@as(usize, 3), stack.toasts.items.len);
    try std.testing.expectEqual(@as(usize, 0), stack.pending.items.len);

    // Verify id2 is no longer present.
    for (stack.toasts.items) |t| {
        try std.testing.expect(t.id != id2);
    }
}

test "target_y_offset reflects stack position" {
    var stack = ToastStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.push("T1", "B1", .info, 0);
    _ = try stack.push("T2", "B2", .info, 0);
    _ = try stack.push("T3", "B3", .info, 0);

    _ = stack.tick(0);

    // Expected: 16, 16+80=96, 16+160=176
    try std.testing.expectEqual(@as(f32, 16.0), stack.toasts.items[0].target_y_offset);
    try std.testing.expectEqual(@as(f32, 96.0), stack.toasts.items[1].target_y_offset);
    try std.testing.expectEqual(@as(f32, 176.0), stack.toasts.items[2].target_y_offset);
}

test "deinit frees all owned bytes and pending bytes" {
    // The testing allocator detects leaks automatically.
    var stack = ToastStack.init(std.testing.allocator);

    _ = try stack.push("Visible 1", "Body 1", .info, 0);
    _ = try stack.push("Visible 2", "Body 2", .warn, 0);
    _ = try stack.push("Visible 3", "Body 3", .err, 0);
    _ = try stack.push("Pending 1", "Body P1", .success, 0);
    _ = try stack.push("Pending 2", "Body P2", .info, 0);

    stack.deinit();
}
