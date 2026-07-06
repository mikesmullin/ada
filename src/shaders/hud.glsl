// Ada "hud" style — sci-fi holographic reticle (docs/PLAN.md §4 + the
// VEGA-style concept in /workspace/voice/tmp/ADA_SHADER2.md): concentric
// technical rings rotating at different speeds/directions (angular
// parallax), plus two circular spectrum visualizers — the user's voice as
// outward bars on the outer ring, Ada's voice as inward bars around the
// core. Same uniform block as orb.glsl, so every state signal drives both
// styles identically.

@vs vs
in vec2 position;
out vec2 uv;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    uv = position;
}
@end

@fs fs
layout(binding=0) uniform fs_params {
    vec4 res_time;  // x: width, y: height, z: time (s), w: press 0..1
    vec4 states_a;  // x: idle, y: listening, z: active, w: thinking
    vec4 states_b;  // x: speaking, y: brain-connected, z,w: unused
    vec4 user_a;    // x: rms, yzw: band 0..2      (mic / the user)
    vec4 user_b;    // x: band 3, y: attack env, z: vad, w: unused
    vec4 ada_a;     // x: rms, yzw: band 0..2      (tts / ada)
    vec4 ada_b;     // x: band 3, y: attack env, z,w: unused
};

in vec2 uv;
out vec4 frag_color;

const float PI  = 3.14159265;
const float TAU = 6.28318531;

float hash1(float n) {
    return fract(sin(n) * 43758.5453123);
}

// interpolate the 4 band energies across x in [0,1]
float band4(vec4 b, float x) {
    float s = clamp(x, 0.0, 1.0) * 3.0;
    float i = floor(s);
    float f = s - i;
    float lo = i < 0.5 ? b.x : (i < 1.5 ? b.y : b.z);
    float hi = i < 0.5 ? b.y : (i < 1.5 ? b.z : b.w);
    return mix(lo, hi, f);
}

// crisp antialiased ring line at radius r0 with half-width w
float ringLine(float r, float r0, float w, float aa) {
    return smoothstep(w + aa, w - aa, abs(r - r0));
}

// angular dash pattern: n repeats, duty in 0..1, phase rotates
float dashes(float th, float n, float duty, float phase) {
    float f = fract(th / TAU * n + phase);
    return step(f, duty);
}

// circular spectrum: bars anchored at radius `base`, extending `dir`
// (+1 outward / -1 inward), driven by 4 bands + rms with animated
// per-bar jitter so 4 bands read as a live many-bin visualizer
float spectrum(float r, float th, float base, float dir, float maxLen,
               vec4 bands, float rms, float nbars, float t, float seed, float aa) {
    float pos = fract(th / TAU);
    float bar = floor(pos * nbars);
    // mirror around the top so lows sit at 12 o'clock, highs at the bottom
    float x = abs(fract(pos + 0.25) - 0.5) * 2.0;
    float h1 = hash1(bar * 7.13 + seed);
    float h2 = hash1(bar * 3.71 + seed * 1.7);
    float jitter = 0.55 + 0.45 * sin(t * (2.5 + h1 * 8.0) + h2 * TAU);
    float amp = band4(bands, x) * jitter + rms * 0.25 * jitter;
    float len = (0.012 + maxLen * amp);
    // radial extent
    float t0 = (r - base) * dir;
    float radial = smoothstep(-aa, aa, t0) * smoothstep(len + aa, len - aa, t0);
    // angular duty: gap between bars
    float f = fract(pos * nbars);
    float ang = smoothstep(0.12, 0.20, f) * smoothstep(0.88, 0.80, f);
    return radial * ang * (0.35 + amp);
}

void main() {
    float t     = res_time.z;
    float press = res_time.w;

    float w_idle   = states_a.x;
    float w_listen = states_a.y;
    float w_active = states_a.z;
    float w_think  = states_a.w;
    float w_speak  = states_b.x;
    float connected = states_b.y;

    float u_rms = user_a.x;
    vec4  u_band = vec4(user_a.yzw, user_b.x);
    float u_env = user_b.y;
    float a_rms = ada_a.x;
    vec4  a_band = vec4(ada_a.yzw, ada_b.x);
    float a_env = ada_b.y;

    // centered, aspect-corrected; scaled so the outer ring fits the window
    vec2 p = uv;
    p.x *= res_time.x / res_time.y;
    float r = length(p) * 1.06;
    float th = atan(p.y, p.x);
    float aa = fwidth(r) * 1.4;

    // ---- palette ----------------------------------------------------------
    vec3 cyan   = vec3(0.15, 0.75, 1.00);  // baseline linework
    vec3 white  = vec3(0.85, 0.97, 1.00);
    vec3 violet = vec3(0.62, 0.42, 1.00);  // thinking
    vec3 amber  = vec3(1.00, 0.68, 0.25);  // active attention
    vec3 warm   = vec3(0.45, 0.95, 1.00);  // her voice

    // thinking spins the machinery up; a dead brain stalls it
    float spin = (1.0 + 2.2 * w_think) * (0.15 + 0.85 * connected);
    float breath = 0.5 + 0.5 * sin(t * 0.7);
    float gain = 0.32 + 0.20 * breath * w_idle
               + 0.28 * w_listen * u_rms
               + 0.35 * w_active + 0.30 * w_speak + 0.25 * w_think;

    vec3 col = vec3(0.004, 0.009, 0.016);
    // subtle scanlines + faint noise sparkle
    col += vec3(0.010, 0.016, 0.022) * (0.5 + 0.5 * sin(uv.y * res_time.y * PI * 0.5));
    col *= 0.9 + 0.1 * hash1(floor(uv.x * res_time.x) + floor(uv.y * res_time.y) * 917.0 + floor(t * 24.0));

    vec3 ink = mix(cyan, violet, 0.75 * w_think);

    // ---- concentric technical rings (the parallax stack) ------------------
    // radius, angular count, duty, speed, weight
    {
        float rr; float mask;

        // r .295: fine inner dashes (spins with her speech energy too)
        rr = th + t * spin * 0.55 + a_rms * w_speak * 0.8;
        mask = ringLine(r, 0.295, 0.0035, aa) * dashes(rr, 64.0, 0.55, 0.0);
        col += ink * mask * gain * 1.1;

        // r .375: sparse ticks, counter-rotating
        rr = th - t * spin * 0.35;
        mask = ringLine(r, 0.375, 0.0100, aa) * dashes(rr, 96.0, 0.14, 0.0);
        col += ink * mask * gain * 0.9;

        // r .52: eight segmented arcs with a traveling data pulse
        rr = th + t * spin * 0.22;
        float seg = dashes(rr, 8.0, 0.72, 0.0);
        mask = ringLine(r, 0.520, 0.0028, aa) * seg;
        col += ink * mask * gain;
        float pulse = smoothstep(0.10, 0.0, abs(fract(th / TAU - t * (0.10 + 0.35 * w_think)) - 0.5) - 0.45);
        col += white * ringLine(r, 0.520, 0.0028, aa) * seg * pulse * (0.25 + 1.2 * w_think) * gain;

        // r .60: dense micro-dashes, fast counter-rotation
        rr = th - t * spin * 0.85;
        mask = ringLine(r, 0.600, 0.0022, aa) * dashes(rr, 140.0, 0.38, 0.0);
        col += ink * mask * gain * 0.75;

        // r .80: thin solid ring + degree ticks (the "dial")
        mask = ringLine(r, 0.800, 0.0016, aa);
        col += ink * mask * gain * 0.9;
        rr = th + t * spin * 0.12;
        mask = ringLine(r, 0.815, 0.0075, aa) * dashes(rr, 180.0, 0.10, 0.0);
        col += ink * mask * gain * 0.7;

        // r .93: sparse outer arcs, slow
        rr = th - t * spin * 0.07;
        mask = ringLine(r, 0.930, 0.0022, aa) * dashes(rr, 4.0, 0.55, 0.125);
        col += ink * mask * gain * 0.85;
    }

    // ---- active: targeting brackets snap in (amber) ------------------------
    if (w_active > 0.003) {
        float snap = 0.90 - 0.045 * w_active; // brackets slide inward as it engages
        float rot = th + sin(t * 0.6) * 0.05;
        float brk = ringLine(r, snap, 0.0055, aa) * dashes(rot, 3.0, 0.16, t * 0.02);
        col += amber * brk * w_active * (0.9 + 0.6 * u_rms);
    }

    // ---- user spectrum: outward bars on the outer ring ---------------------
    {
        float amt = 0.30 * w_listen + 1.0 * w_active;
        if (amt > 0.003) {
            float s = spectrum(r, th, 0.665, 1.0, 0.115, u_band, u_rms, 56.0, t, 3.0, aa);
            vec3 hue = mix(cyan, amber, 0.55 * w_active);
            col += hue * s * amt * 1.4;
            // attack flash: rim shimmer on plosives
            col += hue * ringLine(r, 0.665, 0.004, aa) * u_env * amt;
        }
    }

    // ---- ada spectrum: inward bars around the core + pulsing heart --------
    {
        float s = spectrum(r, th, 0.245, -1.0, 0.10, a_band, a_rms, 44.0, t, 11.0, aa);
        col += warm * s * w_speak * 1.6;

        // core: small disc pulsing with her voice; her highs whiten it
        float coreR = 0.055 + 0.030 * a_rms * w_speak + 0.008 * breath * w_idle;
        float core = smoothstep(coreR + aa, coreR - aa, r);
        vec3 core_col = mix(ink * 0.55, warm, w_speak * (0.4 + 0.6 * a_rms));
        core_col = mix(core_col, white, 0.5 * a_band.w * w_speak);
        col += core_col * core * (0.5 + 0.9 * a_rms * w_speak + 0.25 * breath * w_idle);
        col += warm * exp(-abs(r - coreR) * 26.0) * (0.10 + 0.55 * a_rms * w_speak + 0.2 * a_env);
    }

    // ---- thinking: orbiting comets between the inner rings -----------------
    if (w_think > 0.003) {
        for (int i = 0; i < 3; i++) {
            float ang = t * (1.6 + 0.3 * float(i)) + float(i) * TAU / 3.0;
            vec2 sp = vec2(cos(ang), sin(ang)) * 0.44;
            float d = length(p * 1.06 - sp);
            col += violet * exp(-d * d * 1200.0) * 1.5 * w_think;
            // short trail
            vec2 sp2 = vec2(cos(ang - 0.18), sin(ang - 0.18)) * 0.44;
            col += violet * exp(-dot(p * 1.06 - sp2, p * 1.06 - sp2) * 2000.0) * 0.6 * w_think;
        }
    }

    // ---- PTT press: bright reticle ring ------------------------------------
    col += white * ringLine(r, 0.86, 0.0035 + 0.002 * press, aa) * press * 1.2;

    // ---- soft interior haze so it never reads as empty ----------------------
    col += ink * exp(-r * 2.6) * 0.05 * (1.0 + 1.5 * w_speak * a_rms + u_rms * w_active);

    // ---- brain lost: dim red, machinery stalled -----------------------------
    vec3 err = vec3(dot(col, vec3(0.35))) * vec3(1.2, 0.18, 0.14);
    col = mix(err, col, clamp(connected, 0.0, 1.0));

    // gentle tone-map
    col = col / (1.0 + col * 0.30);
    frag_color = vec4(col, 1.0);
}
@end

@program hud vs fs
