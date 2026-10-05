//! The text and the place of the password prompt, without Wayland objects or
//! fonts. Prompt.zig draws the result. `zig build test` runs the tests below.
//!
//!     Locked. Type your password:
//!     *******_

const std = @import("std");
const testing = std.testing;

pub const title = "Locked. Type your password:";

/// The character for each code point of the password.
pub const mask = '*';
/// The cursor after the last mask character.
pub const cursor = '_';

/// Writes the second line into `out`: one mask character for each code point
/// of the password, then the cursor. When `out` is too short, the line keeps
/// the cursor and as many mask characters as fit. Returns the line.
pub fn password_line(out: []u32, codepoints: usize) []u32 {
    if (out.len == 0) return out[0..0];
    const count = @min(codepoints, out.len - 1);
    @memset(out[0..count], mask);
    out[count] = cursor;
    return out[0 .. count + 1];
}

/// The text box in the coordinates of the surface (logical pixels), and the
/// size of its buffer (buffer pixels).
pub const Box = struct {
    x: i32,
    y: i32,
    buffer_width: i32,
    buffer_height: i32,
};

/// The box of the prompt on an output of `output_width` x `output_height`
/// logical pixels. `title_width`, `line_width` and `line_height` are in buffer
/// pixels, at `scale`.
///
/// The title is in the center of the output. Each line starts at the left
/// edge of the title, thus a long password extends to the right and the title
/// does not move. The buffer stops at the right edge of the output. The
/// buffer size is a multiple of the scale, as wl_surface.set_buffer_scale
/// requires.
pub fn box(
    output_width: i32,
    output_height: i32,
    scale: i32,
    title_width: i32,
    line_width: i32,
    line_height: i32,
) Box {
    const height = round_up(2 * line_height, scale);
    const x = @max(0, @divFloor(output_width - @divFloor(title_width, scale), 2));
    const y = @max(0, @divFloor(output_height - @divFloor(height, scale), 2));
    const max_width = (output_width - x) * scale;
    const width = @min(round_up(@max(title_width, line_width), scale), max_width);
    return .{
        .x = x,
        .y = y,
        .buffer_width = @max(scale, width),
        .buffer_height = @max(scale, height),
    };
}

fn round_up(value: i32, multiple: i32) i32 {
    return @divFloor(value + multiple - 1, multiple) * multiple;
}

test "password_line: a mask character for each code point, then the cursor" {
    var out: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{'_'}, password_line(&out, 0));
    try testing.expectEqualSlices(u32, &.{ '*', '*', '*', '_' }, password_line(&out, 3));
}

test "password_line: a long password keeps the cursor" {
    var out: [4]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ '*', '*', '*', '_' }, password_line(&out, 100));
    var empty: [0]u32 = undefined;
    try testing.expectEqual(@as(usize, 0), password_line(&empty, 5).len);
}

test "box: the title is in the center of the output" {
    // Scale 1, a title of 216 pixels and lines of 16 pixels.
    const b = box(1280, 720, 1, 216, 8, 16);
    try testing.expectEqual(@as(i32, (1280 - 216) / 2), b.x);
    try testing.expectEqual(@as(i32, (720 - 32) / 2), b.y);
    try testing.expectEqual(@as(i32, 216), b.buffer_width);
    try testing.expectEqual(@as(i32, 32), b.buffer_height);
}

test "box: at scale 2 the position is in logical pixels" {
    const b = box(1280, 720, 2, 432, 16, 32);
    try testing.expectEqual(@as(i32, (1280 - 216) / 2), b.x);
    try testing.expectEqual(@as(i32, (720 - 32) / 2), b.y);
    try testing.expectEqual(@as(i32, 432), b.buffer_width);
    try testing.expectEqual(@as(i32, 64), b.buffer_height);
}

test "box: the buffer size is a multiple of the scale" {
    const b = box(1280, 720, 2, 431, 16, 33);
    try testing.expectEqual(@as(i32, 0), @mod(b.buffer_width, 2));
    try testing.expectEqual(@as(i32, 0), @mod(b.buffer_height, 2));
}

test "box: a long password does not move the title" {
    const short = box(1280, 720, 1, 216, 8, 16);
    const long = box(1280, 720, 1, 216, 400, 16);
    try testing.expectEqual(short.x, long.x);
    try testing.expectEqual(@as(i32, 400), long.buffer_width);
}

test "box: the buffer stops at the right edge of the output" {
    const b = box(1280, 720, 1, 216, 5000, 16);
    try testing.expectEqual(@as(i32, 1280 - b.x), b.buffer_width);
}

test "box: a title wider than the output starts at the left edge" {
    const b = box(100, 50, 1, 216, 8, 16);
    try testing.expectEqual(@as(i32, 0), b.x);
    try testing.expectEqual(@as(i32, 100), b.buffer_width);
}
