// Ada's orb — single fullscreen-quad procedural shader (docs/PLAN.md §4).
// No art assets; everything is uniforms. States crossfade (several can be
// active at once — Ada listens while she speaks).

@vs vs
in vec2 position;
out vec2 uv;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    uv = position; // -1..1, aspect-corrected in the fragment shader
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

// -- noise ------------------------------------------------------------
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i + vec2(0, 0)), hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

// 6 octaves: the original 4 were tuned for a ~160px orb and read as soft
// upscaled blobs on a large window; the extra octaves carry fine detail
// that MSAA simply averages away at small sizes. Still trivially cheap.
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 6; i++) {
        v += a * noise(p);
        p = p * 2.03 + vec2(17.3, 9.1);
        a *= 0.5;
    }
    return v;
}

vec2 rot(vec2 p, float a) {
    float c = cos(a), s = sin(a);
    return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
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
    float a_rms = ada_a.x;
    vec4  a_band = vec4(ada_a.yzw, ada_b.x);

    // aspect-corrected coords, orb centered
    vec2 p = uv;
    p.x *= res_time.x / res_time.y;
    float r = length(p);
    float theta = atan(p.y, p.x);

    // ---- core radius: breathing + bass swell + speech pulse ----------
    float radius = 0.34
        + 0.012 * sin(t * 0.9) * (0.4 + 0.6 * w_idle)     // breathing
        + 0.050 * u_band.x * w_active                      // your bass swells it
        + 0.045 * a_rms * w_speak;                         // her voice pulses it

    // surface wobble: fbm ripple; thinking adds an inner swirl rotation
    vec2 np = rot(p, t * (0.15 + 0.9 * w_think));
    float wob = fbm(np * 3.0 + vec2(t * 0.25, -t * 0.17));
    radius += (wob - 0.5) * 0.035;

    // ---- palette ------------------------------------------------------
    vec3 col_core   = vec3(0.10, 0.55, 0.85);   // teal-blue
    vec3 col_speak  = vec3(0.25, 0.85, 0.95);   // bright cyan when she talks
    vec3 col_think  = vec3(0.55, 0.35, 0.95);   // violet swirl
    vec3 col_active = vec3(0.95, 0.65, 0.25);   // amber attention
    vec3 col_err    = vec3(0.6, 0.1, 0.1);      // brain lost

    vec3 core_col = col_core;
    core_col = mix(core_col, col_speak,  clamp(w_speak * (0.5 + 0.9 * a_rms), 0.0, 1.0));
    core_col = mix(core_col, col_think,  0.65 * w_think);
    core_col = mix(core_col, col_active, 0.45 * w_active);
    core_col = mix(col_err, core_col, connected);

    // spectral tint: her highs sparkle the core toward white
    core_col += vec3(0.35) * a_band.w * w_speak;

    // ---- core disc ----------------------------------------------------
    float core = smoothstep(radius + 0.012, radius - 0.06, r);
    float core_glow = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 0.8))
                    * (w_idle * 0.35 + 0.15)
                    + 0.9 * a_rms * w_speak
                    + 0.4 * u_rms * w_active;
    // inner texture: darker fbm veins so the surface reads as liquid, plus
    // a fine high-frequency layer that keeps the surface crisp fullscreen
    float veins = fbm(np * 5.0 + vec2(0.0, t * 0.35));
    float grain = fbm(np * 17.0 - vec2(t * 0.12, t * 0.21));
    vec3 core_out = core_col * core * core_glow * (0.68 + 0.45 * veins + 0.22 * grain);

    // ---- halo: your voice lives here (outer, both passive + active) ---
    float halo_falloff = exp(-max(r - radius, 0.0) * 7.0);
    // per-band ripples around the rim: bass = slow wide, treble = fine fast
    float shimmer =
          u_band.x * 0.9 * sin(theta *  3.0 + t * 1.6)
        + u_band.y * 0.7 * sin(theta *  7.0 - t * 2.4)
        + u_band.z * 0.6 * sin(theta * 13.0 + t * 3.9)
        + u_band.w * 0.5 * sin(theta * 21.0 - t * 6.2);
    float halo_amp = 0.10 * w_idle
                   + (0.18 + 0.30 * u_rms) * w_listen
                   + (0.35 + 0.85 * u_rms) * w_active;
    vec3 halo_col = mix(col_core, col_active, w_active * 0.6);
    vec3 halo_out = halo_col * halo_falloff * halo_amp * (1.0 + shimmer)
                  * smoothstep(radius - 0.02, radius + 0.02, r); // outside only

    // ---- thinking: orbiting sparks -------------------------------------
    vec3 think_out = vec3(0.0);
    if (w_think > 0.001) {
        for (int i = 0; i < 3; i++) {
            float ang = t * 2.2 + float(i) * 2.09439510; // 2*pi/3
            vec2 sp = vec2(cos(ang), sin(ang)) * radius * 0.55;
            float d = length(p - sp);
            think_out += col_think * exp(-d * d * 900.0) * 1.4;
        }
        think_out *= w_think;
    }

    // ---- press feedback ring (PTT) -------------------------------------
    float ring_r = radius * 1.42;
    float ring = exp(-pow((r - ring_r) * 60.0, 2.0));
    vec3 ring_out = vec3(0.9, 0.95, 1.0) * ring * press * 0.9;

    // ---- compose --------------------------------------------------------
    vec3 bg = vec3(0.026, 0.028, 0.045); // v1: opaque dark; transparency later
    vec3 col = bg + core_out + halo_out + think_out + ring_out;

    // gentle tone-map so stacked layers don't clip harshly
    col = col / (1.0 + col * 0.35);
    frag_color = vec4(col, 1.0);
}
@end

@program orb vs fs
