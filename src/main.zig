//! ada — always-on desktop assistant. Subcommand-style CLI (like `voice`):
//! `ada avatar` opens the orb overlay; the back runs separately as a Bun
//! systemd --user unit (back/ada-back.mjs). See docs/PLAN.md.

const std = @import("std");
const avatar = @import("avatar.zig");

const VERSION = "0.1.0";

const HELP =
    \\ada — always-on desktop assistant
    \\
    \\usage:
    \\  ada avatar [options]     open the orb overlay window
    \\  ada coach [options]      M6 coach: plan next step from task list + speak
    \\  ada plan [options]       alias for `ada coach`
    \\  ada version              print version
    \\  ada help                 this text
    \\
    \\coach options (forwarded to back/ada-coach.coffee):
    \\  --quiet / -q             JSON only on stdout
    \\  --dry-run                plan only (no speech); still runs the microagent
    \\  --no-speak               print plan, do not call presence-voice
    \\  --list / -l LABEL        task list label (default shared)
    \\  -n / --limit N           how many todo next rows to feed the coach
    \\
    \\avatar options:
    \\  --solo                   no services: keyboard-driven states
    \\                           (1 idle, 2 listening, 3 active, 4 thinking,
    \\                            5 speaking, space pulse, q/esc quit)
    \\  --style orb|hud          visual style (default hud):
    \\                             orb: glowing liquid orb
    \\                             hud: holographic reticle w/ radial spectrums
    \\  --size N                 window size in px (default 320)
    \\  --back-sock PATH        default $XDG_RUNTIME_DIR/ada-back.sock
    \\  --perception-sock PATH   default /workspace/perception-voice/perception.sock
    \\  --presence-sock PATH     default /tmp/presence-voice.sock
    \\
    \\orb input: hold left button = push-to-talk; short click = cancel.
    \\
;

fn defaultAdaRoot(alloc: std.mem.Allocator) []const u8 {
    if (std.c.getenv("ADA_ROOT")) |r| return std.mem.span(r);
    // Dev default on this machine; override with ADA_ROOT when installed elsewhere.
    _ = alloc;
    return "/workspace/ada";
}

/// `ada coach` / `ada plan` → `bun back/ada-coach.coffee …` (cwd = back/ for bunfig).
fn runCoach(io: std.Io, alloc: std.mem.Allocator, args: []const []const u8) !void {
    const root = defaultAdaRoot(alloc);
    const script = try std.fmt.allocPrint(alloc, "{s}/back/ada-coach.coffee", .{root});
    const back_dir = try std.fmt.allocPrint(alloc, "{s}/back", .{root});

    var child_args: std.ArrayList([]const u8) = .empty;
    defer child_args.deinit(alloc);
    try child_args.append(alloc, "bun");
    try child_args.append(alloc, script);
    // Forward everything after `coach` / `plan`
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        try child_args.append(alloc, args[i]);
    }

    var child = try std.process.spawn(io, .{
        .argv = child_args.items,
        .cwd = .{ .path = back_dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        else => std.process.exit(1),
    }
}

fn defaultBackSock(alloc: std.mem.Allocator) []const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
        return std.fmt.allocPrint(alloc, "{s}/ada-back.sock", .{std.mem.span(dir)}) catch "/tmp/ada-back.sock";
    }
    return "/tmp/ada-back.sock";
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const cmd = if (args.len > 1) args[1] else "help";

    if (std.mem.eql(u8, cmd, "avatar")) {
        var opts = avatar.Options{
            .back_sock = defaultBackSock(arena),
            .perception_sock = "/workspace/perception-voice/perception.sock",
            .presence_sock = "/tmp/presence-voice.sock",
        };
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--solo")) {
                opts.solo = true;
            } else if (std.mem.eql(u8, a, "--style") and i + 1 < args.len) {
                i += 1;
                opts.style = std.meta.stringToEnum(avatar.Style, args[i]) orelse {
                    try stdout.print("error: unknown style '{s}' (orb|hud)\n", .{args[i]});
                    try stdout.flush();
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
                i += 1;
                opts.size = try std.fmt.parseInt(i32, args[i], 10);
            } else if (std.mem.eql(u8, a, "--back-sock") and i + 1 < args.len) {
                i += 1;
                opts.back_sock = args[i];
            } else if (std.mem.eql(u8, a, "--perception-sock") and i + 1 < args.len) {
                i += 1;
                opts.perception_sock = args[i];
            } else if (std.mem.eql(u8, a, "--presence-sock") and i + 1 < args.len) {
                i += 1;
                opts.presence_sock = args[i];
            } else {
                try stdout.print("error: unknown avatar option '{s}'\n\n{s}", .{ a, HELP });
                try stdout.flush();
                std.process.exit(1);
            }
        }
        try avatar.run(init.io, arena, opts, stdout);
        return;
    }

    if (std.mem.eql(u8, cmd, "coach") or std.mem.eql(u8, cmd, "plan")) {
        try runCoach(init.io, arena, args);
        return;
    }

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try stdout.print("ada {s}\n", .{VERSION});
        try stdout.flush();
        return;
    }

    try stdout.print("{s}", .{HELP});
    try stdout.flush();
}
