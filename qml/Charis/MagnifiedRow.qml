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

    readonly property real cell: root.itemSize + root.spacing
    readonly property real restTotal: root.count > 0 ? root.count * root.cell - root.spacing : 0
    readonly property real restStart: (root.axisLength - root.restTotal) / 2

    /*! Resting centre of item \a i, in axis coordinates. */
    function restCentre(i: int): real {
        return root.restStart + i * root.cell + root.itemSize / 2;
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
        `{ sizes: [...], offsets: [...], total }` — sizes along the axis and
        leading-edge offsets, with the whole row centred in \l axisLength.

        Computed once per change and read N times, rather than recomputed
        inside each item's binding: the offsets are a running sum, so letting
        every item work out its own turns an O(n) layout into O(n²) evaluated
        on every frame of a hover.
    */
    readonly property var metrics: {
        const sizes = [];
        let total = 0;
        for (let i = 0; i < root.count; i++) {
            const s = root.itemSize * root.scaleAt(i);
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
        return {
            sizes: sizes,
            offsets: offsets,
            total: total
        };
    }
}
