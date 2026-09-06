pragma ComponentBehavior: Bound

import QtQuick

/*!
    \qmltype MagnifiedRow
    \brief Layout for a row of equal items that swell toward a pointer.

    The parabolic-zoom layout, as a pure function. Give it a count, a resting
    size, and where the pointer is along the row; get back every item's size
    and offset. It draws nothing and knows nothing about docks, icons or
    Wayland — which is what makes it both reusable and testable without a
    compositor.

    \section2 Rest positions, deliberately

    Distance is measured from each item's RESTING centre, never its current
    magnified one. Using the live position makes a feedback loop: the item
    grows, which moves its centre, which changes its distance from the
    pointer, which changes how much it grows. The result oscillates around the
    cursor and never settles. Rest positions are stable by construction, and
    are what Plank and Latte both arrived at.

    \section2 The kernel

    (1 − t²)² rather than a cosine or a bare parabola, because its derivative
    is zero at BOTH ends. A kernel with slope at the edge of its influence
    puts a visible kink in the row exactly where magnification stops, and that
    kink travels with the pointer — much more noticeable than the slightly
    smaller bulge the smooth kernel gives.
*/
QtObject {
    id: root

    /*! Number of items. */
    property int count: 0

    /*! Size of one item at rest, along the row's axis. */
    property real itemSize: 48

    /*! Gap between items. */
    property real spacing: 8

    /*! Total length available. The row is centred within it. */
    property real axisLength: 0

    /*! Pointer position along the axis, in the SAME coordinates as
        \l axisLength — i.e. surface coordinates, not row-relative ones.

        ⚠️ Mixing the two is the classic bug here and it does not look like a
        coordinate bug: the row still bulges, just centred on a point the
        pointer is nowhere near, which reads as the row ignoring the pointer
        entirely. */
    property real pointer: 0

    /*! How much the item under the pointer grows. 1 disables magnification. */
    property real magnification: 1.9

    /*! Reach of the effect, in resting cells. */
    property real influenceCells: 2.6

    /*! 0 = fully at rest, 1 = fully magnified. Animate this to fade the whole
        effect in and out without touching any other property. */
    property real amount: 1

    /*!
        Per-item width multipliers, or an empty list for a uniform row.

        A divider is not an icon and should not occupy an icon's worth of space
        — a full empty cell either side of a one-pixel line is most of what
        makes a dock look loosely packed. Give it 0.4 and the row closes up
        around it without the magnification arithmetic changing at all: the
        scale curve is still a pure function of the pointer's distance from each
        item's resting centre, and only the widths those centres are derived
        from differ.

        \qml
        widthScale: items.map(i => i.kind === "separator" ? 0.4 : 1)
        \endqml
    */
    property var widthScale: []

    function _wf(i: int): real {
        return (root.widthScale && root.widthScale.length > i) ? root.widthScale[i] : 1;
    }

    readonly property real cell: root.itemSize + root.spacing
    readonly property real restTotal: {
        if (root.count <= 0)
            return 0;
        let t = 0;
        for (let i = 0; i < root.count; ++i)
            t += root.itemSize * root._wf(i) + root.spacing;
        return t - root.spacing;
    }
    readonly property real restStart: (root.axisLength - root.restTotal) / 2

    /*! Resting centre of item \a i, in axis coordinates. */
    function restCentre(i: int): real {
        let run = root.restStart;
        for (let k = 0; k < i; ++k)
            run += root.itemSize * root._wf(k) + root.spacing;
        return run + root.itemSize * root._wf(i) / 2;
    }

    function kernel(t: real): real {
        const u = Math.min(1, Math.abs(t));
        const a = 1 - u * u;
        return a * a;
    }

    /*! Scale factor for item \a i. */
    function scaleAt(i: int): real {
        if (root.count === 0 || root.influenceCells <= 0)
            return 1;
        const d = (root.restCentre(i) - root.pointer) / (root.influenceCells * root.cell);
        return 1 + (root.magnification - 1) * root.amount * root.kernel(d);
    }

    /*!
        `{ sizes, offsets, total, start }` — sizes along the axis and
        leading-edge offsets.

        Computed once per change and read N times, rather than recomputed
        inside each item's binding: the offsets are a running sum, so letting
        every item work out its own turns an O(n) layout into O(n²) evaluated
        on every frame of a hover.

        \section2 The row is ANCHORED AT THE POINTER, not centred

        🔴 IT USED TO BE CENTRED, AND THAT MOVES THE THING YOU ARE POINTING AT
        OUT FROM UNDER YOUR CURSOR. Measured on a live dock: with the pointer
        on the divider's resting centre at 1767, the divider spanned
        1745.2..1788.8 at rest and 1767.5..1850.2 once the row expanded — its
        LEFT EDGE landed on the pointer and the item under the cursor became
        nothing. The panel's left edge moved 815 → 647, exactly half the 335px
        the row had grown, because centring distributes the growth
        symmetrically about the row's middle rather than about the cursor.

        The effect is worst where it is most noticed: the bigger the icons, the
        further the drift, and at a 128px dock the first icon's centre moved 46
        pixels. Aiming becomes a guess, and the reported symptom is "the genie
        effect isn't happening, it just makes icons far apart from each other".

        The fix is a change of frame, not of arithmetic. The sizes are
        untouched; only where the row STARTS changes. Build the offsets from a
        centred start, then find where the pointer's resting position lands in
        the magnified row and slide the whole row so it lands on itself. The
        map is the piecewise-linear one between resting leading edges and
        magnified leading edges, which is monotone by construction, so the
        shift is continuous and there is nothing to oscillate.

        At \c{amount == 0} every scale is 1, the magnified boundaries ARE the
        resting ones, the shift is exactly zero and this reduces to the centred
        layout it replaces — so fading magnification in and out stays smooth
        without a special case.

        \note The caller must position the row's BACKGROUND from \c start, not
        from the centre of the available length. A background that stays
        centred while the row slides puts the icons outside it.
    */
    readonly property var metrics: {
        const sizes = [];
        let total = 0;
        for (let i = 0; i < root.count; i++) {
            const s = root.itemSize * root._wf(i) * root.scaleAt(i);
            sizes.push(s);
            total += s + root.spacing;
        }
        total = Math.max(0, total - root.spacing);

        const offsets = [];
        let run = (root.axisLength - total) / 2;
        for (let i = 0; i < root.count; i++) {
            offsets.push(run);
            run += sizes[i] + root.spacing;
        }

        // Where the pointer's RESTING position lands once everything has
        // grown. Walk both edge lists together; `rest` and `mag` are the
        // leading edges of item i, and the pointer is carried across whichever
        // cell it falls in at the same fraction.
        let shift = 0;
        if (root.count > 0 && root.amount > 0) {
            let rest = root.restStart;
            let mag = offsets[0];
            const p = root.pointer;
            if (p <= rest) {
                // Before the row: no interpolation to do, the whole row moves
                // with its first edge.
                shift = 0;
            } else {
                let placed = false;
                for (let i = 0; i < root.count && !placed; i++) {
                    const rw = root.itemSize * root._wf(i) + root.spacing;
                    const mw = sizes[i] + root.spacing;
                    if (p < rest + rw) {
                        // ⚠️ Guard the degenerate cell. A zero-width resting
                        // cell would divide by zero and put NaN into every
                        // offset, which QML accepts and paints as an empty row.
                        const f = rw > 0.0001 ? (p - rest) / rw : 0;
                        shift = p - (mag + f * mw);
                        placed = true;
                    }
                    rest += rw;
                    mag += mw;
                }
                if (!placed)
                    shift = p - (mag + (p - rest));   // past the end: slope 1
            }
        }

        // Never let the shift push the row off the surface. It cannot in
        // practice — the row is far narrower than the axis it lives on — but a
        // dock resized to its maximum on a narrow output is exactly the case
        // that would find out the hard way.
        let start = offsets[0] + shift;
        start = Math.max(0, Math.min(root.axisLength - total, start));
        shift = start - offsets[0];
        if (shift !== 0)
            for (let i = 0; i < root.count; i++)
                offsets[i] += shift;

        return {
            sizes: sizes,
            offsets: offsets,
            total: total,
            start: root.count > 0 ? offsets[0] : (root.axisLength - total) / 2
        };
    }
}
