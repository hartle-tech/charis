// Charis — refraction glass.
//
// WHAT MAKES THIS GLASS RATHER THAN FROSTING. Every "glass" panel on Linux is a
// blur: sample the backdrop, average it, tint it. That is frosted plastic. Real
// glass has THICKNESS, and a thick edge bends what you see through it — which
// is why an Apple sheet reads as a physical object sitting above the content
// rather than a translucent hole cut into it.
//
// So this displaces the backdrop sample by the surface NORMAL, derived from the
// signed distance field of the panel's own shape, scaled so the bend is
// strongest at the rim and zero in the middle. That is what a lens does, and it
// is the entire difference.
//
// The SDF uses the same superellipse exponent as Squircle, so the refraction
// follows a continuous-curvature edge rather than a circular one — the bend has
// no seam in it either.

#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// ⚠️ Qt matches these to QML properties BY NAME, and qt_Matrix/qt_Opacity must
// come first in the block. A mismatched name is not an error — the uniform
// silently stays zero, which for `refraction` means a panel that looks like an
// ordinary blur and gives no clue why.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 srcSize;
    float radius;
    float expo;
    float thickness;
    float refraction;
    float rim;
    float tintAmount;
    vec4 tint;
};

layout(binding = 1) uniform sampler2D src;

// Signed distance to a superellipse-cornered box. Negative inside.
//
// The usual rounded-box SDF uses length() on the corner offset, which is a
// circle. Swapping in the n-norm gives the same continuous-curvature corner
// Squircle draws, so the glass edge and the shape agree.
float sdShape(vec2 p, vec2 b, float r, float n) {
    vec2 q = abs(p) - b + r;
    vec2 m = max(q, vec2(0.0));
    float outside = pow(pow(m.x, n) + pow(m.y, n), 1.0 / n);
    return outside + min(max(q.x, q.y), 0.0) - r;
}

// Surface normal by central difference. Analytic gradients of an n-norm are
// unpleasant and this is four extra evaluations of a cheap function; the
// visible difference is nil.
vec2 shapeNormal(vec2 p, vec2 b, float r, float n) {
    const float e = 1.0;
    vec2 g = vec2(sdShape(p + vec2(e, 0.0), b, r, n) - sdShape(p - vec2(e, 0.0), b, r, n), sdShape(p + vec2(0.0, e), b, r, n) - sdShape(p - vec2(0.0, e), b, r, n));
    float len = length(g);
    // Dead centre of a symmetric shape the gradient really is zero, and
    // normalising it yields NaN — which propagates into the UV and paints the
    // whole panel with whatever texel address NaN clamps to.
    return len > 1e-5 ? g / len : vec2(0.0);
}

void main() {
    vec2 px = qt_TexCoord0 * srcSize;
    vec2 half_ = srcSize * 0.5;
    vec2 p = px - half_;

    float d = sdShape(p, half_, radius, expo);

    // Outside the panel entirely.
    if (d > 0.5) {
        fragColor = vec4(0.0);
        return;
    }

    // 0 at the rim, 1 once we are `thickness` pixels inside.
    float t = clamp(-d / max(thickness, 0.001), 0.0, 1.0);

    // Quadratic falloff: the bend is concentrated in the last few pixels, the
    // way it is in a real bevelled edge. A linear ramp spreads the distortion
    // across the whole panel and reads as a smeared image rather than an edge.
    float bend = (1.0 - t) * (1.0 - t);

    vec2 nrm = shapeNormal(p, half_, radius, expo);
    vec2 uv = qt_TexCoord0 + nrm * bend * (refraction / srcSize);

    // Clamped, because sampling past the edge of a ShaderEffectSource repeats
    // or wraps depending on the backend, and either one puts a bright seam
    // exactly where the refraction is strongest.
    vec4 col = texture(src, clamp(uv, vec2(0.0005), vec2(0.9995)));

    col.rgb = mix(col.rgb, tint.rgb, tintAmount);

    // Specular rim — the bright line along the top edge of a real glass slab.
    // Cheap, and it is most of what sells the material at a glance.
    col.rgb += pow(1.0 - t, 6.0) * rim;

    // Antialias the silhouette across one pixel of the distance field.
    float aa = clamp(0.5 - d, 0.0, 1.0);

    fragColor = vec4(col.rgb, 1.0) * aa * qt_Opacity;
}
