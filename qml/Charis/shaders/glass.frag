// Charis — the Liquid Glass material, done with optics rather than tricks.
//
// WHAT APPLE'S MATERIAL IS, from their own description (WWDC25, "Meet Liquid
// Glass") and from what the people who have pulled it apart agree on: a stack
// of five optical ingredients, not one.
//
//   1. TRANSLUCENCY AND BLUR across the face.
//   2. REFRACTION. The panel is a LENS: it displaces the backdrop rather than
//      averaging it. Snell's law, air into glass, index around 1.5.
//   3. CHROMATIC ABERRATION, at the edge only. Short wavelengths bend harder,
//      so the channels do not land together and the rim carries a colour
//      fringe. This is the single most recognisable feature of the material.
//   4. SPECULAR LIGHT, in two parts: a DIRECTIONAL highlight from a light up
//      and to the left, and a FRESNEL edge that brightens steeply at grazing
//      angles — which is why the silhouette of an Apple panel glows while its
//      face does not.
//   5. A TINT, and enough of a floor under it that the sheet never disappears
//      into dark content.
//
// EVERY ONE OF THOSE WAS EITHER MISSING OR FAKED IN THE VERSION BEFORE THIS,
// and each absence was a defect the operator named before the code did.
//
// 🔴 "There's a weird board around it." The specular was `pow(1-t, 6) * rim`:
//    the same brightness all the way round, which is an OUTLINE, and an
//    outline is a board. Light comes from a direction. Fixed by computing a
//    real 3D surface normal and lighting it.
//
// 🔴 The body was a near-black slab over dark content, because the tint was a
//    flat lerp toward a dark colour and had nothing to work with when the
//    backdrop was already dark. Apple's dark glass LIFTS what is behind it.
//
// 🔴 The refraction was INVISIBLE, measured on the bench 2026-09-17 23:55.
//    Displacing a sample of an already-blurred image moves nothing the eye can
//    see. A real glass sheet is cloudy in the middle and SHARP at its
//    ground-off edge, where it shows a compressed image of what lies just
//    beyond. Hence two sources, and a crossfade to the sharp one in the bevel.
//
// 🔴 And the displacement itself was an invented quadratic falloff along a 2D
//    normal. It is now a HEIGHT FIELD: the panel has a convex squircle bevel,
//    the 3D normal comes from its slope, and the offset is where a ray from
//    the eye actually lands after refracting through it. That is what makes
//    the distortion look like glass instead of like a smear, and it is what
//    "algorithmically accurate" has to mean.

#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// ⚠️ Qt matches these to QML properties BY NAME, and qt_Matrix/qt_Opacity must
// come first in the block. A mismatched name is not an error — the uniform
// silently stays zero, which for `refraction` means a panel that looks like an
// ordinary blur and gives no clue why.
//
// ⚠️ The order here is also the std140 layout: a vec2 needs 8-byte alignment
// and a vec4 needs 16, so the scalars are arranged to land the vectors on
// their boundaries rather than in whatever order reads nicely. `qsb -d` prints
// the offsets it actually chose; check them after any edit here.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;     //   0
    float qt_Opacity;   //  64
    float radius;       //  68
    vec2 srcSize;       //  72
    vec2 lightDir;      //  80
    float expo;         //  88
    float thickness;    //  92
    float refraction;   //  96
    float dispersion;   // 100
    float rim;          // 104
    float rimWidth;     // 108
    float sheen;        // 112
    float tintAmount;   // 116
    float lift;         // 120
    float saturation;   // 124
    float clarity;      // 128
    float ior;          // 132
    float fresnel;      // 136
    float bevel;        // 140
    vec4 tint;          // 144
};

// The blurred body, and the sharp edge. A caller with only one image passes
// the same texture twice and `clarity` stops mattering.
layout(binding = 1) uniform sampler2D src;
layout(binding = 2) uniform sampler2D srcSharp;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
const vec3 VIEW = vec3(0.0, 0.0, 1.0);

// Signed distance to a superellipse-cornered box. Negative inside.
//
// The usual rounded-box SDF uses length() on the corner offset, which is a
// circle. Swapping in the n-norm gives the same continuous-curvature corner
// Squircle draws, so the glass edge and the shape agree — and Apple's corners
// are continuous, which is why a circular one looks subtly wrong beside them.
float sdShape(vec2 p, vec2 b, float r, float n) {
    vec2 q = abs(p) - b + r;
    vec2 m = max(q, vec2(0.0));
    float outside = pow(pow(m.x, n) + pow(m.y, n), 1.0 / n);
    return outside + min(max(q.x, q.y), 0.0) - r;
}

// Gradient of the distance field, pointing OUTWARD (an SDF grows away from its
// shape), by central difference. Analytic gradients of an n-norm are
// unpleasant and this is four extra evaluations of a cheap function.
vec2 shapeGradient(vec2 p, vec2 b, float r, float n) {
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

    // ── The bevel as a HEIGHT FIELD ──────────────────────────────────────
    //
    // `e` runs 0 at the silhouette to 1 at the inner edge of the bevel, and
    // the glass surface rises across it on a convex squircle — flat in the
    // middle, turning over hard at the very edge, which is the shape a piece
    // of glass with a rolled edge actually has.
    //
    //   h(e)     = (1 - (1-e)^4)^(1/4)
    //   dh/de    = (1-e)^3 * (1 - (1-e)^4)^(-3/4)
    //
    // The slope goes to infinity at e = 0. That is correct — the edge really
    // is vertical there — but it has to be clamped or the normal turns over
    // and the last pixel samples from nowhere.
    float e = clamp(-d / max(thickness, 0.001), 0.0, 1.0);
    float k = 1.0 - e;
    float u = max(1.0 - k * k * k * k, 1e-4);
    float dhde = min(k * k * k * pow(u, -0.75), 8.0);

    vec2 g2 = shapeGradient(p, half_, radius, expo);

    // The surface falls away toward the rim, so the normal tilts OUTWARD.
    // `bevel` is the tangent scale: how steep the rolled edge is.
    vec3 N = normalize(vec3(g2 * dhde * bevel, 1.0));

    // ── Refraction, by Snell's law, per channel ──────────────────────────
    //
    // Entering a denser medium (eta < 1) cannot total-internally-reflect, so
    // refract() never returns zero here and needs no guard. Red has the lowest
    // index and bends least; blue the highest and bends most. That ordering is
    // the physics, and it is why the fringe reads as glass rather than as a
    // chromatic filter bolted on afterwards.
    float spread = dispersion * 0.06;
    vec3 Rr = refract(-VIEW, N, 1.0 / max(ior - spread, 1.01));
    vec3 Rg = refract(-VIEW, N, 1.0 / max(ior, 1.01));
    vec3 Rb = refract(-VIEW, N, 1.0 / max(ior + spread, 1.01));

    // Where the ray lands on the backdrop, having crossed `refraction` pixels
    // of glass. Divided by the depth component, which is how far a ray at that
    // angle travels sideways per unit of depth.
    vec2 uvR = qt_TexCoord0 + (Rr.xy / max(abs(Rr.z), 1e-3)) * (refraction / srcSize);
    vec2 uvG = qt_TexCoord0 + (Rg.xy / max(abs(Rg.z), 1e-3)) * (refraction / srcSize);
    vec2 uvB = qt_TexCoord0 + (Rb.xy / max(abs(Rb.z), 1e-3)) * (refraction / srcSize);

    // Clamped, because sampling past the edge of a ShaderEffectSource repeats
    // or wraps depending on the backend, and either one puts a bright seam
    // exactly where the refraction is strongest.
    vec2 lo = vec2(0.0005);
    vec2 hi = vec2(0.9995);

    // The body: the blurred image, carried by the same lens so the whole face
    // moves as one piece of glass rather than as a blurred rectangle with a
    // distorted trim.
    vec3 body = texture(src, clamp(uvG, lo, hi)).rgb;

    // The edge: the SHARP image, one tap per channel.
    vec3 edgeCol = vec3(texture(srcSharp, clamp(uvR, lo, hi)).r, texture(srcSharp, clamp(uvG, lo, hi)).g, texture(srcSharp, clamp(uvB, lo, hi)).b);

    // Sharp only inside the bevel, and squared so the crossover is quick — a
    // slow fade between the two reads as a smear rather than as an edge.
    float bevelMix = k * k;
    vec3 col = mix(body, edgeCol, clamp(clarity, 0.0, 1.0) * bevelMix);

    // ── Vibrancy ─────────────────────────────────────────────────────────
    // Apple's material is MORE saturated than its backdrop, not less. Colour
    // is what keeps glass from reading as grey plastic.
    col = mix(vec3(dot(col, LUMA)), col, saturation);

    // ── The veil, then the floor ─────────────────────────────────────────
    col = mix(col, tint.rgb, tintAmount);
    col += max(0.0, lift - dot(col, LUMA));

    // ── Specular, in two parts ───────────────────────────────────────────
    //
    // The light sits up and to the left and slightly in front, which is where
    // every Apple material puts it. Blinn-Phong for the directional highlight,
    // Schlick for the Fresnel edge. The Fresnel term is what makes the
    // SILHOUETTE glow while the face stays quiet, and it needs no falloff
    // function of its own: the normal is only steep near the rim, so the term
    // is only large near the rim. That is the difference between a highlight
    // and a drawn border.
    vec3 L = normalize(vec3(normalize(lightDir + vec2(1e-6)) * 0.85, 0.52));
    vec3 H = normalize(L + VIEW);
    float spec = pow(max(dot(N, H), 0.0), max(rimWidth, 1.0));
    float fres = 0.04 + 0.96 * pow(1.0 - max(dot(N, VIEW), 0.0), 5.0);

    col += spec * rim;
    col += fres * fresnel;

    // ── Sheen ────────────────────────────────────────────────────────────
    //
    // A broad, very soft gradient across the face, brightest on the lit side.
    // Real glass is never flat across its front. Guarded at the centre, where
    // normalising a zero-length vector produced a visible dark singularity in
    // the middle of every panel (seen on the bench with sheen pushed to 0.5).
    float plen = length(p);
    if (plen > 1.0) {
        float along = dot(p / plen, normalize(lightDir + vec2(1e-6)));
        col += sheen * (along * 0.5 + 0.5) * e;
    } else {
        col += sheen * 0.5 * e;
    }

    // Antialias the silhouette across one pixel of the distance field.
    float aa = clamp(0.5 - d, 0.0, 1.0);

    fragColor = vec4(col, 1.0) * aa * qt_Opacity;
}
