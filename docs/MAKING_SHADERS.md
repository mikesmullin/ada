# Making Ada avatar shaders (styles)

How to add a new visual style to `ada avatar`. Written so a future session
can be pointed at this doc plus one request ("make me a style like X") and
produce a good one on the first try. The two existing styles are the
reference implementations: `src/shaders/orb.glsl` (liquid glowing orb) and
`src/shaders/hud.glsl` (VEGA-style holographic reticle, concept in
`/workspace/voice/tmp/ADA_SHADER2.md`).

## Architecture in one paragraph

Every style is a single fragment shader on a fullscreen triangle. The host
(`src/avatar.zig`) computes ALL state — socket IO, smoothing, gating — and
hands the shader one uniform block per frame. Styles differ only in
artwork: same vertex shader, same uniform block, same vertex layout. A
style is selected once at startup (`ada avatar --style <name>`); there is
no runtime switching. Shaders are compiled at build time by sokol-shdc
into Zig sources (gitignored `src/shaders/*.glsl.zig`), cross-compiled for
GL/GLES/Metal/HLSL/WGSL so don't use GL-only tricks.

## The uniform contract (identical in every style — copy it verbatim)

```glsl
layout(binding=0) uniform fs_params {
    vec4 res_time;  // x: width px, y: height px, z: time s, w: press 0..1
    vec4 states_a;  // x: idle, y: listening, z: active, w: thinking
    vec4 states_b;  // x: speaking, y: back-connected, z,w: unused
    vec4 user_a;    // x: rms, yzw: band 0..2      (mic / the user)
    vec4 user_b;    // x: band 3, y: attack env, z: vad, w: unused
    vec4 ada_a;     // x: rms, yzw: band 0..2      (tts / ada)
    vec4 ada_b;     // x: band 3, y: attack env, z,w: unused
};
```

Semantics you can rely on:

- **All weights are pre-smoothed** host-side with attack/release envelopes
  (fast rise, slower fall) — never snap, always crossfade. Multiple states
  are >0 simultaneously by design; **Ada listens while she speaks**, so
  user-audio and ada-audio visuals must be able to layer without fighting.
- `idle` = 1 − max(active, thinking, speaking). Listening is almost always
  ~1 in practice, so "listening" visuals must be *subtle* — idle is the
  resting look, listening only adds a whisper of reactivity.
- `press` is PTT feedback (left button held on the window).
- `connected` < 1 means the back is unreachable: the style must have a
  clearly "wounded" look (both existing styles desaturate toward dim red
  and slow/stall their motion).
- Audio: `rms` and 4 spectral bands per stream, 0..1, ~60 Hz from the
  actual audio pipelines (band edges 0–300/300–1k/1k–3k/3k–8k Hz; bass in
  .y, treble in `*_b.x`). `env` spikes on attacks/plosives — great for
  flashes and ripples. `vad` is mic voice-activity (user stream only).
- The host force-opens `speaking` whenever ada frames carry audible rms
  (playback truth beats back state timing) — so gating her visuals on
  `w_speak * a_rms` is correct and will animate in sync with her actual
  voice.

## The color language (keep it consistent across styles)

Mike's eyes are trained on these; a new style can restyle the *forms* but
should keep the hue semantics unless he asks otherwise:

| signal | hue |
|---|---|
| baseline / linework / idle | cyan-blue |
| user's voice | cool cyan (shift toward **amber** when `active`) |
| active / engaged attention | **amber** |
| thinking | **violet** |
| Ada's voice / core | **warm bright cyan-white** |
| back lost | dim **red**, motion stalled |

## Techniques that work (learned the hard way)

- **Resolution independence is about content, not buffers.** The
  framebuffer always tracks the window natively; "looks upscaled" means
  your detail frequencies are too low. Give noise 6+ octaves / include a
  fine-detail layer; it MSAA-averages away at small sizes and shines at
  fullscreen. Cost is irrelevant (RTX 5070 Ti; these shaders are ~free).
- **Crisp lines**: antialias with `fwidth`-based smoothsteps
  (`aa = fwidth(r) * 1.4`, see `ringLine()` in hud.glsl). Never hardcode
  pixel-ish widths without it.
- **4 bands → convincing spectrum**: interpolate the 4 band energies
  across bar position (`band4()` in hud.glsl), mirror around 12 o'clock
  (lows at top like real radial analyzers), and give each bar animated
  jitter (`hash(bar)`-seeded sine). Reads as a live many-bin FFT.
- **Compositing**: build the image additively into `col`, then soft
  tone-map `col / (1.0 + col * k)` so stacked layers saturate gracefully
  instead of clipping.
- **Polar everything** for circular styles: `r = length(p)`,
  `th = atan(p.y, p.x)`; aspect-correct first (`p.x *= width/height`).
  Angular patterns are `fract(th/TAU * n + phase)` games.
- **Angular parallax sells depth**: concentric elements rotating at
  different speeds *and directions*. Tie the speed multiplier to
  `thinking` for a "machinery spinning up" feel.
- Time comes ONLY from `res_time.z` (starts at 0 per run). No wall-clock
  assumptions.

## State → motion mapping (what each signal should *do*)

The forms are yours to invent; the signals below must each stay visually
identifiable, including overlapped:

- `idle`: slow breathing/drift. Calm, dark, never distracting.
- `listening` (passive): the user's voice faintly ripples something outer.
- `active`: unmistakable "I'm engaged" — brighter, amber accents, user's
  voice drives strong reaction (bass = big/slow, treble = fine/fast).
- `thinking`: sustained motion (orbits, spin-up, traveling pulses) that
  reads even in a screenshot… but especially in motion.
- `speaking`: her actual waveform animates an inner/core element — this is
  the "mouth". Must track `a_rms`/`a_band` tightly, not just the state.
- `press`: immediate, local, bright — a tactile acknowledgment.
- attack `env`s: transient flashes/ripples, decay fast.

## Adding a style, step by step

1. `cp src/shaders/hud.glsl src/shaders/<name>.glsl` (best template) and
   change the last line to `@program <name> vs fs`. Keep `@vs vs` and the
   uniform block byte-identical.
2. `build.zig`: add `"<name>"` to the `shader_names` array. Done — the
   shdc step is generated per name.
3. `src/avatar.zig`: add to `pub const Style = enum { orb, hud, <name> };`,
   add `const shd_<name> = @import("shaders/<name>.glsl.zig");` and a
   switch arm in `init()`: `.<name> => shd_<name>.<name>ShaderDesc(sg.queryBackend()),`.
4. `src/main.zig`: the `--style` flag parses the enum automatically
   (`std.meta.stringToEnum`); just update the HELP text.
5. `zig build -Doptimize=ReleaseSafe` — shdc reports GLSL errors with line
   numbers. Gotchas: constant loop bounds only; no `#version` (shdc adds
   it); every uniform block needs `layout(binding=N)`; must compile for
   all five backends, so stick to vanilla GLSL (no textures needed so far).

## Testing/iterating without bothering anyone

- `ada avatar --solo --style <name> --size 500` — no services needed.
  Keys: `1` reset to idle, `2` listening, `3` active, `4` thinking,
  `5` speaking (toggles, they combine), `space` audio pulse; solo mode
  synthesizes fake audio for whichever streams the states imply.
- Force states remotely for screenshots:
  `W=$(DISPLAY=:0 xdotool search --class ada | head -1)` then
  `DISPLAY=:0 xdotool key --window $W 3 5` etc.
- Screenshot: get geometry via
  `eval $(DISPLAY=:0 xdotool getwindowgeometry --shell $W)` then
  `ffmpeg -f x11grab -video_size ${WIDTH}x${HEIGHT} -i :0.0+${X},${Y} -frames:v 1 out.png`
  (clamp the region to the desktop or the grab errors). Inspect a zoomed
  crop (`-vf "crop=…,scale=…:flags=neighbor"`) for sharpness claims.
- Real-audio pass: run the full stack (`ada avatar --style <name>`), then
  drive her voice repeatably with
  `printf 'ada\t\t\tenqueue\tA long test sentence for the inner ring.\n' | socat - UNIX-CONNECT:/tmp/presence-voice.sock`
  (or just `voice ada "..."`). Capture mid-sentence.
- Judge states in this order: idle first (it's what's on screen 95% of the
  time — it must be gorgeous *and* ignorable), then speaking, then the
  overlaps (active+speaking is the money shot).
- Kill a stuck avatar with `pkill -9 -x ada` (exact name — `pkill -f` has
  a habit of matching your own shell), single-instance flock means only
  one runs at a time.

## House rules

- Never repurpose or reorder the uniform block; add new styles, not new
  fields, unless every style + avatar.zig are updated together.
- Preserve every signal listed above — Mike explicitly wants the full
  set of overlapping state animations in all styles.
- `hud` is the default style (Mike's pick); new styles ship behind
  `--style` until he promotes one.
- One commit per style, screenshots verified before claiming it works.
