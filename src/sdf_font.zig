//! Runtime MSDF font: atlas + metrics + custom sokol pipeline.
//! Ported from gl1 for Ada's closed captions (bottom-center overlay).

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const png = @import("png.zig");
const metrics = @import("sdf_metrics");
const shd = @import("sdf_text_shader");

pub const Clip = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const Batch = struct {
    start: usize,
    end: usize,
    size: f32,
    clip: ?Clip,
};

const AsciiGlyphs = struct { ch0: u8, ch1: u8 };

/// Map fancy Unicode punctuation → ASCII glyphs present in the MSDF atlas.
fn mapCodepointToAscii(cp: u21) AsciiGlyphs {
    return switch (cp) {
        0x2018, 0x2019, 0x201A, 0x201B, 0x2032, 0x2035, 0x02BC, 0x02B9 => .{ .ch0 = '\'', .ch1 = 0 },
        0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x2036, 0x00AB, 0x00BB => .{ .ch0 = '"', .ch1 = 0 },
        0x2013, 0x2010, 0x2011, 0x2012, 0x2212 => .{ .ch0 = '-', .ch1 = 0 },
        0x2014, 0x2015 => .{ .ch0 = '-', .ch1 = '-' },
        0x00A0, 0x202F, 0x2007, 0x2009, 0x200A, 0x2008 => .{ .ch0 = ' ', .ch1 = 0 },
        0x2026 => .{ .ch0 = '.', .ch1 = '.' },
        0x2022, 0x2023, 0x2043, 0x00B7, 0x2219, 0x25E6, 0x25AA, 0x25AB, 0x25CF, 0x25CB => .{ .ch0 = '-', .ch1 = 0 },
        0x00D7, 0x2715, 0x2716, 0x274C => .{ .ch0 = 'x', .ch1 = 0 },
        else => blk: {
            if (cp < 0x80) break :blk .{ .ch0 = @intCast(cp), .ch1 = 0 };
            break :blk .{ .ch0 = '?', .ch1 = 0 };
        },
    };
}

pub const SdfFont = struct {
    image: sg.Image = .{},
    view: sg.View = .{},
    smp: sg.Sampler = .{},
    shd_obj: sg.Shader = .{},
    pip: sg.Pipeline = .{},
    vbuf: [4]sg.Buffer = @splat(.{}),
    vbuf_i: usize = 0,
    ok: bool = false,

    verts: []f32 = &.{},
    vert_count: usize = 0,
    capacity_verts: usize = 0,
    allocator: std.mem.Allocator = undefined,

    batches: [16]Batch = undefined,
    batch_n: usize = 0,
    cur_clip: ?Clip = null,
    cur_size: f32 = 0,

    pub fn init(self: *SdfFont, allocator: std.mem.Allocator, atlas_png: []const u8) !void {
        self.allocator = allocator;
        self.capacity_verts = 6 * 256 * 8;
        self.verts = try allocator.alloc(f32, self.capacity_verts);
        errdefer allocator.free(self.verts);

        var img = try png.load(allocator, atlas_png);
        defer img.deinit(allocator);

        var img_data: sg.ImageData = .{};
        img_data.mip_levels[0] = sg.asRange(img.pixels);
        self.image = sg.makeImage(.{
            .width = @intCast(img.width),
            .height = @intCast(img.height),
            .pixel_format = .RGBA8,
            .data = img_data,
            .label = "sdf-font-atlas",
        });
        self.view = sg.makeView(.{
            .texture = .{ .image = self.image },
            .label = "sdf-font-view",
        });
        self.smp = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
            .label = "sdf-font-smp",
        });

        self.shd_obj = sg.makeShader(shd.sdfTextShaderDesc(sg.queryBackend()));

        var pip_desc: sg.PipelineDesc = .{
            .shader = self.shd_obj,
            .primitive_type = .TRIANGLES,
            .index_type = .NONE,
            .label = "sdf-font-pip",
        };
        pip_desc.layout.attrs[shd.ATTR_sdf_text_position].format = .FLOAT2;
        pip_desc.layout.attrs[shd.ATTR_sdf_text_texcoord0].format = .FLOAT2;
        pip_desc.layout.attrs[shd.ATTR_sdf_text_color0].format = .FLOAT4;
        pip_desc.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };
        self.pip = sg.makePipeline(pip_desc);

        for (&self.vbuf) |*vb| {
            vb.* = sg.makeBuffer(.{
                .usage = .{ .stream_update = true },
                .size = self.capacity_verts * @sizeOf(f32),
                .label = "sdf-font-vbuf",
            });
        }
        self.vbuf_i = 0;

        self.ok = self.image.id != 0 and self.pip.id != 0 and self.shd_obj.id != 0 and self.vbuf[0].id != 0;
        if (!self.ok) return error.SdfFontInitFailed;
    }

    pub fn deinit(self: *SdfFont) void {
        for (&self.vbuf) |*vb| {
            if (vb.id != 0) sg.destroyBuffer(vb.*);
        }
        if (self.pip.id != 0) sg.destroyPipeline(self.pip);
        if (self.shd_obj.id != 0) sg.destroyShader(self.shd_obj);
        if (self.smp.id != 0) sg.destroySampler(self.smp);
        if (self.view.id != 0) sg.destroyView(self.view);
        if (self.image.id != 0) sg.destroyImage(self.image);
        if (self.verts.len != 0) self.allocator.free(self.verts);
        self.* = .{};
    }

    pub fn beginFrame(self: *SdfFont) void {
        self.vert_count = 0;
        self.batch_n = 0;
        self.cur_clip = null;
        self.cur_size = 0;
    }

    fn closeBatch(self: *SdfFont) void {
        if (self.cur_size == 0) return;
        if (self.batch_n == 0) {
            self.cur_size = 0;
            return;
        }
        const b = &self.batches[self.batch_n - 1];
        b.end = self.vert_count;
        if (b.end <= b.start) {
            self.batch_n -= 1;
        }
        self.cur_size = 0;
    }

    fn ensureBatch(self: *SdfFont, size: f32) void {
        if (self.cur_size == size and self.batch_n > 0) return;
        self.closeBatch();
        if (self.batch_n >= self.batches.len) return;
        self.batches[self.batch_n] = .{
            .start = self.vert_count,
            .end = self.vert_count,
            .size = size,
            .clip = self.cur_clip,
        };
        self.batch_n += 1;
        self.cur_size = size;
    }

    pub fn advance(_: *const SdfFont, size: f32) f32 {
        const gi = metrics.ascii_index['M'];
        if (gi >= 0) return metrics.glyphs[@intCast(gi)].advance * size;
        return 0.6 * size;
    }

    pub fn lineHeight(_: *const SdfFont, size: f32) f32 {
        return metrics.line_height * size;
    }

    pub fn measure(self: *const SdfFont, text: []const u8, size: f32) struct { w: f32, h: f32 } {
        const adv = self.advance(size);
        const lh = self.lineHeight(size);
        var x: f32 = 0;
        var max_w: f32 = 0;
        var lines: f32 = 1;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\n') {
                max_w = @max(max_w, x);
                x = 0;
                lines += 1;
                continue;
            }
            x += adv;
        }
        max_w = @max(max_w, x);
        return .{ .w = max_w, .h = lines * lh };
    }

    /// Queue MSDF text. `size` is em size in pixels. `y` is top of the line box.
    pub fn drawText(self: *SdfFont, x: f32, y: f32, size: f32, color: [4]f32, text: []const u8) void {
        if (!self.ok or size <= 0 or text.len == 0) return;
        self.ensureBatch(size);

        const scale = size / metrics.px_size;
        const lh = metrics.line_height * size;
        const baseline = y + metrics.ascender * size;

        var pen_x = x;
        var pen_y = baseline;
        var prev: u21 = 0;

        var i: usize = 0;
        while (i < text.len) {
            const b = text[i];
            if (b == '\n') {
                pen_x = x;
                pen_y += lh;
                prev = 0;
                i += 1;
                continue;
            }

            var ascii0: u8 = 0;
            var ascii1: u8 = 0;
            if (b < 0x80) {
                ascii0 = b;
                i += 1;
            } else {
                var cp: u21 = 0;
                var len: usize = 0;
                if (b & 0xE0 == 0xC0 and i + 1 < text.len) {
                    cp = (@as(u21, b & 0x1F) << 6) | (text[i + 1] & 0x3F);
                    len = 2;
                } else if (b & 0xF0 == 0xE0 and i + 2 < text.len) {
                    cp = (@as(u21, b & 0x0F) << 12) | (@as(u21, text[i + 1] & 0x3F) << 6) | (text[i + 2] & 0x3F);
                    len = 3;
                } else if (b & 0xF8 == 0xF0 and i + 3 < text.len) {
                    cp = (@as(u21, b & 0x07) << 18) | (@as(u21, text[i + 1] & 0x3F) << 12) |
                        (@as(u21, text[i + 2] & 0x3F) << 6) | (text[i + 3] & 0x3F);
                    len = 4;
                } else {
                    ascii0 = '?';
                    i += 1;
                    len = 0;
                }
                if (len > 0) {
                    const m = mapCodepointToAscii(cp);
                    ascii0 = m.ch0;
                    ascii1 = m.ch1;
                    i += len;
                }
            }

            var pass: u8 = 0;
            while (pass < 2) : (pass += 1) {
                const ch: u8 = if (pass == 0) ascii0 else ascii1;
                if (pass == 1 and ch == 0) break;
                if (ch == 0) break;

                if (ch == ' ') {
                    const gi = metrics.ascii_index[' '];
                    if (gi >= 0) {
                        pen_x += metrics.glyphs[@intCast(gi)].advance * size;
                    } else {
                        pen_x += 0.5 * size;
                    }
                    prev = ch;
                    continue;
                }

                const gi = metrics.ascii_index[ch];
                if (gi < 0) {
                    prev = 0;
                    continue;
                }
                const g = metrics.glyphs[@intCast(gi)];

                if (prev != 0) {
                    for (metrics.kernings) |k| {
                        if (k.a == prev and k.b == ch) {
                            pen_x += k.x * size;
                            break;
                        }
                    }
                }

                const gw = g.width * scale;
                const gh = g.height * scale;
                const gx = pen_x + g.bearing_x * size - metrics.padding * scale;
                const gy = pen_y - g.bearing_y * size - metrics.padding * scale;

                const tu0 = g.u;
                const tv0 = g.v;
                const tu1 = g.u + g.uw;
                const tv1 = g.v + g.uh;

                self.pushVert(gx, gy, tu0, tv0, color);
                self.pushVert(gx + gw, gy, tu1, tv0, color);
                self.pushVert(gx + gw, gy + gh, tu1, tv1, color);
                self.pushVert(gx, gy, tu0, tv0, color);
                self.pushVert(gx + gw, gy + gh, tu1, tv1, color);
                self.pushVert(gx, gy + gh, tu0, tv1, color);

                pen_x += g.advance * size;
                prev = ch;
            }
        }
    }

    const WrapResult = struct {
        lines: [8][128]u8 = undefined,
        lens: [8]usize = @splat(0),
        n: usize = 0,
        height: f32 = 0,
    };

    fn wrapText(self: *const SdfFont, text: []const u8, size: f32, max_w: f32) WrapResult {
        var r: WrapResult = .{};
        if (text.len == 0 or size <= 0) return r;

        const adv = self.advance(size);
        const lh = self.lineHeight(size);
        var word_start: usize = 0;
        var i: usize = 0;
        var cur_w: f32 = 0;
        var cur_len: usize = 0;

        while (i <= text.len) {
            const at_end = i == text.len;
            const is_break = at_end or text[i] == ' ' or text[i] == '\n';
            if (!is_break) {
                i += 1;
                continue;
            }

            const word = text[word_start..i];
            const word_w = adv * @as(f32, @floatFromInt(word.len));
            const need_space = cur_len > 0 and word.len > 0;
            const space_w: f32 = if (need_space) adv else 0;

            if (word.len > 0 and cur_len > 0 and cur_w + space_w + word_w > max_w) {
                if (r.n < r.lines.len) {
                    r.lens[r.n] = cur_len;
                    r.n += 1;
                }
                cur_len = 0;
                cur_w = 0;
            }

            if (word.len > 0 and r.n < r.lines.len) {
                if (cur_len > 0 and cur_len < r.lines[r.n].len) {
                    r.lines[r.n][cur_len] = ' ';
                    cur_len += 1;
                    cur_w += adv;
                }
                const copy_n = @min(word.len, r.lines[r.n].len - cur_len);
                @memcpy(r.lines[r.n][cur_len..][0..copy_n], word[0..copy_n]);
                cur_len += copy_n;
                cur_w += adv * @as(f32, @floatFromInt(copy_n));
            }

            if (at_end or (i < text.len and text[i] == '\n')) {
                if (cur_len > 0 and r.n < r.lines.len) {
                    r.lens[r.n] = cur_len;
                    r.n += 1;
                    cur_len = 0;
                    cur_w = 0;
                }
            }

            if (at_end) break;
            i += 1;
            word_start = i;
        }
        if (cur_len > 0 and r.n < r.lines.len) {
            r.lens[r.n] = cur_len;
            r.n += 1;
        }
        r.height = @as(f32, @floatFromInt(r.n)) * lh;
        return r;
    }

    pub fn measureWrappedHeight(self: *const SdfFont, text: []const u8, size: f32, max_w: f32) f32 {
        return self.wrapText(text, size, max_w).height;
    }

    /// Word-wrap and draw centered; `y_top` is the top of the text block.
    /// Returns block height in pixels.
    pub fn drawCaptionAt(
        self: *SdfFont,
        screen_w: f32,
        y_top: f32,
        size: f32,
        color: [4]f32,
        text: []const u8,
        max_w_frac: f32,
    ) f32 {
        if (!self.ok or text.len == 0 or size <= 0) return 0;
        const max_w = screen_w * max_w_frac;
        const wrapped = self.wrapText(text, size, max_w);
        if (wrapped.n == 0) return 0;

        const lh = self.lineHeight(size);
        var y = y_top;
        if (y < 4) y = 4;

        var li: usize = 0;
        while (li < wrapped.n) : (li += 1) {
            const line = wrapped.lines[li][0..wrapped.lens[li]];
            const m = self.measure(line, size);
            const x = (screen_w - m.w) * 0.5;
            self.drawText(x, y, size, color, line);
            y += lh;
        }
        return wrapped.height;
    }

    /// Convenience: single caption anchored to the bottom of the screen.
    pub fn drawCaptionCentered(
        self: *SdfFont,
        screen_w: f32,
        screen_h: f32,
        size: f32,
        color: [4]f32,
        text: []const u8,
        max_w_frac: f32,
        bottom_pad: f32,
    ) void {
        const h = self.measureWrappedHeight(text, size, screen_w * max_w_frac);
        const y = screen_h - bottom_pad - h;
        _ = self.drawCaptionAt(screen_w, y, size, color, text, max_w_frac);
    }

    fn pushVert(self: *SdfFont, x: f32, y: f32, u: f32, v: f32, c: [4]f32) void {
        const need = self.vert_count + 8;
        if (need > self.capacity_verts) {
            const new_cap = @max(self.capacity_verts * 2, need);
            const new_buf = self.allocator.realloc(self.verts, new_cap) catch return;
            self.verts = new_buf;
            self.capacity_verts = new_cap;
            for (&self.vbuf) |*vb| {
                if (vb.id != 0) sg.destroyBuffer(vb.*);
                vb.* = sg.makeBuffer(.{
                    .usage = .{ .stream_update = true },
                    .size = self.capacity_verts * @sizeOf(f32),
                    .label = "sdf-font-vbuf",
                });
            }
        }
        const o = self.vert_count;
        self.verts[o + 0] = x;
        self.verts[o + 1] = y;
        self.verts[o + 2] = u;
        self.verts[o + 3] = v;
        self.verts[o + 4] = c[0];
        self.verts[o + 5] = c[1];
        self.verts[o + 6] = c[2];
        self.verts[o + 7] = c[3];
        self.vert_count = o + 8;
    }

    pub fn flush(self: *SdfFont, screen_w: f32, screen_h: f32) void {
        if (!self.ok or self.vert_count == 0) {
            self.beginFrame();
            return;
        }
        self.closeBatch();
        if (self.batch_n == 0) {
            self.beginFrame();
            return;
        }

        const buf = self.vbuf[self.vbuf_i % self.vbuf.len];
        self.vbuf_i +%= 1;
        sg.updateBuffer(buf, sg.asRange(self.verts[0..self.vert_count]));

        var vs_params: shd.VsParams = .{
            .u_screen = .{ screen_w, screen_h },
            ._pad0 = .{ 0, 0 },
        };

        var bind: sg.Bindings = .{};
        bind.vertex_buffers[0] = buf;
        bind.views[shd.VIEW_tex] = self.view;
        bind.samplers[shd.SMP_smp] = self.smp;

        sg.applyPipeline(self.pip);
        sg.applyBindings(bind);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));

        var bi: usize = 0;
        while (bi < self.batch_n) : (bi += 1) {
            const b = self.batches[bi];
            if (b.end <= b.start) continue;

            if (b.clip) |cl| {
                sg.applyScissorRectf(cl.x, cl.y, cl.w, cl.h, true);
            } else {
                sg.applyScissorRectf(0, 0, screen_w, screen_h, true);
            }

            const scale = b.size / metrics.px_size;
            const screen_px_range = metrics.px_range * scale;
            var fs_params: shd.FsParams = .{
                .u_sdf = .{ screen_px_range, 0, 0, 0 },
            };
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params));

            const base: u32 = @intCast(b.start / 8);
            const n_verts: u32 = @intCast((b.end - b.start) / 8);
            sg.draw(base, n_verts, 1);
        }

        sg.applyScissorRectf(0, 0, screen_w, screen_h, true);
        self.beginFrame();
    }
};
