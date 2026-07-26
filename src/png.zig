//! Minimal PNG loader: 8-bit RGBA or RGB, non-interlaced.
//! Cross-platform pure Zig (zlib via std.compress.flate).

const std = @import("std");
const flate = std.compress.flate;

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA8 row-major, top-left origin.
    pixels: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

const png_sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub fn load(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &png_sig)) return error.InvalidPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(allocator);

    var off: usize = 8;
    var saw_ihdr = false;
    while (off + 12 <= data.len) {
        const length = std.mem.readInt(u32, data[off..][0..4], .big);
        off += 4;
        if (off + 4 + length + 4 > data.len) return error.InvalidPng;
        const ctype = data[off .. off + 4];
        off += 4;
        const chunk = data[off .. off + length];
        off += length;
        off += 4; // CRC

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (length < 13) return error.InvalidPng;
            width = std.mem.readInt(u32, chunk[0..4], .big);
            height = std.mem.readInt(u32, chunk[4..8], .big);
            bit_depth = chunk[8];
            color_type = chunk[9];
            if (chunk[10] != 0 or chunk[11] != 0 or chunk[12] != 0) return error.UnsupportedPng;
            if (bit_depth != 8) return error.UnsupportedPng;
            if (color_type != 2 and color_type != 6) return error.UnsupportedPng;
            if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.InvalidPng;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(allocator, chunk);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
    }
    if (!saw_ihdr or idat.items.len == 0) return error.InvalidPng;

    const bpp: u32 = if (color_type == 6) 4 else 3;
    const stride = width * bpp;
    const raw_len = height * (1 + stride);

    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    {
        var in: std.Io.Reader = .fixed(idat.items);
        var fw: std.Io.Writer = .fixed(raw);
        var decompress: flate.Decompress = .init(&in, .zlib, &.{});
        const n = decompress.reader.streamRemaining(&fw) catch return error.InflateFailed;
        if (n < raw_len) return error.TruncatedPng;
    }

    const pixels = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(pixels);

    const prev = try allocator.alloc(u8, stride);
    defer allocator.free(prev);
    const curr = try allocator.alloc(u8, stride);
    defer allocator.free(curr);
    @memset(prev, 0);

    var y: u32 = 0;
    var roff: usize = 0;
    while (y < height) : (y += 1) {
        const ftype = raw[roff];
        roff += 1;
        @memcpy(curr, raw[roff .. roff + stride]);
        roff += stride;
        try unfilter(ftype, curr, prev, bpp);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const si = x * bpp;
            const di = (y * width + x) * 4;
            pixels[di + 0] = curr[si + 0];
            pixels[di + 1] = curr[si + 1];
            pixels[di + 2] = curr[si + 2];
            pixels[di + 3] = if (bpp == 4) curr[si + 3] else 255;
        }
        @memcpy(prev, curr);
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn unfilter(ftype: u8, curr: []u8, prev: []const u8, bpp: u32) !void {
    const b: usize = bpp;
    switch (ftype) {
        0 => {},
        1 => {
            var i: usize = b;
            while (i < curr.len) : (i += 1) curr[i] +%= curr[i - b];
        },
        2 => {
            for (curr, 0..) |*c, i| c.* +%= prev[i];
        },
        3 => {
            var i: usize = 0;
            while (i < curr.len) : (i += 1) {
                const left: u8 = if (i >= b) curr[i - b] else 0;
                curr[i] +%= @truncate((@as(u16, left) + prev[i]) / 2);
            }
        },
        4 => {
            var i: usize = 0;
            while (i < curr.len) : (i += 1) {
                const left: u8 = if (i >= b) curr[i - b] else 0;
                const up = prev[i];
                const ul: u8 = if (i >= b) prev[i - b] else 0;
                curr[i] +%= paeth(left, up, ul);
            }
        },
        else => return error.BadPngFilter,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const ia: i16 = a;
    const ib: i16 = b;
    const ic: i16 = c;
    const p = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Write 8-bit RGBA non-interlaced PNG (top-left origin).
pub fn writeRgba(allocator: std.mem.Allocator, io: std.Io, path: []const u8, width: u32, height: u32, rgba: []const u8) !void {
    if (width == 0 or height == 0) return error.InvalidPng;
    if (rgba.len < @as(usize, width) * height * 4) return error.InvalidPng;

    const stride = width * 4;
    const raw_len = height * (1 + stride);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_off = y * (1 + stride);
        raw[row_off] = 0; // filter None
        @memcpy(raw[row_off + 1 ..][0..stride], rgba[y * stride ..][0..stride]);
    }

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.ensureTotalCapacity(64 * 1024);
        var deflate_buf: [std.compress.flate.max_window_len + 4096]u8 = undefined;
        var comp = try std.compress.flate.Compress.init(&aw.writer, &deflate_buf, .zlib, .default);
        try comp.writer.writeAll(raw);
        try comp.finish();
        try compressed.appendSlice(allocator, aw.written());
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, &png_sig);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(allocator, &out, "IHDR", &ihdr);
    try appendChunk(allocator, &out, "IDAT", compressed.items);
    try appendChunk(allocator, &out, "IEND", &[_]u8{});

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = out.items,
        .flags = .{ .truncate = true },
    });
}

fn appendChunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctype: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, ctype);
    try out.appendSlice(allocator, data);

    var crc = std.hash.Crc32.init();
    crc.update(ctype);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(allocator, &crc_buf);
}
