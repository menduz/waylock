const Output = @This();

const std = @import("std");
const log = std.log;
const math = std.math;
const mem = std.mem;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const ext = wayland.client.ext;

const Lock = @import("Lock.zig");
const Prompt = @import("Prompt.zig");

lock: *Lock,
name: u32,
wl_output: *wl.Output,
surface: ?*wl.Surface = null,
viewport: ?*wp.Viewport = null,
lock_surface: ?*ext.SessionLockSurfaceV1 = null,
prompt: ?Prompt = null,
/// The scale of wl_output. The prompt draws its text at this scale.
scale: i32 = 1,

configured: bool = false,
// These fields are not used before the first configure is received.
width: u31 = undefined,
height: u31 = undefined,

link: wl.list.Link,

pub fn create_surface(output: *Output) !void {
    const surface = try output.lock.compositor.?.createSurface();
    output.surface = surface;

    const lock_surface = try output.lock.session_lock.?.getLockSurface(surface, output.wl_output);
    lock_surface.setListener(*Output, lock_surface_listener, output);
    output.lock_surface = lock_surface;

    output.viewport = try output.lock.viewporter.?.getViewport(surface);

    output.prompt = @as(Prompt, undefined);
    output.prompt.?.init(
        output.lock.prompt_options,
        output.lock.compositor.?,
        output.lock.subcompositor.?,
        output.lock.shm.?,
        surface,
    ) catch |err| {
        // The lock works without the prompt.
        log.err("failed to create the password prompt: {s}", .{@errorName(err)});
        output.prompt = null;
    };
}

pub fn listen(output: *Output) void {
    output.wl_output.setListener(*Output, output_listener, output);
}

fn output_listener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .scale => |ev| output.scale = @max(1, ev.factor),
        .done => output.render_prompt(),
        else => {},
    }
}

/// Draws the prompt with the current password. It does nothing before the
/// first configure.
pub fn render_prompt(output: *Output) void {
    if (!output.configured) return;
    const prompt = &(output.prompt orelse return);
    prompt.render(.{
        .output_width = output.width,
        .output_height = output.height,
        .scale = output.scale,
        .codepoints = output.lock.password.codepoints(),
    });
}

pub fn destroy(output: *Output) void {
    output.wl_output.release();
    if (output.prompt) |*prompt| prompt.deinit();
    if (output.viewport) |viewport| viewport.destroy();
    if (output.lock_surface) |lock_surface| lock_surface.destroy();
    if (output.surface) |surface| surface.destroy();

    output.link.remove();
    output.lock.gpa.destroy(output);
}

fn lock_surface_listener(
    _: *ext.SessionLockSurfaceV1,
    event: ext.SessionLockSurfaceV1.Event,
    output: *Output,
) void {
    const lock = output.lock;
    switch (event) {
        .configure => |ev| {
            output.configured = true;
            output.width = @min(std.math.maxInt(u31), ev.width);
            output.height = @min(std.math.maxInt(u31), ev.height);
            output.lock_surface.?.ackConfigure(ev.serial);
            output.render_prompt();
            output.attach_buffer(lock.buffers[@intFromEnum(lock.color)]);
        },
    }
}

pub fn attach_buffer(output: *Output, buffer: *wl.Buffer) void {
    if (!output.configured) return;
    output.surface.?.attach(buffer, 0, 0);
    output.surface.?.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
    output.viewport.?.setDestination(output.width, output.height);
    output.surface.?.commit();
}
