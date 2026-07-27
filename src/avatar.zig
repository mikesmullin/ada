//! `ada avatar` — the orb overlay (docs/PLAN.md §4).
//!
//! Render thread: sokol_app + sokol_gfx drive a single fullscreen-quad
//! shader; all animation state arrives as smoothed uniforms.
//! Socket threads: back (JSON lines, bidirectional), perception-voice
//! levels (binary FeatureFrames, mic), presence-voice levels (binary
//! FeatureFrames, tts). Threads only write the `targets` struct; the
//! render thread smooths toward it with attack/release envelopes.
//!
//! Fail-fast: without --solo, all three services must be reachable at
//! startup (plan §9.3); after that, each socket thread reconnects with a
//! 1 s backoff so a service restart just makes the orb go quiet briefly.

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const shd = @import("shaders/orb.glsl.zig");
const shd_hud = @import("shaders/hud.glsl.zig");
const ipc = @import("ipc.zig");
const sdf_font_mod = @import("sdf_font.zig");
const font_assets = @import("font_assets");
const caption_mod = @import("caption.zig");

/// Visual styles. Same uniform block in every shader, so all state/audio
/// signals drive each style identically — only the artwork differs.
pub const Style = enum { orb, hud };

pub const Options = struct {
    solo: bool = false,
    back_sock: []const u8,
    perception_sock: []const u8,
    presence_sock: []const u8,
    size: i32 = 320,
    style: Style = .hud,
};

const AudioFeat = struct {
    rms: f32 = 0,
    band: [4]f32 = .{ 0, 0, 0, 0 },
    vad: f32 = 0,
    live: bool = false, // real frames flowing (vs synthesized fallback)
};

/// Written by socket threads under `mu`, copied once per frame by render.
const Targets = struct {
    mu: std.Io.Mutex = .init,
    listening: f32 = 0,
    active: f32 = 0,
    thinking: f32 = 0,
    speaking: f32 = 0,
    connected: f32 = 1,
    user: AudioFeat = .{},
    ada: AudioFeat = .{},
    /// nowSeconds() of the last TTS frame with audible content. The back's
    /// `speaking` state tracks request completion (OK = enqueued, playback
    /// is async), so it goes false while she is still audibly talking —
    /// the frames are the playback clock, and they open the speaking gate
    /// directly (see frame()).
    ada_last_audible: f64 = -10,
};

/// Render-thread-only smoothed copies of Targets.
const Smooth = struct {
    listening: f32 = 0,
    active: f32 = 0,
    thinking: f32 = 0,
    speaking: f32 = 0,
    connected: f32 = 1,
    user: AudioFeat = .{},
    ada: AudioFeat = .{},
    user_env: f32 = 0,
    ada_env: f32 = 0,
    user_last_rms: f32 = 0,
    ada_last_rms: f32 = 0,
    press: f32 = 0,
};

const G = struct {
    var alloc: std.mem.Allocator = undefined;
    var io: std.Io = undefined;
    var opts: Options = undefined;

    var targets: Targets = .{};
    var smooth: Smooth = .{};

    var back_fd: c_int = -1;
    var back_mu: std.Io.Mutex = .init; // guards back_fd writes/sends

    var start_ts: std.Io.Clock.Timestamp = undefined;
    var last_time: f64 = 0;
    var press_started: f64 = -1;

    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};
    var font: sdf_font_mod.SdfFont = .{};
    /// Closed captions as Game9-style particles (spawn / age / fade / GC).
    var captions: caption_mod.System = .{};

    // --solo keyboard toggles
    var solo_listen: bool = true;
    var solo_active: bool = false;
    var solo_think: bool = false;
    var solo_speak: bool = false;
    var solo_pulse: f64 = -10;
    var solo_caption_i: u32 = 0;

    /// Held open for process lifetime (exclusive flock). Closed + unlinked on clean exit.
    var lock_file: ?std.Io.File = null;
    var lock_owned: bool = false;
};

// ---------------------------------------------------------------------------
// Single-instance lock: pidfile + exclusive file lock.
// File content (two lines):
//   <pid>\n
//   <unix_started_at>\n
// Refuse if another live avatar is recorded / holds the lock. Stale files
// (dead pid and free lock) are taken over — same idea as ada-back .back.lock.
// Clean exit (window close / SIGQUIT / SIGINT / SIGTERM) unlinks the file.

const LOCK_PATH = "/workspace/ada/.avatar.lock";
const LOCK_PATH_Z: [:0]const u8 = LOCK_PATH;

extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn time(tloc: ?*i64) i64;
extern "c" fn unlink(path: [*:0]const u8) c_int;

fn pidIsAlive(pid: std.posix.pid_t) bool {
    if (pid <= 0) return false;
    // kill(pid, 0): 0 = exists; EPERM = exists but not ours; ESRCH = gone.
    const rc = kill(@intCast(pid), 0);
    if (rc == 0) return true;
    return std.posix.errno(rc) == .PERM;
}

fn readLockMeta(io: std.Io, file: std.Io.File) struct { pid: std.posix.pid_t, started: i64 } {
    var buf: [128]u8 = undefined;
    // Positional read from offset 0 (no seek needed).
    const n = file.readPositionalAll(io, &buf, 0) catch return .{ .pid = 0, .started = 0 };
    if (n == 0) return .{ .pid = 0, .started = 0 };
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    const line1 = it.next() orelse "";
    const line2 = it.next() orelse "";
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, line1, " \t\r"), 10) catch 0;
    const started = std.fmt.parseInt(i64, std.mem.trim(u8, line2, " \t\r"), 10) catch 0;
    return .{ .pid = pid, .started = started };
}

/// Lock / startup failures always go to stderr (not the optional stdout log),
/// so wrappers that only keep stderr — or humans redirecting 2> — can see why
/// the orb refused to start. `launch1.sh` currently discards both streams;
/// run without it, or drop the `2>&1` redirect, to observe these messages.
fn emitStartupError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const w = &stderr_writer.interface;
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

fn acquireInstanceLock(io: std.Io) void {
    const file = std.Io.Dir.createFileAbsolute(io, LOCK_PATH, .{
        .read = true,
        .truncate = false,
    }) catch |err| {
        emitStartupError(io, "error: cannot open instance lock {s}: {t}\n", .{ LOCK_PATH, err });
        std.process.exit(1);
    };
    // Keep fd open for process lifetime so the exclusive lock is released by
    // the kernel on crash even if we never reach releaseInstanceLock.

    const meta = readLockMeta(io, file);
    const got_lock = file.tryLock(io, .exclusive) catch false;

    // Refuse if exclusive lock is held elsewhere, or pidfile points at a live process.
    if (!got_lock or pidIsAlive(meta.pid)) {
        emitStartupError(
            io,
            "error: another ada avatar is already running (pid {d}, started {d}, lock: {s})\n" ++
                "       stop it first, or remove a stale lock if that pid is dead:\n" ++
                "       rm -f {s}\n",
            .{ meta.pid, meta.started, LOCK_PATH, LOCK_PATH },
        );
        // Do not leave this process holding the exclusive lock after a refuse.
        file.close(io);
        std.process.exit(1);
    }

    // We hold exclusive lock and peer pid is not live: write our identity.
    file.setLength(io, 0) catch {};
    const now: i64 = time(null);
    var wbuf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&wbuf, "{d}\n{d}\n", .{ std.c.getpid(), now }) catch {
        emitStartupError(io, "error: cannot format instance lock {s}\n", .{LOCK_PATH});
        file.close(io);
        std.process.exit(1);
    };
    file.writeStreamingAll(io, line) catch |err| {
        emitStartupError(io, "error: cannot write instance lock {s}: {t}\n", .{ LOCK_PATH, err });
        file.close(io);
        std.process.exit(1);
    };

    G.lock_file = file;
    G.lock_owned = true;
}

/// Close the exclusive lock fd and remove the pidfile. Idempotent.
/// Safe to call from sokol cleanup and from signal handlers (uses only
/// async-signal-safe ops on the hot path after flags are checked).
fn releaseInstanceLock() void {
    if (!G.lock_owned) return;
    G.lock_owned = false;

    // Close first so flock is released before another process recreates the path.
    if (G.lock_file) |file| {
        G.lock_file = null;
        // Prefer raw close in signal context; Io close may not be signal-safe.
        _ = std.c.close(file.handle);
    }
    _ = unlink(LOCK_PATH_Z.ptr);
}

/// SIGQUIT (awesome titlebar X often maps here), SIGINT, SIGTERM: drop lock and exit.
fn onFatalSignal(sig: std.posix.SIG) callconv(.c) void {
    releaseInstanceLock();
    // Re-raise with default disposition so the shell sees the real signal.
    const default_act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &default_act, null);
    std.posix.raise(sig) catch {};
}

fn installLockSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onFatalSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.QUIT, &act, null);
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

// ---------------------------------------------------------------------------
// X11: set WM_CLASS = "ada" so awesome-WM client rules can target the window
// (floating/ontop/borderless/placement all live in rc.lua — plan §4).

const XClassHint = extern struct { res_name: [*:0]u8, res_class: [*:0]u8 };
extern fn XSetClassHint(dpy: *anyopaque, w: c_ulong, hint: *XClassHint) c_int;
extern fn XFlush(dpy: *anyopaque) c_int;

fn setWmClass() void {
    if (builtin.os.tag != .linux) return;
    const dpy = @constCast(sapp.x11GetDisplay() orelse return);
    const win: c_ulong = @intFromPtr(sapp.x11GetWindow() orelse return);
    var name = "ada".*;
    var hint = XClassHint{ .res_name = &name, .res_class = &name };
    _ = XSetClassHint(dpy, win, &hint);
    _ = XFlush(dpy);
}

// ---------------------------------------------------------------------------
// Back socket (JSON lines, bidirectional)

// Deliberately raw POSIX (std.c), NOT std.Io: reading a mostly-idle stream
// through the Threaded Io from a spawned thread degenerated into an
// empty-line busy-spin (takeDelimiterExclusive returned "" at ~100k/s with
// zero syscalls) that pinned a core and never delivered events. Plain
// blocking read(2)/write(2) can't do that. The levels streams stay on
// std.Io — they push continuously and block correctly.
fn connectBackFd() !c_int {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);

    var addr = std.mem.zeroes(std.c.sockaddr.un);
    addr.family = std.c.AF.UNIX;
    if (G.opts.back_sock.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..G.opts.back_sock.len], G.opts.back_sock);

    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) {
        return error.ConnectFailed;
    }
    return fd;
}

fn nowSeconds() f64 {
    const now = std.Io.Clock.Timestamp.now(G.io, .awake);
    const dur = G.start_ts.durationTo(now);
    return @as(f64, @floatFromInt(dur.raw.nanoseconds)) / 1e9;
}

fn sleepSecond() void {
    // libc nanosleep, deliberately io-free: std.Io.sleep from a spawned
    // (non-io-managed) thread can return immediately, which turned the
    // back reconnect loop into a 100%-CPU spin that never reconnected.
    const ts = std.c.timespec{ .sec = 1, .nsec = 0 };
    _ = std.c.nanosleep(&ts, null);
}

fn sendBack(line: []const u8) void {
    G.back_mu.lockUncancelable(G.io);
    defer G.back_mu.unlock(G.io);
    if (G.back_fd < 0) return;
    _ = std.c.write(G.back_fd, line.ptr, line.len);
    _ = std.c.write(G.back_fd, "\n", 1);
}

fn sendPtt(down: bool) void {
    sendBack(if (down) "{\"ev\":\"ptt\",\"down\":true}" else "{\"ev\":\"ptt\",\"down\":false}");
}

const StateMsg = struct {
    ev: []const u8,
    listening: bool = false,
    active: bool = false,
    thinking: bool = false,
    speaking: bool = false,
    who: []const u8 = "",
    text: []const u8 = "",
};

fn spawnCaption(text: []const u8) void {
    // Empty = no-op: particles self-expire (Game9 lifetime), no hard clear.
    G.captions.spawn(G.io, nowSeconds(), text);
}

fn handleBackLine(line: []const u8) void {
    // c_allocator: this runs on the back socket thread, and G.alloc is
    // main()'s arena (not thread-safe).
    const parsed = std.json.parseFromSlice(StateMsg, std.heap.c_allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    const msg = parsed.value;

    if (std.mem.eql(u8, msg.ev, "caption")) {
        // who:"ada" (or omitted) → spawn a caption particle.
        if (msg.who.len == 0 or std.mem.eql(u8, msg.who, "ada")) {
            spawnCaption(msg.text);
        }
        return;
    }
    if (!std.mem.eql(u8, msg.ev, "state")) return;

    G.targets.mu.lockUncancelable(G.io);
    defer G.targets.mu.unlock(G.io);
    G.targets.listening = if (msg.listening) 1 else 0;
    G.targets.active = if (msg.active) 1 else 0;
    G.targets.thinking = if (msg.thinking) 1 else 0;
    G.targets.speaking = if (msg.speaking) 1 else 0;
}

fn backThread() void {
    var acc: [8192]u8 = undefined;
    var acc_len: usize = 0;
    while (true) {
        const fd = blk: {
            G.back_mu.lockUncancelable(G.io);
            defer G.back_mu.unlock(G.io);
            break :blk G.back_fd;
        };
        if (fd >= 0) {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = std.c.read(fd, &buf, buf.len);
                if (n <= 0) break; // EOF or error: reconnect
                for (buf[0..@intCast(n)]) |b| {
                    if (b == '\n') {
                        handleBackLine(acc[0..acc_len]);
                        acc_len = 0;
                    } else if (acc_len < acc.len) {
                        acc[acc_len] = b;
                        acc_len += 1;
                    }
                }
            }
            // connection lost
            std.debug.print("[avatar] back connection lost, reconnecting…\n", .{});
            acc_len = 0;
            G.back_mu.lockUncancelable(G.io);
            _ = std.c.close(G.back_fd);
            G.back_fd = -1;
            G.back_mu.unlock(G.io);
            setConnected(false);
        }
        sleepSecond();
        if (connectBackFd()) |fresh| {
            std.debug.print("[avatar] back reconnected\n", .{});
            G.back_mu.lockUncancelable(G.io);
            G.back_fd = fresh;
            G.back_mu.unlock(G.io);
            setConnected(true);
        } else |_| {}
    }
}

fn setConnected(ok: bool) void {
    G.targets.mu.lockUncancelable(G.io);
    defer G.targets.mu.unlock(G.io);
    G.targets.connected = if (ok) 1 else 0;
    if (!ok) {
        G.targets.active = 0;
        G.targets.thinking = 0;
        G.targets.speaking = 0;
        // leave caption particles to age out on their own
    }
}

// ---------------------------------------------------------------------------
// Voice-service level streams (binary FeatureFrames)

fn connectPerceptionLevels() !std.Io.net.Stream {
    const addr = try std.Io.net.UnixAddress.init(G.opts.perception_sock);
    var conn = try addr.connect(G.io);
    errdefer conn.close(G.io);

    var wbuf: [256]u8 = undefined;
    var w = conn.writer(G.io, &wbuf);
    try ipc.writeFramed(&w.interface, "{\"command\":\"subscribe\",\"channel\":\"levels\"}");

    var rbuf: [1024]u8 = undefined;
    var r = conn.reader(G.io, &rbuf);
    var ack_buf: [512]u8 = undefined;
    const ack = try ipc.readFramed(&r.interface, &ack_buf);
    if (std.mem.indexOf(u8, ack, "\"ok\"") == null) return error.SubscribeRejected;
    return conn;
}

fn connectPresenceLevels() !std.Io.net.Stream {
    const addr = try std.Io.net.UnixAddress.init(G.opts.presence_sock);
    var conn = try addr.connect(G.io);
    errdefer conn.close(G.io);

    var wbuf: [64]u8 = undefined;
    var w = conn.writer(G.io, &wbuf);
    try w.interface.writeAll("subscribe\tlevels\n");
    try w.interface.flush();

    var rbuf: [256]u8 = undefined;
    var r = conn.reader(G.io, &rbuf);
    const line = try r.interface.takeDelimiterExclusive('\n');
    if (!std.mem.eql(u8, line, "OK")) return error.SubscribeRejected;
    return conn;
}

fn applyFrame(f: *const ipc.FeatureFrame) void {
    G.targets.mu.lockUncancelable(G.io);
    defer G.targets.mu.unlock(G.io);
    const feat = if (f.stream_id == ipc.STREAM_TTS) &G.targets.ada else &G.targets.user;
    feat.rms = f.rms;
    feat.band = f.band;
    feat.vad = if (f.flags & ipc.FLAG_VAD != 0) 1 else 0;
    feat.live = true;
    if (f.stream_id == ipc.STREAM_TTS and f.rms > 0.02) {
        G.targets.ada_last_audible = nowSeconds();
    }
}

fn zeroFeat(which: enum { user, ada }) void {
    G.targets.mu.lockUncancelable(G.io);
    defer G.targets.mu.unlock(G.io);
    const feat = if (which == .ada) &G.targets.ada else &G.targets.user;
    feat.* = .{};
}

/// Reads fixed-size frames until the connection drops.
fn frameLoop(conn: *std.Io.net.Stream) void {
    var buf: [4096]u8 = undefined;
    var reader = conn.reader(G.io, &buf);
    while (true) {
        var frame_bytes: [ipc.FeatureFrame.SIZE]u8 align(4) = undefined;
        reader.interface.readSliceAll(&frame_bytes) catch return;
        const f: *const ipc.FeatureFrame = @ptrCast(&frame_bytes);
        if (f.magic != ipc.FRAME_MAGIC) return; // desync: drop + reconnect
        applyFrame(f);
    }
}

fn levelsThread(comptime which: enum { perception, presence }, initial: ?std.Io.net.Stream) void {
    var conn: ?std.Io.net.Stream = initial;
    while (true) {
        if (conn) |*c| {
            frameLoop(c);
            c.close(G.io);
            conn = null;
            zeroFeat(if (which == .presence) .ada else .user);
        }
        sleepSecond();
        conn = switch (which) {
            .perception => connectPerceptionLevels() catch null,
            .presence => connectPresenceLevels() catch null,
        };
    }
}

fn perceptionThread(initial: ?std.Io.net.Stream) void {
    levelsThread(.perception, initial);
}

fn presenceThread(initial: ?std.Io.net.Stream) void {
    levelsThread(.presence, initial);
}

// ---------------------------------------------------------------------------
// Render

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    setWmClass();

    // fullscreen triangle (covers clip space; uv runs past ±1 at the corners,
    // which the shader treats as background)
    G.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]f32{
            -1.0, -1.0,
            3.0,  -1.0,
            -1.0, 3.0,
        }),
    });

    // both programs share the vertex layout (one vec2 position at slot 0)
    // and the fs_params uniform block, so only the shader desc differs
    const shader_desc = switch (G.opts.style) {
        .orb => shd.orbShaderDesc(sg.queryBackend()),
        .hud => shd_hud.hudShaderDesc(sg.queryBackend()),
    };
    G.pip = sg.makePipeline(.{
        .shader = sg.makeShader(shader_desc),
        .layout = init: {
            var l = sg.VertexLayoutState{};
            l.attrs[shd.ATTR_orb_position].format = .FLOAT2;
            break :init l;
        },
    });

    // MSDF caption font (JetBrains Mono atlas, same as gl1).
    G.font.init(G.alloc, font_assets.jetbrains_mono_msdf_png) catch |err| {
        std.debug.print("[avatar] sdf font init failed: {t}\n", .{err});
    };
}

/// Exponential approach: fast attack, slower release (plan §4 — "all
/// audio-driven parameters get attack/release smoothing in the avatar").
fn approach(cur: f32, target: f32, dt: f32, tau_up: f32, tau_down: f32) f32 {
    const tau = if (target > cur) tau_up else tau_down;
    const k = 1.0 - @exp(-dt / tau);
    return cur + (target - cur) * k;
}

fn smoothFeat(cur: *AudioFeat, target: AudioFeat, dt: f32) void {
    cur.rms = approach(cur.rms, target.rms, dt, 0.03, 0.18);
    for (&cur.band, target.band) |*b, tb| b.* = approach(b.*, tb, dt, 0.03, 0.22);
    cur.vad = approach(cur.vad, target.vad, dt, 0.05, 0.3);
}

export fn frame() void {
    const now: f64 = nowSeconds();
    const dt: f32 = @floatCast(@max(now - G.last_time, 0.0001));
    G.last_time = now;

    // caption particles: expire finished ones (Game9 Particle__updateSystem)
    G.captions.update(G.io, now);

    // copy targets (tiny critical section)
    var tgt: Targets = undefined;
    {
        G.targets.mu.lockUncancelable(G.io);
        defer G.targets.mu.unlock(G.io);
        tgt.listening = G.targets.listening;
        tgt.active = G.targets.active;
        tgt.thinking = G.targets.thinking;
        tgt.speaking = G.targets.speaking;
        tgt.connected = G.targets.connected;
        tgt.user = G.targets.user;
        tgt.ada = G.targets.ada;
        tgt.ada_last_audible = G.targets.ada_last_audible;
    }

    // Her actual audio opens the speaking gate (playback truth beats the
    // back's request-completion state — see Targets.ada_last_audible).
    if (now - tgt.ada_last_audible < 0.3) tgt.speaking = 1;

    if (G.opts.solo) soloDrive(&tgt, now);

    // Until presence-voice grows its feature-frame stream (milestone 5, in
    // Bob's court — see docs/PLAN.md §5a), synthesize a speaking pulse from
    // the back's speaking state so the core still animates with her voice.
    if (!tgt.ada.live and tgt.speaking > 0.5) {
        const t: f32 = @floatCast(now);
        tgt.ada.rms = 0.35 + 0.3 * @sin(t * 3.1) + 0.15 * @sin(t * 9.7);
        tgt.ada.band = .{
            0.4 + 0.3 * @sin(t * 2.3),
            0.35 + 0.25 * @sin(t * 4.1 + 1.5),
            0.3 + 0.25 * @sin(t * 6.7 + 0.5),
            0.25 + 0.2 * @sin(t * 11.3 + 2.5),
        };
    }

    const s = &G.smooth;
    s.listening = approach(s.listening, tgt.listening, dt, 0.15, 0.4);
    s.active = approach(s.active, tgt.active, dt, 0.08, 0.35);
    s.thinking = approach(s.thinking, tgt.thinking, dt, 0.12, 0.4);
    s.speaking = approach(s.speaking, tgt.speaking, dt, 0.08, 0.35);
    s.connected = approach(s.connected, tgt.connected, dt, 0.3, 0.3);
    smoothFeat(&s.user, tgt.user, dt);
    smoothFeat(&s.ada, tgt.ada, dt);

    // attack envelopes: spike on rising rms, decay on their own
    const u_attack = @max(0.0, tgt.user.rms - s.user_last_rms) * 8.0;
    const a_attack = @max(0.0, tgt.ada.rms - s.ada_last_rms) * 8.0;
    s.user_last_rms = tgt.user.rms;
    s.ada_last_rms = tgt.ada.rms;
    s.user_env = @min(1.0, approach(s.user_env, u_attack, dt, 0.01, 0.12));
    s.ada_env = @min(1.0, approach(s.ada_env, a_attack, dt, 0.01, 0.12));

    const press_target: f32 = if (G.press_started >= 0) 1.0 else 0.0;
    s.press = approach(s.press, press_target, dt, 0.04, 0.15);

    // idle recedes as any engaged state rises
    const engaged = @max(s.active, @max(s.thinking, s.speaking));
    const w_idle = 1.0 - engaged;

    const params = shd.FsParams{
        .res_time = .{ sapp.widthf(), sapp.heightf(), @floatCast(now), s.press },
        .states_a = .{ w_idle, s.listening, s.active, s.thinking },
        .states_b = .{ s.speaking, s.connected, 0, 0 },
        .user_a = .{ s.user.rms, s.user.band[0], s.user.band[1], s.user.band[2] },
        .user_b = .{ s.user.band[3], s.user_env, s.user.vad, 0 },
        .ada_a = .{ s.ada.rms, s.ada.band[0], s.ada.band[1], s.ada.band[2] },
        .ada_b = .{ s.ada.band[3], s.ada_env, 0, 0 },
    };

    const sw = sapp.widthf();
    const sh = sapp.heightf();

    sg.beginPass(.{ .swapchain = sglue.swapchain() });
    sg.applyPipeline(G.pip);
    sg.applyBindings(G.bind);
    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&params));
    sg.draw(0, 3, 1);

    // Closed captions: particle stack (newest at bottom, fade after solid hold).
    if (G.font.ok) {
        var cap_text: [caption_mod.MAX][caption_mod.TEXT_CAP]u8 = undefined;
        var cap_len: [caption_mod.MAX]usize = @splat(0);
        var cap_born: [caption_mod.MAX]f64 = @splat(0);
        var cap_solid: [caption_mod.MAX]f32 = @splat(0);
        var cap_life: [caption_mod.MAX]f32 = @splat(0);
        const cap_n = G.captions.snapshot(G.io, &cap_text, &cap_len, &cap_born, &cap_solid, &cap_life);
        if (cap_n > 0) {
            const font_size = @max(12.0, @min(18.0, sw * 0.045));
            G.font.beginFrame();
            caption_mod.drawStack(&G.font, sw, sh, font_size, now, &cap_text, &cap_len, &cap_born, &cap_solid, &cap_life, cap_n);
            G.font.flush(sw, sh);
        }
    }

    sg.endPass();
    sg.commit();
}

/// --solo: keyboard-driven states + synthetic audio so the orb can be
/// developed/reviewed without any services (milestone 1's fake uniforms).
fn soloDrive(tgt: *Targets, now: f64) void {
    tgt.listening = if (G.solo_listen) 1 else 0;
    tgt.active = if (G.solo_active) 1 else 0;
    tgt.thinking = if (G.solo_think) 1 else 0;
    tgt.speaking = if (G.solo_speak) 1 else 0;
    tgt.connected = 1;

    const t: f32 = @floatCast(now);
    if (G.solo_active or G.solo_listen) {
        const gate: f32 = if (G.solo_active) 1.0 else 0.5;
        tgt.user.rms = gate * (0.3 + 0.25 * @sin(t * 2.7) + 0.15 * @sin(t * 7.1));
        tgt.user.band = .{
            gate * (0.4 + 0.3 * @sin(t * 1.9)),
            gate * (0.3 + 0.25 * @sin(t * 3.7 + 1.0)),
            gate * (0.25 + 0.2 * @sin(t * 5.3 + 2.0)),
            gate * (0.2 + 0.2 * @sin(t * 8.9 + 3.0)),
        };
    }
    if (G.solo_speak) {
        tgt.ada.rms = 0.35 + 0.3 * @sin(t * 3.1) + 0.15 * @sin(t * 9.7);
        tgt.ada.band = .{
            0.4 + 0.3 * @sin(t * 2.3),
            0.35 + 0.25 * @sin(t * 4.1 + 1.5),
            0.3 + 0.25 * @sin(t * 6.7 + 0.5),
            0.25 + 0.2 * @sin(t * 11.3 + 2.5),
        };
    }
    // click pulse feedback
    const since: f32 = @floatCast(now - G.solo_pulse);
    if (since < 0.5) tgt.user.rms += (0.5 - since) * 1.6;
}

export fn event(ev: [*c]const sapp.Event) void {
    const e = ev.*;
    switch (e.type) {
        .MOUSE_DOWN => if (e.mouse_button == .LEFT) {
            G.press_started = G.last_time;
            sendPtt(true);
        },
        .MOUSE_UP => if (e.mouse_button == .LEFT) {
            const held = G.last_time - G.press_started;
            G.press_started = -1;
            sendPtt(false);
            if (held < 0.25) sendBack("{\"ev\":\"click\"}"); // cancel/dismiss
        },
        .KEY_DOWN => switch (e.key_code) {
            .ESCAPE, .Q => {
                sendBack("{\"ev\":\"quit\"}");
                sapp.requestQuit();
            },
            ._1 => if (G.opts.solo) {
                G.solo_active = false;
                G.solo_think = false;
                G.solo_speak = false;
            },
            ._2 => if (G.opts.solo) {
                G.solo_listen = !G.solo_listen;
            },
            ._3 => if (G.opts.solo) {
                G.solo_active = !G.solo_active;
            },
            ._4 => if (G.opts.solo) {
                G.solo_think = !G.solo_think;
            },
            ._5 => if (G.opts.solo) {
                G.solo_speak = !G.solo_speak;
                if (G.solo_speak) {
                    spawnCaption("Hello — this is a sample caption.");
                }
            },
            .SPACE => if (G.opts.solo) {
                G.solo_pulse = G.last_time;
                // Spawn another caption to demo stacking / fade.
                G.solo_caption_i +%= 1;
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Caption particle #{d}", .{G.solo_caption_i}) catch "Caption particle";
                spawnCaption(msg);
            },
            else => {},
        },
        else => {},
    }
}

export fn cleanup() void {
    // Window close / normal sokol teardown (titlebar X, q/esc quit path).
    releaseInstanceLock();
    if (G.font.ok) G.font.deinit();
    sg.shutdown();
}

// ---------------------------------------------------------------------------

pub fn run(io: std.Io, alloc: std.mem.Allocator, opts: Options, log: *std.Io.Writer) !void {
    G.alloc = alloc;
    G.io = io;
    G.opts = opts;
    G.start_ts = std.Io.Clock.Timestamp.now(io, .awake);

    acquireInstanceLock(io);
    installLockSignalHandlers();

    if (!opts.solo) {
        // fail fast, with an actionable message per missing service (§9.3)
        G.back_fd = connectBackFd() catch {
            emitStartupError(
                io,
                "error: ada back is not reachable (unix://{s})\n" ++
                    "       start it: systemctl --user start ada-back\n" ++
                    "       (or run the orb alone: ada avatar --solo)\n",
                .{opts.back_sock},
            );
            std.process.exit(1);
        };
        const perc = connectPerceptionLevels() catch {
            emitStartupError(
                io,
                "error: perception-voice levels stream is not reachable (unix://{s})\n" ++
                    "       start it: systemctl --user start perception-voice\n",
                .{opts.perception_sock},
            );
            std.process.exit(1);
        };
        // Presence levels are OPTIONAL for now: the `subscribe levels`
        // interface is milestone 5 (presence-voice side, Bob's). Until it
        // lands, the orb synthesizes a speaking pulse from state events; the
        // thread keeps retrying and picks the real stream up automatically.
        const pres: ?std.Io.net.Stream = connectPresenceLevels() catch blk: {
            try log.print(
                "warning: presence-voice levels stream unavailable (unix://{s})\n" ++
                    "         speaking pulse will be synthesized until `subscribe levels` lands\n",
                .{opts.presence_sock},
            );
            try log.flush();
            break :blk null;
        };

        _ = try std.Thread.spawn(.{}, backThread, .{});
        _ = try std.Thread.spawn(.{}, perceptionThread, .{@as(?std.Io.net.Stream, perc)});
        _ = try std.Thread.spawn(.{}, presenceThread, .{pres});
    }

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .width = opts.size,
        .height = opts.size,
        .sample_count = 4,
        .high_dpi = true, // full-res framebuffer on scaled displays
        .window_title = "ada",
        .logger = .{ .func = slog.func },
    });
}
