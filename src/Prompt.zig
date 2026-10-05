//! The password prompt in the center of an output. A subsurface of the lock
//! surface holds the text. Its buffer is transparent except for the glyphs,
//! thus the color of the lock surface shows around them. prompt_layout.zig
//! gives the text and the place.
//!
//! An error here must never stop the lock. Thus each error is logged, and the
//! output then shows no prompt.
const Prompt = @This();

const std = @import("std");
const fmt = std.fmt;
const log = std.log;
const math = std.math;
const posix = std.posix;
const system = posix.system;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const pixman = @import("pixman");
const fcft = @import("fcft");

const layout = @import("prompt_layout.zig");

/// The fcft font names for the prompt. The second one is the fallback.
pub const Options = struct {
    font: [:0]const u8 = "Terminus:size=12",
    text_color: u24 = 0xffffff,
};

const fallback_font = "monospace:size=12";

/// A wl_buffer in shared memory, with a pixman image of the same memory.
const Buffer = struct {
    prompt: *Prompt,
    wl_buffer: ?*wl.Buffer = null,
    image: ?*pixman.Image = null,
    data: []align(std.heap.page_size_min) u8 = &.{},
    width: i32 = 0,
    height: i32 = 0,
    busy: bool = false,

    fn init(buffer: *Buffer, shm: *wl.Shm, width: i32, height: i32) !void {
        buffer.deinit();

        const stride = width * 4;
        const size: usize = @intCast(stride * height);

        const fd = try posix.memfd_create("waylock-prompt", std.os.linux.MFD.CLOEXEC);
        defer _ = system.close(fd);
        switch (posix.errno(system.ftruncate(fd, @intCast(size)))) {
            .SUCCESS => {},
            else => return error.Truncate,
        }

        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        const pool = try shm.createPool(fd, @intCast(size));
        defer pool.destroy();

        const wl_buffer = try pool.createBuffer(0, width, height, stride, .argb8888);
        errdefer wl_buffer.destroy();
        wl_buffer.setListener(*Buffer, buffer_listener, buffer);

        const image = pixman.Image.createBitsNoClear(
            .a8r8g8b8,
            width,
            height,
            @ptrCast(data.ptr),
            stride,
        ) orelse return error.OutOfMemory;

        buffer.* = .{
            .prompt = buffer.prompt,
            .wl_buffer = wl_buffer,
            .image = image,
            .data = data,
            .width = width,
            .height = height,
        };
    }

    fn deinit(buffer: *Buffer) void {
        if (buffer.wl_buffer) |wl_buffer| wl_buffer.destroy();
        if (buffer.image) |image| _ = image.unref();
        if (buffer.data.len > 0) posix.munmap(buffer.data);
        buffer.* = .{ .prompt = buffer.prompt };
    }

    fn buffer_listener(_: *wl.Buffer, event: wl.Buffer.Event, buffer: *Buffer) void {
        switch (event) {
            .release => {
                buffer.busy = false;
                // A render found no free buffer. Do it now.
                if (buffer.prompt.pending) |pending| buffer.prompt.render(pending);
            },
        }
    }
};

/// The values of a render. render() keeps them when both buffers are busy.
pub const State = struct {
    output_width: u31,
    output_height: u31,
    scale: i32,
    codepoints: usize,
};

options: Options,
shm: *wl.Shm,
surface: *wl.Surface,
subsurface: *wl.Subsurface,
font: ?*fcft.Font = null,
font_scale: i32 = 0,
buffers: [2]Buffer,
pending: ?State = null,

/// Makes the subsurface of the prompt above `parent`. The caller must not
/// move the Prompt after this call: the buffers point to it.
pub fn init(
    prompt: *Prompt,
    options: Options,
    compositor: *wl.Compositor,
    subcompositor: *wl.Subcompositor,
    shm: *wl.Shm,
    parent: *wl.Surface,
) !void {
    const surface = try compositor.createSurface();
    errdefer surface.destroy();
    const subsurface = try subcompositor.getSubsurface(surface, parent);
    errdefer subsurface.destroy();
    // A commit of the prompt shows at once, without a commit of the parent.
    // Only the position waits for the next commit of the parent.
    subsurface.setDesync();

    // The input goes to the lock surface below.
    const region = try compositor.createRegion();
    defer region.destroy();
    surface.setInputRegion(region);

    prompt.* = .{
        .options = options,
        .shm = shm,
        .surface = surface,
        .subsurface = subsurface,
        .buffers = .{ .{ .prompt = prompt }, .{ .prompt = prompt } },
    };
}

pub fn deinit(prompt: *Prompt) void {
    for (&prompt.buffers) |*buffer| buffer.deinit();
    if (prompt.font) |font| font.destroy();
    prompt.subsurface.destroy();
    prompt.surface.destroy();
}

/// Draws the prompt and commits the subsurface.
pub fn render(prompt: *Prompt, state: State) void {
    prompt.draw(state) catch |err| {
        log.err("failed to draw the password prompt: {s}", .{@errorName(err)});
    };
}

fn draw(prompt: *Prompt, state: State) !void {
    const font = try prompt.load_font(state.scale);

    var title: [layout.title.len]u32 = undefined;
    for (layout.title, 0..) |c, i| title[i] = c;
    const title_run = try font.rasterizeTextRunUtf32(&title, .default);
    defer title_run.destroy();

    var line_buffer: [256]u32 = undefined;
    const line = layout.password_line(&line_buffer, state.codepoints);
    const line_run = try font.rasterizeTextRunUtf32(line, .default);
    defer line_run.destroy();

    const box = layout.box(
        state.output_width,
        state.output_height,
        state.scale,
        run_width(title_run),
        run_width(line_run),
        font.height,
    );

    const buffer = for (&prompt.buffers) |*buffer| {
        if (!buffer.busy) break buffer;
    } else {
        // The compositor still reads both buffers. Draw at the next release.
        prompt.pending = state;
        return;
    };
    prompt.pending = null;

    if (buffer.width != box.buffer_width or buffer.height != box.buffer_height) {
        try buffer.init(prompt.shm, box.buffer_width, box.buffer_height);
    }

    // Transparent: all bytes of a8r8g8b8 are 0.
    @memset(buffer.data, 0);

    const color = pixman_color(prompt.options.text_color);
    try draw_run(buffer, font, title_run, &color, 0, 0);
    try draw_run(buffer, font, line_run, &color, 0, font.height);

    prompt.subsurface.setPosition(box.x, box.y);
    prompt.surface.setBufferScale(state.scale);
    prompt.surface.attach(buffer.wl_buffer.?, 0, 0);
    prompt.surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
    prompt.surface.commit();
    buffer.busy = true;
}

/// The font at `scale`. A new scale loads the font again.
fn load_font(prompt: *Prompt, scale: i32) !*fcft.Font {
    if (prompt.font) |font| {
        if (prompt.font_scale == scale) return font;
        font.destroy();
        prompt.font = null;
    }

    var names = [_][*:0]const u8{ prompt.options.font.ptr, fallback_font };
    var attributes: [16]u8 = undefined;
    const dpi = try fmt.bufPrintZ(&attributes, "dpi={d}", .{96 * scale});

    const font = try fcft.Font.fromName(&names, dpi.ptr);
    prompt.font = font;
    prompt.font_scale = scale;
    return font;
}

fn run_width(run: *const fcft.TextRun) i32 {
    var width: i32 = 0;
    for (run.glyphs[0..run.count]) |glyph| width += glyph.advance.x;
    return width;
}

fn draw_run(
    buffer: *Buffer,
    font: *const fcft.Font,
    run: *const fcft.TextRun,
    color: *const pixman.Color,
    x: i32,
    y: i32,
) !void {
    const fill = pixman.Image.createSolidFill(color) orelse return error.OutOfMemory;
    defer _ = fill.unref();

    var offset = x;
    for (run.glyphs[0..run.count]) |glyph| {
        if (offset >= buffer.width) break;
        // A color glyph (an emoji) has its own colors. Other glyphs are a
        // mask for the text color.
        const color_glyph = glyph.pix.getFormat() == .a8r8g8b8;
        pixman.Image.composite32(
            .over,
            if (color_glyph) glyph.pix else fill,
            if (color_glyph) null else glyph.pix,
            buffer.image.?,
            0,
            0,
            0,
            0,
            offset + glyph.x,
            y + font.ascent - glyph.y,
            glyph.width,
            glyph.height,
        );
        offset += glyph.advance.x;
    }
}

fn pixman_color(rgb: u24) pixman.Color {
    return .{
        .red = @as(u16, @as(u8, @truncate(rgb >> 16))) * 0x101,
        .green = @as(u16, @as(u8, @truncate(rgb >> 8))) * 0x101,
        .blue = @as(u16, @as(u8, @truncate(rgb))) * 0x101,
        .alpha = 0xffff,
    };
}

