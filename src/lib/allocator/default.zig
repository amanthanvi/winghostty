const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Returns the allocator used when the C API is not given a custom allocator.
pub fn fallback() std.mem.Allocator {
    // Tests always use the test allocator so we can detect leaks.
    if (comptime builtin.is_test) return testing.allocator;

    // If we have libc, use that. We prefer libc if we have it because
    // its generally fast but also lets the embedder easily override
    // malloc/free with custom allocators like mimalloc or something.
    if (comptime builtin.link_libc) return std.heap.c_allocator;

    // Wasm
    if (comptime builtin.target.cpu.arch.isWasm()) return std.heap.wasm_allocator;

    // No libc, use the preferred allocator for releases which is the
    // Zig SMP allocator.
    return std.heap.smp_allocator;
}

/// Returns the explicit C allocator when present, otherwise the platform
/// fallback allocator.
pub fn default(comptime Allocator: type, c_alloc_: ?*const Allocator) std.mem.Allocator {
    if (c_alloc_) |c_alloc| return c_alloc.zig();
    return fallback();
}

test "fallback allocator can allocate" {
    const alloc = fallback();
    const str = try alloc.alloc(u8, 10);
    defer alloc.free(str);
    try testing.expectEqual(10, str.len);
}
