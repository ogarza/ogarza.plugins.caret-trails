#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 resolution;
    vec2 center;
    vec2 radii;
    float angle;
    float land;
    vec3 tint;
};

void main() {
    vec2 p = qt_TexCoord0 * resolution;

    // into the particle's frame: translate, un-rotate
    vec2 d = p - center;
    float ca = cos(-angle);
    float sa = sin(-angle);
    vec2 q = vec2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);

    // exact capsule distance in true pixel space
    float grow = 1.0 + land * 0.35;
    float halfLen = max(radii.x - radii.y, 0.0);
    float dd = length(q - vec2(clamp(q.x, -halfLen, halfLen), 0.0)) - radii.y;
    dd /= grow;

    float core = 1.0 - smoothstep(0.0, 1.4, dd);
    float glow = exp(-max(dd, 0.0) / 4.5) * 0.55;

    float a = clamp(core + glow, 0.0, 1.2);

    // force a clean zero at the quad borders
    float wx = smoothstep(0.0, 6.0, p.x) * (1.0 - smoothstep(resolution.x - 6.0, resolution.x, p.x));
    float wy = smoothstep(0.0, 6.0, p.y) * (1.0 - smoothstep(resolution.y - 6.0, resolution.y, p.y));
    a *= wx * wy;

    vec3 col = tint * (0.72 + 0.28 * core);
    fragColor = vec4(col * a, a) * qt_Opacity;
}
