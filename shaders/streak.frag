#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 resolution;
    vec2 target;
    vec2 tailStart;
    float progress;
    vec3 tint;
};

void main() {
    vec2 p = qt_TexCoord0 * resolution;

    float t = clamp(progress, 0.0, 1.0);

    // tail fully retracts into the caret over the lifetime
    float retract = smoothstep(0.05, 0.95, t);
    vec2 s0 = mix(tailStart, target, retract);
    vec2 pa = p - s0;
    vec2 ba = target - s0;
    float ds = length(pa - ba * clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0));

    float core = 1.0 - smoothstep(0.9, 2.0, ds);
    float glow = exp(-max(ds, 0.0) / 5.0) * 0.4;

    // dim toward the far end; anchored to the original axis so shading stays
    // stable while the segment collapses
    vec2 fa = target - tailStart;
    float hAxial = clamp(dot(p - tailStart, fa) / max(dot(fa, fa), 1e-4), 0.0, 1.0);
    float taper = mix(0.3, 1.0, hAxial);

    float env = smoothstep(0.0, 0.06, t) * (1.0 - smoothstep(0.4, 1.0, t));
    float a = clamp(core + glow, 0.0, 1.0) * env * taper;

    float wx = smoothstep(0.0, 6.0, p.x) * (1.0 - smoothstep(resolution.x - 6.0, resolution.x, p.x));
    float wy = smoothstep(0.0, 6.0, p.y) * (1.0 - smoothstep(resolution.y - 6.0, resolution.y, p.y));
    a *= wx * wy;

    vec3 col = tint * (0.72 + 0.28 * core);
    fragColor = vec4(col * a, a) * qt_Opacity;
}
