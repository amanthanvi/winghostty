//! Bounded undo/redo stack for recoverable destructive operations.
//!
//! Pure bookkeeping: stores opaque snapshots of clear_screen, reset,
//! close_tab, and split_create actions. Capture and replay logic lives
//! in the Win32 apprt surface; this module only manages the stack and
//! memory budget.
//!
//! Two caps are load-bearing for memory safety in long sessions:
//!   - `max_entries` (16) prevents unbounded list growth.
//!   - `max_total_bytes` (8 MB) caps retained scrollback / palette
//!     blobs so a heavy terminal session doesn't balloon RSS.
//! Both are enforced on every `push`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { clear_screen, reset, close_tab, split_create };

pub const ClearScreenSnapshot = struct {
    scrollback_bytes: []u8,
};

pub const ResetSnapshot = struct {
    palette_blob: []u8,
    modes_blob: []u8,
};

pub const CloseTabSnapshot = struct {
    scrollback_bytes: []u8,
    title: []u8,
};

pub const SplitCreateSnapshot = struct {
    split_index: usize,
};

pub const Snapshot = union(Kind) {
    clear_screen: ClearScreenSnapshot,
    reset: ResetSnapshot,
    close_tab: CloseTabSnapshot,
    split_create: SplitCreateSnapshot,
};

pub const Entry = struct {
    kind: Kind,
    snapshot: Snapshot,
    timestamp_ms: u64,

    /// Owned-byte footprint used for cap accounting.
    pub fn byteSize(self: Entry) usize {
        return switch (self.snapshot) {
            .clear_screen => |s| s.scrollback_bytes.len,
            .reset => |s| s.palette_blob.len + s.modes_blob.len,
            .close_tab => |s| s.scrollback_bytes.len + s.title.len,
            .split_create => 0,
        };
    }

    /// Frees every owned byte slice inside the snapshot.
    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.snapshot) {
            .clear_screen => |s| alloc.free(s.scrollback_bytes),
            .reset => |s| {
                alloc.free(s.palette_blob);
                alloc.free(s.modes_blob);
            },
            .close_tab => |s| {
                alloc.free(s.scrollback_bytes);
                alloc.free(s.title);
            },
            .split_create => {},
        }
    }
};

pub const max_entries: usize = 16;
pub const max_total_bytes: usize = 8 * 1024 * 1024;

pub const UndoStack = struct {
    alloc: Allocator,
    entries: std.ArrayListUnmanaged(Entry),
    redo_entries: std.ArrayListUnmanaged(Entry),
    total_bytes: usize,

    pub fn init(alloc: Allocator) UndoStack {
        return .{
            .alloc = alloc,
            .entries = .{},
            .redo_entries = .{},
            .total_bytes = 0,
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.entries.items) |*e| e.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        for (self.redo_entries.items) |*e| e.deinit(self.alloc);
        self.redo_entries.deinit(self.alloc);
        self.total_bytes = 0;
    }

    /// Push a new entry, taking ownership of its snapshot allocations.
    /// Clears the redo branch and evicts oldest undo entries until both
    /// caps (count + bytes) are satisfied.
    pub fn push(self: *UndoStack, entry: Entry) Allocator.Error!void {
        // New action invalidates the redo branch.
        self.clearRedo();

        const incoming = entry.byteSize();

        // Evict oldest entries until the byte cap has room (or stack empty).
        while (self.entries.items.len > 0 and
            self.total_bytes + incoming > max_total_bytes)
        {
            self.evictOldest();
        }

        // Evict oldest entries until the count cap has room.
        while (self.entries.items.len >= max_entries) {
            self.evictOldest();
        }

        try self.entries.append(self.alloc, entry);
        self.total_bytes += incoming;
    }

    /// Move the newest undo entry to the redo stack and return a
    /// borrowed pointer into the redo list so the caller can replay
    /// its snapshot. The pointer is only valid until the next mutation
    /// of `redo_entries`; callers must consume it synchronously.
    ///
    /// Never returns an entry by value: the snapshot holds owned byte
    /// slices, so copying the Entry would create aliasing between the
    /// redo slot and the caller's copy — a latent UAF / double-free if
    /// the caller deinits.
    pub fn popForUndo(self: *UndoStack) ?*const Entry {
        const entry = self.entries.pop() orelse return null;
        self.total_bytes -= entry.byteSize();
        self.redo_entries.append(self.alloc, entry) catch {
            // Redo-append failed (OOM). The entry is still owned by
            // the stack via the temporary on-stack variable; put it
            // back on the undo stack so nothing leaks and the operation
            // effectively becomes a no-op.
            self.total_bytes += entry.byteSize();
            self.entries.append(self.alloc, entry) catch {
                // Both appends failed. Free the entry ourselves rather
                // than leaking it — the stack is the owner.
                var tmp = entry;
                tmp.deinit(self.alloc);
                self.total_bytes -= entry.byteSize();
            };
            return null;
        };
        return &self.redo_entries.items[self.redo_entries.items.len - 1];
    }

    /// Move the newest redo entry back onto the undo stack and return
    /// a borrowed pointer into the undo list. Same lifetime rules as
    /// `popForUndo`.
    pub fn popForRedo(self: *UndoStack) ?*const Entry {
        const entry = self.redo_entries.pop() orelse return null;
        self.entries.append(self.alloc, entry) catch {
            // Undo-append failed; restore to redo so nothing leaks.
            self.redo_entries.append(self.alloc, entry) catch {
                var tmp = entry;
                tmp.deinit(self.alloc);
            };
            return null;
        };
        self.total_bytes += entry.byteSize();
        return &self.entries.items[self.entries.items.len - 1];
    }

    pub fn undoDepth(self: *const UndoStack) usize {
        return self.entries.items.len;
    }

    pub fn redoDepth(self: *const UndoStack) usize {
        return self.redo_entries.items.len;
    }

    // -- internal helpers --------------------------------------------------

    fn evictOldest(self: *UndoStack) void {
        var oldest = self.entries.orderedRemove(0);
        self.total_bytes -= oldest.byteSize();
        oldest.deinit(self.alloc);
    }

    fn clearRedo(self: *UndoStack) void {
        // Do NOT subtract `e.byteSize()` from `total_bytes` — redo
        // entries already had their bytes deducted when they moved
        // from undo → redo in `popForUndo`, and `total_bytes` is
        // documented as tracking only the undo-stack footprint for
        // cap enforcement. Subtracting again would underflow on the
        // common "undo, then perform a new action" sequence (panic
        // in safe builds; wrap to a huge value in release).
        for (self.redo_entries.items) |*e| {
            e.deinit(self.alloc);
        }
        self.redo_entries.clearAndFree(self.alloc);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeSmallEntry(alloc: Allocator, id: u8) Allocator.Error!Entry {
    const buf = try alloc.alloc(u8, 4);
    @memset(buf, id);
    return .{
        .kind = .clear_screen,
        .snapshot = .{ .clear_screen = .{ .scrollback_bytes = buf } },
        .timestamp_ms = id,
    };
}

fn makeSizedEntry(alloc: Allocator, size: usize, ts: u64) Allocator.Error!Entry {
    const buf = try alloc.alloc(u8, size);
    @memset(buf, 0xAB);
    return .{
        .kind = .clear_screen,
        .snapshot = .{ .clear_screen = .{ .scrollback_bytes = buf } },
        .timestamp_ms = ts,
    };
}

test "push enforces entry count cap" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    for (0..20) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }
    try std.testing.expectEqual(max_entries, stack.undoDepth());
    // Oldest 4 (timestamps 0-3) were evicted; newest starts at 4.
    try std.testing.expectEqual(@as(u64, 4), stack.entries.items[0].timestamp_ms);
}

test "push enforces byte cap" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const chunk: usize = 2 * 1024 * 1024; // 2 MB each
    for (0..8) |i| {
        const entry = try makeSizedEntry(alloc, chunk, @intCast(i));
        try stack.push(entry);
        try std.testing.expect(stack.total_bytes <= max_total_bytes);
    }
    // 8 MB cap / 2 MB each = at most 4 entries.
    try std.testing.expect(stack.undoDepth() <= 4);
}

test "push clears redo stack" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const a = try makeSmallEntry(alloc, 1);
    const b = try makeSmallEntry(alloc, 2);
    try stack.push(a);
    try stack.push(b);

    _ = stack.popForUndo(); // B goes to redo
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());

    const c = try makeSmallEntry(alloc, 3);
    try stack.push(c); // clears redo
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
    try std.testing.expectEqual(@as(usize, 2), stack.undoDepth());
}

test "push after undo does not underflow total_bytes" {
    // Regression: `clearRedo` previously subtracted redo bytes from
    // `total_bytes`, but `popForUndo` already did that when moving
    // the entry off the undo stack. The combined effect was an
    // underflow the first time the user hit undo-then-push.
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const a = try makeSmallEntry(alloc, 1);
    const a_size = a.byteSize();
    try stack.push(a);
    try std.testing.expectEqual(a_size, stack.total_bytes);

    _ = stack.popForUndo(); // undo A → redo
    try std.testing.expectEqual(@as(usize, 0), stack.total_bytes);

    const b = try makeSmallEntry(alloc, 2);
    const b_size = b.byteSize();
    try stack.push(b); // clearRedo must not underflow
    try std.testing.expectEqual(b_size, stack.total_bytes);
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
}

test "popForUndo returns newest" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    for (1..4) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }

    const e3 = stack.popForUndo().?;
    try std.testing.expectEqual(@as(u64, 3), e3.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 2), stack.undoDepth());

    const e2 = stack.popForUndo().?;
    try std.testing.expectEqual(@as(u64, 2), e2.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
}

test "popForUndo moves to redo and popForRedo moves back" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const entry = try makeSmallEntry(alloc, 42);
    try stack.push(entry);

    {
        const popped = stack.popForUndo().?;
        try std.testing.expectEqual(@as(u64, 42), popped.timestamp_ms);
    }
    try std.testing.expectEqual(@as(usize, 0), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());

    {
        const restored = stack.popForRedo().?;
        try std.testing.expectEqual(@as(u64, 42), restored.timestamp_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
}

test "deinit frees everything" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);

    for (0..5) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }
    // Move one to redo so both lists hold owned memory.
    _ = stack.popForUndo();

    // deinit must free all; testing allocator asserts no leaks.
    stack.deinit();
}

test "single oversized entry is accepted and empties the rest" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    // Push a few small entries.
    for (0..5) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }
    try std.testing.expectEqual(@as(usize, 5), stack.undoDepth());

    // Push one oversized entry (> max_total_bytes).
    const big = try makeSizedEntry(alloc, max_total_bytes + 1024, 99);
    try stack.push(big);

    // All small entries evicted; oversized one survives alone.
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(u64, 99), stack.entries.items[0].timestamp_ms);
}
