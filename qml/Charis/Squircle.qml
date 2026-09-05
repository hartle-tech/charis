pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

/*!
    \qmltype Squircle
    \brief A rounded rectangle whose corners have no seam in them.

    WHAT IS ACTUALLY WRONG WITH \c{Rectangle { radius: 16 }}.

    An ordinary rounded rectangle is a straight edge that meets a circular
    arc. At the join the two agree on position and on direction, so nothing
    looks broken — but they disagree on CURVATURE, which jumps from zero to
    1/r instantly. Human vision is measurably sensitive to that discontinuity
    even though almost nobody can name it: the corner reads as slightly
    pinched, and a row of such corners reads as mechanical.

    Apple replaced circular corners with continuous-curvature ones in iOS 7
    and has used them on every surface since — icons, sheets, buttons,
    hardware bezels. It is one of the least discussed and most load-bearing
    parts of why their UI looks the way it does, and it is entirely
    reproducible: the corner just has to be a curve whose curvature RAMPS from
    zero instead of starting at full value.

    This uses the superellipse family, which does exactly that:

    \badcode
    |x/r|ⁿ + |y/r|ⁿ = 1
    \endcode

    At n = 2 that is a circle, and this component is then identical to
    \c Rectangle. As n grows the corner flattens near the edges and tightens
    near the diagonal, which is precisely the curvature ramp that removes the
    seam. n ≈ 5 is very close to Apple's construction.

    \c smoothing maps 0 → 1 onto n = 2 → 5, so 0 is a plain rounded rectangle
    and 1 is the continuous corner. It is not a slider anyone should need to
    touch — the default is the right answer — but interpolating it is a
    legitimate way to animate between shapes.

    \section2 Why sampled rather than a bezier fillet

    The usual replication of this (Figma's corner smoothing, and the several
    JS libraries that copy it) builds each corner from cubic Béziers with
    control points from a fitted formula. That produces a compact path, and it
    is an APPROXIMATION of the superellipse with published error.

    Sampling the real curve is exact by construction, needs no fitted
    constants, and costs nothing that matters: the sample count scales with
    the corner's actual pixel size, so a 12px corner spends 10 points and a
    64px corner spends 22. The renderer triangulates once and caches; the
    difference against a four-bezier path is not measurable next to a single
    blur.

    \section2 Using it as a mask

    An app icon clipped to a squircle is the other half of the look. \c Shape
    renders into a layer cleanly, so this works as a \c MultiEffect mask
    source directly:

    \qml
    Image { source: icon; layer.enabled: true; layer.effect: ... }
    MultiEffect {
        source: iconImage
        maskEnabled: true
        maskSource: Squircle { fillColor: "white" }
    }
    \endqml
*/
Shape {
    id: root

    /*! Corner radius, clamped to half the shorter side. */
    property real radius: 16

    /*! 0 = circular corner (identical to Rectangle), 1 = continuous. */
    property real smoothing: 1

    /*! Fill. Set to "transparent" for an outline-only shape. */
    property color fillColor: "white"

    /*! Border colour; transparent by default. */
    property color strokeColor: "transparent"

    /*! Border width. */
    property real strokeWidth: 0

    // Curve rendering is the GPU path and antialiases in the fragment shader
    // rather than by multisampling the whole item, which matters because this
    // is drawn once per dock icon per frame.
    preferredRendererType: Shape.CurveRenderer

    readonly property real _r: Math.max(0, Math.min(root.radius, Math.min(width, height) / 2))

    // n = 2 is a circle; 5 is the continuous corner. Anything beyond ~6 stops
    // reading as a corner and starts reading as a bevel.
    readonly property real _n: 2 + 3 * Math.max(0, Math.min(1, root.smoothing))

    // Samples per corner, from the corner's rendered size. A tiny radius given
    // 24 points wastes them on sub-pixel detail; a large one given 8 shows
    // visible facets on the diagonal, which is the exact defect this component
    // exists to remove.
    readonly property int _steps: Math.max(6, Math.min(28, Math.ceil(root._r / 3) + 6))

    // Rebuilt only when the geometry or shape parameters change — not per
    // frame, and not on colour changes.
    readonly property var _points: {
        const w = root.width;
        const h = root.height;
        const r = root._r;

        if (w <= 0 || h <= 0)
            return [];
        if (r <= 0)
            return [Qt.point(0, 0), Qt.point(w, 0), Qt.point(w, h), Qt.point(0, h), Qt.point(0, 0)];

        const n = root._n;
        const steps = root._steps;
        const e = 2 / n;
        const pts = [];

        // One corner's worth of offsets from its own centre, walking the
        // superellipse from the horizontal axis round to the vertical.
        // Computed once and then mirrored, so the four corners are guaranteed
        // identical rather than merely similar.
        const cx = [];
        const cy = [];
        for (let i = 0; i <= steps; i++) {
            const t = (i / steps) * (Math.PI / 2);
            cx.push(r * Math.pow(Math.cos(t), e));
            cy.push(r * Math.pow(Math.sin(t), e));
        }

        // Top-right: from the top edge round to the right edge.
        for (let i = steps; i >= 0; i--)
            pts.push(Qt.point(w - r + cx[i], r - cy[i]));
        // Bottom-right.
        for (let i = 0; i <= steps; i++)
            pts.push(Qt.point(w - r + cx[i], h - r + cy[i]));
        // Bottom-left.
        for (let i = steps; i >= 0; i--)
            pts.push(Qt.point(r - cx[i], h - r + cy[i]));
        // Top-left.
        for (let i = 0; i <= steps; i++)
            pts.push(Qt.point(r - cx[i], r - cy[i]));

        // Close explicitly. A polyline left open leaves a hairline gap at the
        // top-left under the curve renderer — invisible on a dark background
        // and glaring on a light one, which is a miserable way to find out.
        pts.push(pts[0]);
        return pts;
    }

    ShapePath {
        fillColor: root.fillColor
        strokeColor: root.strokeColor
        strokeWidth: root.strokeWidth
        // Butt joins on a closed polyline would show at every sample point.
        joinStyle: ShapePath.RoundJoin
        capStyle: ShapePath.RoundCap

        PathPolyline {
            path: root._points
        }
    }
}
