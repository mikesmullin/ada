//! `ada avatar` — the orb overlay (docs/PLAN.md §4).
//!
//! Render thread: sokol_app + sokol_gfx drive a single fullscreen-quad
//! shader; all animation state arrives as smoothed uniforms.
//! Socket threads: brain (JSON lines, bidirectional), perception-voice
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
const ipc = @import("ipc.zig");

pub const Options = struct {
    solo: bool = false,
    brain_sock: []const u8,
    perception_sock: []const u8,
    presence_sock: []const u8,
    size: i32 = 200,
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

    var brain_conn: ?std.Io.net.Stream = null;
    var brain_mu: std.Io.Mutex = .init; // guards brain_conn writes/sends

    var start_ts: std.Io.Clock.Timestamp = undefined;
    var last_time: f64 = 0;
    var press_started: f64 = -1;

    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};

    // --solo keyboard toggles
    var solo_listen: bool = true;
    var solo_active: bool = false;
    var solo_think: bool = false;
    var solo_speak: bool = false;
    var solo_pulse: f64 = -10;
};

// ---------------------------------------------------------------------------
// Single-instance lock: one orb per machine. flock() is held for the
// process lifetime and released by the kernel on ANY exit (crash included),
// so there are no stale-lock states to clean up. Anchored to the repo
// checkout like the rest of this ecosystem's fixed paths.

const LOCK_PATH = "/workspace/ada/.avatar.lock";

extern "c" fn flock(fd: c_int, operation: c_int) c_int;
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;

fn acquireInstanceLock(io: std.Io, log: *std.Io.Writer) !void {
    const file = std.Io.Dir.cwd().createFile(io, LOCK_PATH, .{
        .read = true,
        .truncate = false,
    }) catch |err| {
        try log.print("error: cannot open instance lock {s}: {t}\n", .{ LOCK_PATH, err });
        try log.flush();
        std.process.exit(1);
    };
    if (flock(file.handle, LOCK_EX | LOCK_NB) != 0) {
        var pid_buf: [32]u8 = undefined;
        var reader = file.reader(io, &pid_buf);
        const other = reader.interface.takeDelimiterExclusive('\n') catch "";
        try log.print(
            "error: another ada avatar is already running{s}{s} (lock: {s})\n",
            .{ if (other.len > 0) " with pid " else "", other, LOCK_PATH },
        );
        try log.flush();
        std.process.exit(1);
    }
    // lock held: record our pid for diagnostics and keep the fd open forever
    var wbuf: [32]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    writer.interface.print("{d}\n", .{std.c.getpid()}) catch {};
    writer.interface.flush() catch {};
    // `file` intentionally never closed — the lock lives exactly as long
    // as this process does.
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
// Brain socket (JSON lines, bidirectional)

fn connectBrain() !std.Io.net.Stream {
    const addr = try std.Io.net.UnixAddress.init(G.opts.brain_sock);
    return try addr.connect(G.io);
}

fn nowSeconds() f64 {
    const now = std.Io.Clock.Timestamp.now(G.io, .awake);
    const dur = G.start_ts.durationTo(now);
    return @as(f64, @floatFromInt(dur.raw.nanoseconds)) / 1e9;
}

fn sleepSecond() void {
    G.io.sleep(.{ .nanoseconds = 1_000_000_000 }, .awake) catch {};
}

fn sendBrain(line: []const u8) void {
    G.brain_mu.lockUncancelable(G.io);
    defer G.brain_mu.unlock(G.io);
    const conn = &(G.brain_conn orelse return);
    var buf: [256]u8 = undefined;
    var w = conn.writer(G.io, &buf);
    w.interface.writeAll(line) catch return;
    w.interface.writeAll("\n") catch return;
    w.interface.flush() catch return;
}

fn sendPtt(down: bool) void {
    sendBrain(if (down) "{\"ev\":\"ptt\",\"down\":true}" else "{\"ev\":\"ptt\",\"down\":false}");
}

const StateMsg = struct {
    ev: []const u8,
    listening: bool = false,
    active: bool = false,
    thinking: bool = false,
    speaking: bool = false,
};

fn handleBrainLine(line: []const u8) void {
    const parsed = std.json.parseFromSlice(StateMsg, G.alloc, line, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    const msg = parsed.value;
    if (!std.mem.eql(u8, msg.ev, "state")) return; // captions are future work

    G.targets.mu.lockUncancelable(G.io);
    defer G.targets.mu.unlock(G.io);
    G.targets.listening = if (msg.listening) 1 else 0;
    G.targets.active = if (msg.active) 1 else 0;
    G.targets.thinking = if (msg.thinking) 1 else 0;
    G.targets.speaking = if (msg.speaking) 1 else 0;
}

fn brainThread() void {
    while (true) {
        const conn = blk: {
            G.brain_mu.lockUncancelable(G.io);
            defer G.brain_mu.unlock(G.io);
            break :blk G.brain_conn;
        };
        if (conn) |c| {
            var buf: [8192]u8 = undefined;
            var reader = c.reader(G.io, &buf);
            while (true) {
                const line = reader.interface.takeDelimiterExclusive('\n') catch break;
                handleBrainLine(line);
            }
            // connection lost
            G.brain_mu.lockUncancelable(G.io);
            if (G.brain_conn) |*dead| dead.close(G.io);
            G.brain_conn = null;
            G.brain_mu.unlock(G.io);
            setConnected(false);
        }
        sleepSecond();
        if (connectBrain()) |fresh| {
            G.brain_mu.lockUncancelable(G.io);
            G.brain_conn = fresh;
            G.brain_mu.unlock(G.io);
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

    G.pip = sg.makePipeline(.{
        .shader = sg.makeShader(shd.orbShaderDesc(sg.queryBackend())),
        .layout = init: {
            var l = sg.VertexLayoutState{};
            l.attrs[shd.ATTR_orb_position].format = .FLOAT2;
            break :init l;
        },
    });
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
    }

    if (G.opts.solo) soloDrive(&tgt, now);

    // Until presence-voice grows its feature-frame stream (milestone 5, in
    // Bob's court — see docs/PLAN.md §5a), synthesize a speaking pulse from
    // the brain's speaking state so the core still animates with her voice.
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

    sg.beginPass(.{ .swapchain = sglue.swapchain() });
    sg.applyPipeline(G.pip);
    sg.applyBindings(G.bind);
    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&params));
    sg.draw(0, 3, 1);
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
            if (held < 0.25) sendBrain("{\"ev\":\"click\"}"); // cancel/dismiss
        },
        .KEY_DOWN => switch (e.key_code) {
            .ESCAPE, .Q => {
                sendBrain("{\"ev\":\"quit\"}");
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
            },
            .SPACE => if (G.opts.solo) {
                G.solo_pulse = G.last_time;
            },
            else => {},
        },
        else => {},
    }
}

export fn cleanup() void {
    sg.shutdown();
}

// ---------------------------------------------------------------------------

pub fn run(io: std.Io, alloc: std.mem.Allocator, opts: Options, log: *std.Io.Writer) !void {
    G.alloc = alloc;
    G.io = io;
    G.opts = opts;
    G.start_ts = std.Io.Clock.Timestamp.now(io, .awake);

    try acquireInstanceLock(io, log);

    if (!opts.solo) {
        // fail fast, with an actionable message per missing service (§9.3)
        G.brain_conn = connectBrain() catch {
            try log.print(
                "error: ada brain is not reachable (unix://{s})\n" ++
                    "       start it: systemctl --user start ada-brain\n" ++
                    "       (or run the orb alone: ada avatar --solo)\n",
                .{opts.brain_sock},
            );
            try log.flush();
            std.process.exit(1);
        };
        const perc = connectPerceptionLevels() catch {
            try log.print(
                "error: perception-voice levels stream is not reachable (unix://{s})\n" ++
                    "       start it: systemctl --user start perception-voice\n",
                .{opts.perception_sock},
            );
            try log.flush();
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

        _ = try std.Thread.spawn(.{}, brainThread, .{});
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
        .window_title = "ada",
        .logger = .{ .func = slog.func },
    });
}
