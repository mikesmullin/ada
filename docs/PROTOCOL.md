# Ada IPC protocols

Three processes, four sockets (see docs/PLAN.md §3). This file is the
authoritative wire spec. Where it differs from the draft plan it is because
the plan's assumptions didn't survive contact with the existing daemons'
actual protocols (noted inline).

## 1. FeatureFrame (binary, both voice services → avatar)

**36 bytes** little-endian, ~60 Hz. (The plan said 32, but the fields it
listed sum to 36 — the fields won.)

```
offset  type   field
0       u32    magic        'AVF1' = 0x31465641 LE (bytes "AVF1")
4       u32    stream_id    0 = mic (user), 1 = tts (ada)
8       f32    rms          0..1
12      f32[4] band         low / low-mid / high-mid / high energy, 0..1
28      f32    pitch_hint   Hz, 0 = none
32      u32    flags        bit0 voice-active (VAD)
                            bit1 stream-start (first frame of an utterance)
                            bit2 stream-end   (last frame of an utterance)
```

Frames are raw structs back-to-back on the socket — no per-frame length
prefix (fixed size). Receivers resync on `magic` if they ever misalign.

## 2. perception-voice (existing socket, new `subscribe` command)

Socket: `/workspace/perception-voice/perception.sock`.
Existing framing: **4-byte big-endian length prefix + JSON payload** (this
is the daemon's real protocol; the plan guessed line-delimited JSON).
The one-shot `get`/`set` request/response commands are unchanged.

New command — sent as a normal framed JSON request:

```json
{"command": "subscribe", "channel": "levels" | "words"}
```

The server replies with a framed `{"status":"ok","channel":...}` ack, then
the connection becomes a **push stream** (never closed by the server):

- `channel=levels` → raw binary FeatureFrames (§1), stream_id=0, ~60 Hz
  (two half-overlapping windows per 512-sample mic chunk @16 kHz = 62.5 Hz).
  Consumed by the avatar.
- `channel=words` → framed JSON messages (same 4-byte-BE framing), pushed
  the moment they exist. Consumed by the back:

```json
{"ev":"partial",   "ts":1234567890.123, "text":"turn on the des"}
{"ev":"utterance", "ts":1234567890.123, "text":"Turn on the desk light.",
 "t_start":1234567885.0, "t_end":1234567890.1}
```

`partial` events come from a secondary `tiny.en` decode of the in-progress
utterance buffer (net-new — the daemon previously only decoded after the
VAD tail). `utterance` is the finalized large-model decode.

One channel per connection; binary and JSON framing never mix.

## 3. presence-voice (existing socket, new `subscribe` line)

Socket: `/tmp/presence-voice.sock`.
Speak protocol: one text line per request,
`preset\tspeaker\teffects\tschedule\ttext\n` — speaker/effects may be
empty for daemon defaults — replied with `OK\n` / `ERR msg\n`. `OK`
arrives once the utterance is *enqueued* on the daemon's mixer (playback
is asynchronous; the levels stream in §1 is the playback-truth signal).

`schedule` is **required and explicit** — utterances collide, and the
caller must say which semantics it wants:

- `enqueue` — queue behind whatever speech is already playing. The
  daemon's speech channel is a strict FIFO, so consecutive enqueues play
  gapless in order (the back's per-sentence streaming path).
- `interrupt` — immediately silence any playing/queued speech, then speak.
  With **empty text** this is the stop primitive: silence, `OK`, nothing
  spoken (the back's click-cancel and barge-in path).

The back schedules a reply's opening sentence as `interrupt` and the
rest as `enqueue`. HTTP `POST /speak` mirrors this with a required
`"schedule"` JSON field for `mode=play`.

(Caveat observed live: line-format parse failures close the connection
without an `ERR` line.)

New request lines — same line framing:

**Status: implemented** (presence-voice commit `8863c4e`,
`src/audio/feature_tap.zig` — frames are computed in the sokol_audio
stream callback, i.e. the playback clock, so they align with what the
ears hear). The avatar still treats the stream as optional and falls back
to a synthesized speaking pulse if the daemon is old or unreachable.

- `subscribe\tlevels\n` → reply `OK\n`, then the connection becomes a push
  stream of binary FeatureFrames (§1), stream_id=1, ~60 Hz, computed from
  the PCM chunk the daemon is *about to write* to PulseAudio (aligned to
  the playback clock by chunked writes). stream-start/stream-end flags
  bracket each utterance. Consumed by the avatar.
- `subscribe\tevents\n` → reply `OK\n`, then a push stream of JSON lines:

```json
{"ev":"speak-start","text":"..."}
{"ev":"speak-end"}
```

## 4. avatar ⇄ back (JSON lines)

Socket: `$XDG_RUNTIME_DIR/ada-back.sock` (fallback `/tmp/ada-back.sock`).
The back is the server (long-lived systemd unit); the avatar connects and
**fails fast** with a clear error if it can't (plan §9.3).

Line-delimited JSON, one object per line:

```
back → avatar:  {"ev":"state", "listening":true, "active":false,
                  "thinking":false, "speaking":false}
                 {"ev":"caption", "who":"ada"|"user", "text":"..."}   // future
avatar → back:  {"ev":"ptt", "down":true|false}
                 {"ev":"click"}     // short press: cancel / dismiss
                 {"ev":"quit"}
```

Press-and-hold semantics: the avatar sends `ptt down:true` on left-button
press immediately (latency), `down:false` on release; if the hold was
shorter than 250 ms it also sends `click` — the back treats a sub-250 ms
PTT window with no speech as a no-op, and `click` cancels any pending or
speaking turn (whisper-style cancel-before-commit).
