const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

// Parse OSC 22
pub fn parse(parser: anytype, _: ?u8) ?*@TypeOf(parser.command) {
    assert(parser.state == .@"22");
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    parser.command = .{
        .mouse_shape = .{
            .value = data[0 .. data.len - 1 :0],
        },
    };
    return &parser.command;
}

test "OSC 22: pointer cursor" {
    const testing = std.testing;

    var p = @import("../../osc.zig").Parser.init(null);

    const input = "22;pointer";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .mouse_shape);
    try testing.expectEqualStrings("pointer", cmd.mouse_shape.value);
}
