// hp-snap: a liquid-glass lens (IrisLiquidLens.qml). The wallpaper under the lens shows through clear in the
// middle and bends toward the rim, where the glass is thickest, with a little dispersion; a specular rim
// catches the light from the top left and, more faintly, from the bottom right.
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;       // item pixels
    vec4 sceneRect;      // where the item is on the screen (x, y, width, height), screen pixels
    vec2 sceneSize;      // the screen
    float radius;        // corner radius, item pixels
    float bezel;         // how far in from the rim the glass bends, item pixels
    float refraction;    // how strongly it bends, 0..
    float pixelRatio;
    float presence;      // 0..1, fades the whole lens
    float highlight;     // rim brightness, 0..
    vec4 tint;           // a wash over the glass (rgb, amount)
    vec4 crop;           // the part of the backdrop texture the screen shows (x, y, width, height in 0..1)
};

layout(binding = 1) uniform sampler2D backdrop;

float box(vec2 p, vec2 half_, float r) {
    r = min(r, min(half_.x, half_.y));
    vec2 q = abs(p) - half_ + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 half_ = itemSize * 0.5;
    vec2 p = qt_TexCoord0 * itemSize - half_;
    float d = box(p, half_, radius);
    float aa = 0.5 / max(pixelRatio, 1.0);
    float cover = clamp(0.5 - d / (2.0 * aa), 0.0, 1.0);
    if (cover <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }
    vec2 n = vec2(box(p + vec2(0.5, 0.0), half_, radius) - box(p - vec2(0.5, 0.0), half_, radius),
                  box(p + vec2(0.0, 0.5), half_, radius) - box(p - vec2(0.0, 0.5), half_, radius));
    n = n / max(length(n), 1e-4);

    // 0 at the rim, 1 once past the bezel: the bend grows toward the rim like the edge of a thick lens.
    float depth = clamp(-d / max(bezel, 1.0), 0.0, 1.0);
    // Toward the rim the glass curves away, so it shows what lies just past its edge, pulled in around the rim.
    float bend = pow(1.0 - depth, 2.5) * refraction * bezel;
    vec2 scale = sceneRect.zw / itemSize;
    vec2 here = sceneRect.xy + (p + half_) * scale;
    vec2 off = n * bend * scale;
    // A backdrop not uploaded yet samples empty (alpha 0): draw nothing there rather than black.
    float filled = texture(backdrop, crop.xy + here / sceneSize * crop.zw).a;
    if (filled <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }
    vec3 col = vec3(texture(backdrop, crop.xy + (here + off * 1.07) / sceneSize * crop.zw).r,
                    texture(backdrop, crop.xy + (here + off) / sceneSize * crop.zw).g,
                    texture(backdrop, crop.xy + (here + off * 0.93) / sceneSize * crop.zw).b);
    col = mix(col, tint.rgb, tint.a);

    // Light on the rim: a bright line where the glass faces the light, a fainter one opposite.
    float rim = 1.0 - smoothstep(0.0, 2.5, -d);
    float key = pow(max(dot(n, normalize(vec2(-0.55, -0.83))), 0.0), 1.4);
    float fill = pow(max(dot(n, normalize(vec2(0.55, 0.83))), 0.0), 2.0) * 0.45;
    float inner = (1.0 - smoothstep(0.0, bezel * 0.6, -d)) * 0.06;
    col += (rim * (key + fill) * 0.5 + inner) * highlight;

    float a = cover * presence * qt_Opacity * filled;
    fragColor = vec4(col * a, a);
}
