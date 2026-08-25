#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 resolution;
    vec2 p0;
    vec2 p1;
    float progress;
    vec3 tint;
};

float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

void main() {
    vec2 p = qt_TexCoord0 * resolution;

    float d = sdSegment(p, p0, p1);

    float core = 1.0 - smoothstep(1.5, 3.0, d);
    float glow = exp(-d / 9.0) * 0.45;

    float t = clamp(progress, 0.0, 1.0);
    float ease = 1.0 - pow(1.0 - t, 3.0);
    vec2 head = mix(p0, p1, ease);
    float pulse = exp(-length(p - head) / 16.0);

    float fade = smoothstep(0.0, 0.05, t) * (1.0 - smoothstep(0.55, 1.0, t));

    float a = clamp(core + glow + pulse * 0.9 * (1.0 - t), 0.0, 1.0) * fade;

    vec3 col = tint * (0.7 + 0.3 * core);
    fragColor = vec4(col * a, a) * qt_Opacity;
}
