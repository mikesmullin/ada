//! Wire types shared by the avatar's socket clients (docs/PROTOCOL.md).

const std = @import("std");

/// 'AVF1' as little-endian bytes "AVF1" (docs/PROTOCOL.md §1).
pub const FRAME_MAGIC: u32 = 0x31465641;

pub const STREAM_MIC: u32 = 0;
pub const STREAM_TTS: u32 = 1;

pub const FLAG_VAD: u32 = 1 << 0;
pub const FLAG_START: u32 = 1 << 1;
pub const FLAG_END: u32 = 1 << 2;

/// 36 bytes little-endian, ~60 Hz, pushed by both voice services.
pub const FeatureFrame = extern struct {
    magic: u32,
    stream_id: u32,
    rms: f32,
    band: [4]f32,
    pitch_hint: f32,
    flags: u32,

    pub const SIZE = 36;
};

comptime {
    std.debug.assert(@sizeOf(FeatureFrame) == FeatureFrame.SIZE);
}

/// perception-voice framing: 4-byte big-endian length prefix + JSON payload.
pub fn writeFramed(w: *std.Io.Writer, payload: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .big);
    try w.writeAll(&len_buf);
    try w.writeAll(payload);
    try w.flush();
}

/// Reads one length-prefixed JSON payload into `buf`, returns the slice.
pub fn readFramed(r: *std.Io.Reader, buf: []u8) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try r.readSliceAll(&len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > buf.len) return error.MessageTooLarge;
    try r.readSliceAll(buf[0..len]);
    return buf[0..len];
}
