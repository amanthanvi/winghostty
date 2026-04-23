const std = @import("std");
const Config = @import("Config.zig");

pub const Key = Config.Key;

/// Returns the value type for a key.
pub fn Value(comptime key: Key) type {
    return Config.Value(key);
}

test "Value" {
    const testing = std.testing;

    try testing.expectEqual(Config.RepeatableString, Value(.@"font-family"));
    try testing.expectEqual(?bool, Value(.@"cursor-style-blink"));
}
