// MSDF text shader — compiled by sokol-shdc → sdf_text.glsl.zig
#pragma sokol @vs vs
layout(binding=0) uniform vs_params {
    vec2 u_screen; // viewport width/height in pixels
    vec2 _pad0;
};

in vec2 position;
in vec2 texcoord0;
in vec4 color0;

out vec2 uv;
out vec4 color;

void main() {
    // Top-left origin pixel coords → NDC
    vec2 ndc = vec2(
        position.x / u_screen.x * 2.0 - 1.0,
        1.0 - position.y / u_screen.y * 2.0
    );
    gl_Position = vec4(ndc, 0.0, 1.0);
    uv = texcoord0;
    color = color0;
}
#pragma sokol @end

#pragma sokol @fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
layout(binding=1) uniform fs_params {
    // x = screen pixel range (px_range * scale), yzw unused
    vec4 u_sdf;
};

in vec2 uv;
in vec4 color;

out vec4 frag_color;

float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

void main() {
    vec3 msdf = texture(sampler2D(tex, smp), uv).rgb;
    float sd = median(msdf.r, msdf.g, msdf.b);
    float screen_px_range = max(u_sdf.x, 1.0);
    float screen_px_distance = screen_px_range * (sd - 0.5);
    float alpha = clamp(screen_px_distance + 0.5, 0.0, 1.0);
    frag_color = vec4(color.rgb, color.a * alpha);
}
#pragma sokol @end

#pragma sokol @program sdf_text vs fs
