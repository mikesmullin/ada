//! Easing curves ported from Game9 (`Math.c` / `easy()`).
//! `t` is progress in 0..1; results are clamped-friendly (callers may pass unclamped).

const std = @import("std");
const math = std.math;

pub fn lerp(t: f32, a: f32, b: f32) f32 {
    return a + (b - a) * t;
}

pub fn clamp01(t: f32) f32 {
    return @max(0.0, @min(1.0, t));
}

pub const Easing = enum {
    linear,
    in_sine,
    out_sine,
    in_out_sine,
    in_quad,
    out_quad,
    in_out_quad,
    in_quart,
    out_quart,
    in_out_quart,
    in_expo,
    out_expo,
};

/// Game9 `easy(ease, t)` — apply named curve to progress.
pub fn easy(ease: Easing, t: f32) f32 {
    const x = clamp01(t);
    return switch (ease) {
        .linear => x,
        .in_sine => 1.0 - @cos((x * math.pi) / 2.0),
        .out_sine => @sin((x * math.pi) / 2.0),
        .in_out_sine => -(@cos(math.pi * x) - 1.0) / 2.0,
        .in_quad => x * x,
        .out_quad => 1.0 - (1.0 - x) * (1.0 - x),
        .in_out_quad => if (x < 0.5) 2.0 * x * x else 1.0 - pow2(-2.0 * x + 2.0) / 2.0,
        .in_quart => x * x * x * x,
        .out_quart => 1.0 - pow4(1.0 - x),
        .in_out_quart => if (x < 0.5) 8.0 * x * x * x * x else 1.0 - pow4(-2.0 * x + 2.0) / 2.0,
        .in_expo => if (x == 0.0) 0.0 else math.pow(f32, 2.0, 10.0 * x - 10.0),
        .out_expo => if (x == 1.0) 1.0 else 1.0 - math.pow(f32, 2.0, -10.0 * x),
    };
}

fn pow2(v: f32) f32 {
    return v * v;
}
fn pow4(v: f32) f32 {
    const v2 = v * v;
    return v2 * v2;
}
