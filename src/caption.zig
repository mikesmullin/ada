//! Caption particle system — Game9-inspired (Particle.c + Timer born_at progress).
//!
//! Each spoken sentence is a particle:
//!   - born_at wall time (0 = dead slot)
//!   - solid hold scales with word count (reading allowance)
//!   - then fade to transparent (eased), then GC
//!   - stack bottom-up: newest on the bottom
//!
//! Parent chain (Ada multi-sentence captions):
//!   Each new particle is "parented" to the previous live one. Decay (fade)
//!   cannot start until BOTH (a) its own word-count solid hold has elapsed and
//!   (b) the parent has fully expired. That extends attack/sustain only —
//!   release duration stays FADE_S. Prevents a long early line from outlasting
//!   a short later line in a confusing way: you finish reading the long one
//!   before the short trailing one begins to fade.

const std = @import("std");
const ease = @import("ease.zig");
const sdf_font_mod = @import("sdf_font.zig");

pub const TEXT_CAP = 256;
pub const MAX = 16;

/// Solid hold = clamp(BASE + PER_WORD * n_words, MIN, MAX), then FADE seconds of decay.
pub const SOLID_BASE_S: f32 = 0.75;
pub const SOLID_PER_WORD_S: f32 = 0.30; // ~200 wpm reading allowance
pub const SOLID_MIN_S: f32 = 1.0;
pub const SOLID_MAX_S: f32 = 8.0;
pub const FADE_S: f32 = 3.5;

const Particle = struct {
    /// Seconds from avatar start clock; 0 = dead (Game9 `born_at == 0`).
    born_at: f64 = 0,
    text: [TEXT_CAP]u8 = undefined,
    text_len: usize = 0,
    /// Opaque hold (word-count base, possibly extended by parent expire).
    solid_s: f32 = SOLID_MIN_S,
    /// Total lifetime = solid_s + FADE_S (fade length is always FADE_S).
    life_s: f32 = SOLID_MIN_S + FADE_S,
};

/// Whitespace-separated word count (empty → 0).
pub fn countWords(text: []const u8) u32 {
    var n: u32 = 0;
    var in_word = false;
    for (text) |b| {
        const is_ws = b == ' ' or b == '\t' or b == '\n' or b == '\r';
        if (is_ws) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
        }
    }
    return n;
}

/// How long the caption stays fully opaque before fading (word-count only).
pub fn solidSeconds(word_count: u32) f32 {
    const wc: f32 = @floatFromInt(@max(word_count, 1));
    const s = SOLID_BASE_S + SOLID_PER_WORD_S * wc;
    return @min(SOLID_MAX_S, @max(SOLID_MIN_S, s));
}

pub fn lifeSeconds(word_count: u32) f32 {
    return solidSeconds(word_count) + FADE_S;
}

/// Solid hold for a new particle: at least word-count solid, and not before
/// the previous particle fully expires (parent chain).
pub fn solidWithParent(base_solid: f32, born_at: f64, parent_expire_at: ?f64) f32 {
    var solid = base_solid;
    if (parent_expire_at) |pe| {
        const wait: f32 = @floatCast(pe - born_at);
        if (wait > solid) solid = wait;
    }
    // Guard absurd holds if clocks go weird
    if (solid < SOLID_MIN_S) solid = SOLID_MIN_S;
    if (solid > 60.0) solid = 60.0;
    return solid;
}

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

        const born = if (now <= 0) 0.001 else now;
        const wc = countWords(text);
        const base_solid = solidSeconds(wc);

        // Parent = previous live particle (last in stack). Its life_s already
        // includes any extension from *its* parent, so the chain composes.
        var parent_expire: ?f64 = null;
        if (self.count > 0) {
            const parent = self.items[self.count - 1];
            if (parent.born_at > 0) {
                parent_expire = parent.born_at + @as(f64, parent.life_s);
            }
        }

        const solid = solidWithParent(base_solid, born, parent_expire);
        var p: Particle = .{
            .born_at = born,
            .solid_s = solid,
            .life_s = solid + FADE_S,
        };
        const n = @min(text.len, TEXT_CAP);
        @memcpy(p.text[0..n], text[0..n]);
        p.text_len = n;
        self.items[self.count] = p;
        self.count += 1;
    }

    /// Game9 `Particle__progress`: 0 at birth, 1 at death.
    pub fn progress(born_at: f64, life_s: f32, now: f64) f32 {
        if (born_at == 0 or life_s <= 0) return 1.0;
        const age: f32 = @floatCast(now - born_at);
        return ease.clamp01(age / life_s);
    }

    /// Opacity: full for solid_s, then ease toward 0 through life_s.
    /// Fade uses easeInQuad so text stays readable longer, then drops off.
    /// solid_s may be parent-extended; fade duration is still (life_s - solid_s) == FADE_S.
    pub fn alpha(born_at: f64, solid_s: f32, life_s: f32, now: f64) f32 {
        if (born_at == 0) return 0.0;
        const age: f32 = @floatCast(now - born_at);
        if (age <= solid_s) return 1.0;
        if (age >= life_s) return 0.0;
        const fade = life_s - solid_s;
        if (fade <= 0) return 0.0;
        const fade_t = (age - solid_s) / fade;
        return 1.0 - ease.easy(.in_quad, fade_t);
    }

    /// Expire finished particles; compact in birth order.
    pub fn update(self: *System, io: std.Io, now: f64) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        var w: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const p = self.items[i];
            if (p.born_at == 0 or progress(p.born_at, p.life_s, now) >= 1.0) continue;
            if (w != i) self.items[w] = p;
            w += 1;
        }
        self.count = w;
    }

    /// Drop every live particle (thread-safe). Tom uses this so only one
    /// security challenge line is visible at a time.
    pub fn clear(self: *System, io: std.Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.count = 0;
        self.items = @splat(.{});
    }

    /// Snapshot live particles for the render thread (oldest → newest).
    pub fn snapshot(
        self: *System,
        io: std.Io,
        out_text: *[MAX][TEXT_CAP]u8,
        out_len: *[MAX]usize,
        out_born: *[MAX]f64,
        out_solid: *[MAX]f32,
        out_life: *[MAX]f32,
    ) usize {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const n = self.count;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = self.items[i];
            out_len[i] = p.text_len;
            out_born[i] = p.born_at;
            out_solid[i] = p.solid_s;
            out_life[i] = p.life_s;
            if (p.text_len > 0) {
                @memcpy(out_text[i][0..p.text_len], p.text[0..p.text_len]);
            }
        }
        return n;
    }
};

/// Draw stacked captions: newest at the bottom.
pub fn drawStack(
    font: *sdf_font_mod.SdfFont,
    screen_w: f32,
    screen_h: f32,
    font_size: f32,
    now: f64,
    texts: *const [MAX][TEXT_CAP]u8,
    lens: *const [MAX]usize,
    borns: *const [MAX]f64,
    solids: *const [MAX]f32,
    lives: *const [MAX]f32,
    n: usize,
) void {
    if (!font.ok or n == 0 or font_size <= 0) return;

    const gap: f32 = 4.0;
    const bottom_pad: f32 = 10.0;
    const max_w_frac: f32 = 0.92;
    const rgb: [3]f32 = .{ 0.92, 0.97, 1.0 };

    var heights: [MAX]f32 = @splat(0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (lens[i] == 0) continue;
        heights[i] = font.measureWrappedHeight(texts[i][0..lens[i]], font_size, screen_w * max_w_frac);
    }

    var cursor_bottom = screen_h - bottom_pad;
    var idx: isize = @intCast(n);
    idx -= 1;
    while (idx >= 0) : (idx -= 1) {
        const ui: usize = @intCast(idx);
        if (lens[ui] == 0) continue;
        const a = System.alpha(borns[ui], solids[ui], lives[ui], now);
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
