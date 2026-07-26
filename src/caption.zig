//! Caption particle system — Game9-inspired (Particle.c + Timer born_at progress).
//!
//! Each spoken sentence is a particle:
//!   - born_at wall time (0 = dead slot)
//!   - 0..1s solid, then fade to transparent by 5s (eased)
//!   - stack bottom-up: newest on the bottom
//!   - GC removes finished particles (compact, preserves birth order)

const std = @import("std");
const ease = @import("ease.zig");
const sdf_font_mod = @import("sdf_font.zig");

pub const TEXT_CAP = 256;
pub const MAX = 16;

/// Solid hold, then fade window (matches user spec).
pub const SOLID_S: f32 = 1.0;
pub const LIFE_S: f32 = 5.0;

const Particle = struct {
    /// Seconds from avatar start clock; 0 = dead (Game9 `born_at == 0`).
    born_at: f64 = 0,
    text: [TEXT_CAP]u8 = undefined,
    text_len: usize = 0,
};

pub const System = struct {
    items: [MAX]Particle = @splat(.{}),
    count: usize = 0,
    mu: std.Io.Mutex = .init,

    /// Spawn a caption particle (thread-safe). Empty text is a no-op.
    pub fn spawn(self: *System, io: std.Io, now: f64, text: []const u8) void {
        if (text.len == 0) return;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        // Full → drop oldest (shift), keep newest.
        if (self.count >= MAX) {
            var i: usize = 0;
            while (i + 1 < self.count) : (i += 1) {
                self.items[i] = self.items[i + 1];
            }
            self.count -= 1;
        }

        var p: Particle = .{ .born_at = if (now <= 0) 0.001 else now };
        const n = @min(text.len, TEXT_CAP);
        @memcpy(p.text[0..n], text[0..n]);
        p.text_len = n;
        self.items[self.count] = p;
        self.count += 1;
    }

    /// Game9 `Particle__progress`: 0 at birth, 1 at death.
    pub fn progress(born_at: f64, now: f64) f32 {
        if (born_at == 0) return 1.0;
        const age: f32 = @floatCast(now - born_at);
        return ease.clamp01(age / LIFE_S);
    }

    /// Opacity: full for SOLID_S, then ease toward 0 through LIFE_S.
    /// Fade uses easeInQuad so text stays readable longer, then drops off.
    pub fn alpha(born_at: f64, now: f64) f32 {
        if (born_at == 0) return 0.0;
        const age: f32 = @floatCast(now - born_at);
        if (age <= SOLID_S) return 1.0;
        if (age >= LIFE_S) return 0.0;
        const fade_t = (age - SOLID_S) / (LIFE_S - SOLID_S);
        // fade_t 0→1 maps alpha 1→0 with ease-in (slow start, fast end).
        return 1.0 - ease.easy(.in_quad, fade_t);
    }

    /// Expire finished particles; compact in birth order (Game9 swap-last
    /// would scramble stack order — captions need chronological order).
    pub fn update(self: *System, io: std.Io, now: f64) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        var w: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const p = self.items[i];
            if (p.born_at == 0 or progress(p.born_at, now) >= 1.0) continue;
            if (w != i) self.items[w] = p;
            w += 1;
        }
        self.count = w;
    }

    pub fn clear(self: *System, io: std.Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.count = 0;
    }

    /// Snapshot live particles for the render thread (oldest → newest).
    pub fn snapshot(
        self: *System,
        io: std.Io,
        out_text: *[MAX][TEXT_CAP]u8,
        out_len: *[MAX]usize,
        out_born: *[MAX]f64,
    ) usize {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const n = self.count;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = self.items[i];
            out_len[i] = p.text_len;
            out_born[i] = p.born_at;
            if (p.text_len > 0) {
                @memcpy(out_text[i][0..p.text_len], p.text[0..p.text_len]);
            }
        }
        return n;
    }
};

/// Draw stacked captions: newest at the bottom. Returns nothing.
pub fn drawStack(
    font: *sdf_font_mod.SdfFont,
    screen_w: f32,
    screen_h: f32,
    font_size: f32,
    now: f64,
    texts: *const [MAX][TEXT_CAP]u8,
    lens: *const [MAX]usize,
    borns: *const [MAX]f64,
    n: usize,
) void {
    if (!font.ok or n == 0 or font_size <= 0) return;

    const gap: f32 = 4.0;
    const bottom_pad: f32 = 10.0;
    const max_w_frac: f32 = 0.92;
    const rgb: [3]f32 = .{ 0.92, 0.97, 1.0 };

    // First pass: heights (newest last in arrays).
    var heights: [MAX]f32 = @splat(0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (lens[i] == 0) continue;
        heights[i] = font.measureWrappedHeight(texts[i][0..lens[i]], font_size, screen_w * max_w_frac);
    }

    // Stack from bottom: newest (index n-1) sits on the bottom pad.
    var cursor_bottom = screen_h - bottom_pad;
    var idx: isize = @intCast(n);
    idx -= 1;
    while (idx >= 0) : (idx -= 1) {
        const ui: usize = @intCast(idx);
        if (lens[ui] == 0) continue;
        const a = System.alpha(borns[ui], now);
        if (a <= 0.01) {
            cursor_bottom -= heights[ui] + gap;
            continue;
        }
        const h = heights[ui];
        const y_top = cursor_bottom - h;
        const col: [4]f32 = .{ rgb[0], rgb[1], rgb[2], a * 0.94 };
        _ = font.drawCaptionAt(screen_w, y_top, font_size, col, texts[ui][0..lens[ui]], max_w_frac);
        cursor_bottom = y_top - gap;
        if (cursor_bottom < 4) break;
    }
}
