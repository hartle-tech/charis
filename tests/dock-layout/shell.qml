// Charis — MagnifiedRow conformance test.
//
// The dock's magnification is the component's whole reason for existing, and
// it is exactly the kind of thing that "looks fine" while being wrong: a row
// that bulges around the wrong point, or overlaps by a pixel, or has a kink in
// it, still reads as a working dock in a screenshot. So the properties are
// asserted numerically rather than eyeballed.
//
// One check here — pointer/centres-on-the-right-item — is a regression test for
// a bug that shipped into a screenshot before being caught: the pointer arrives
// in surface coordinates while the row's rest positions were measured from
// zero, so the magnification centred on the left edge of the monitor. The dock
// still bulged. It just ignored the cursor.

import QtQuick
import Quickshell
import Charis

ShellRoot {
    id: root

    property int failures: 0
    property int checks: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks += 1;
        if (!ok)
            root.failures += 1;
        console.log((ok ? "PASS  " : "FAIL  ") + name + "   " + detail);
    }

    // A realistic configuration: seven icons on an ultrawide.
    property MagnifiedRow rowUnderTest: MagnifiedRow {
        id: row
        count: 7
        itemSize: 52
        spacing: 8
        axisLength: 2752
        magnification: 1.9
        influenceCells: 2.6
        amount: 1
    }

    Component.onCompleted: {
        // ── 1. At rest, nothing is magnified ────────────────────────────
        row.amount = 0;
        let allBase = true;
        for (const s of row.metrics.sizes)
            if (Math.abs(s - row.itemSize) > 1e-9)
                allBase = false;
        root.check("rest/all-items-base-size", allBase, "sizes=" + row.metrics.sizes.map(v => v.toFixed(1)).join(","));

        const restTotal = 7 * 60 - 8;
        root.check("rest/total", Math.abs(row.metrics.total - restTotal) < 1e-9, "total=" + row.metrics.total + " expected=" + restTotal);

        // The row is centred in the axis, so the first offset must leave half
        // the slack on the left.
        root.check("rest/centred", Math.abs(row.metrics.offsets[0] - (row.axisLength - restTotal) / 2) < 1e-9, "offset0=" + row.metrics.offsets[0].toFixed(2));

        // ── 2. THE REGRESSION: pointer centres on the right item ────────
        // The surface is 2752 wide and the row is centred, so the middle of
        // the screen is the middle of the row: item 3 of 0..6. With the bug,
        // rest centres were measured from 0, item 3's "centre" was 210, the
        // pointer at 1376 was ~19 cells away, and the row magnified around
        // its left end instead.
        row.amount = 1;
        row.pointer = row.axisLength / 2;
        let peak = 0, peakIdx = -1;
        for (let i = 0; i < row.count; i++) {
            const s = row.scaleAt(i);
            if (s > peak) {
                peak = s;
                peakIdx = i;
            }
        }
        root.check("pointer/centres-on-the-right-item", peakIdx === 3, "peak at index " + peakIdx + " (expected 3), scale=" + peak.toFixed(4));

        // Dead centre on an item means FULL magnification, not merely the most.
        root.check("pointer/exact-hit-is-full-magnification", Math.abs(peak - row.magnification) < 1e-6, "scale=" + peak.toFixed(6) + " magnification=" + row.magnification);

        // ── 3. Falloff is monotonic in both directions ──────────────────
        let mono = true;
        for (let i = peakIdx; i < row.count - 1; i++)
            if (row.scaleAt(i + 1) > row.scaleAt(i) + 1e-9)
                mono = false;
        for (let i = peakIdx; i > 0; i--)
            if (row.scaleAt(i - 1) > row.scaleAt(i) + 1e-9)
                mono = false;
        root.check("falloff/monotonic", mono, "scales=" + [0, 1, 2, 3, 4, 5, 6].map(i => row.scaleAt(i).toFixed(3)).join(","));

        // ── 4. Symmetric about the pointer ──────────────────────────────
        // A row of 7 with the pointer on the middle one must mirror exactly.
        // Asymmetry here means the rest-centre arithmetic is off by half a
        // cell, which looks like the row "leaning" toward one side.
        let sym = true;
        for (let k = 1; k <= 3; k++)
            if (Math.abs(row.scaleAt(3 - k) - row.scaleAt(3 + k)) > 1e-9)
                sym = false;
        root.check("falloff/symmetric", sym, "left=" + row.scaleAt(2).toFixed(4) + " right=" + row.scaleAt(4).toFixed(4));

        // ── 5. No overlaps and no gaps ──────────────────────────────────
        // Every neighbouring pair must be exactly `spacing` apart. Any drift
        // here is icons visibly crowding or drifting apart as the row swells,
        // which is one of the most obvious tells of a home-made dock.
        let packed = true;
        let worstGap = 0;
        const m = row.metrics;
        for (let i = 0; i < row.count - 1; i++) {
            const gap = m.offsets[i + 1] - (m.offsets[i] + m.sizes[i]);
            worstGap = Math.max(worstGap, Math.abs(gap - row.spacing));
            if (Math.abs(gap - row.spacing) > 1e-9)
                packed = false;
        }
        root.check("layout/packed-exactly", packed, "worst deviation=" + worstGap.toExponential(2));

        // ── 6. The row grows, and stays centred while it does ───────────
        root.check("layout/grows-when-magnified", m.total > restTotal, "magnified=" + m.total.toFixed(1) + " rest=" + restTotal);

        const centreOfRow = m.offsets[0] + m.total / 2;
        root.check("layout/stays-centred", Math.abs(centreOfRow - row.axisLength / 2) < 1e-6, "row centre=" + centreOfRow.toFixed(3) + " axis centre=" + (row.axisLength / 2).toFixed(3));

        // ── 7. The kernel lands softly ──────────────────────────────────
        // (1−t²)² must reach zero with zero slope at the influence edge. A
        // kernel with slope there puts a travelling kink in the row.
        const eps = 1e-4;
        const slopeAtEdge = Math.abs(row.kernel(1) - row.kernel(1 - eps)) / eps;
        root.check("kernel/zero-at-edge", Math.abs(row.kernel(1)) < 1e-12, "k(1)=" + row.kernel(1).toExponential(2));
        root.check("kernel/flat-at-edge", slopeAtEdge < 1e-3, "|k'(1)|=" + slopeAtEdge.toExponential(2));
        root.check("kernel/unity-at-centre", Math.abs(row.kernel(0) - 1) < 1e-12, "k(0)=" + row.kernel(0));

        // ── 8. Beyond the influence radius, nothing moves ───────────────
        // Otherwise a 40-icon dock relayouts every icon on every frame of a
        // hover, for motion invisible at the far end.
        row.pointer = row.restCentre(0);
        const far = row.scaleAt(6);
        root.check("influence/bounded", Math.abs(far - 1) < 1e-9, "far item scale=" + far.toFixed(9));

        // ── 9. amount fades the whole effect, not just its speed ────────
        row.pointer = row.axisLength / 2;
        row.amount = 0.5;
        const half = row.scaleAt(3);
        root.check("amount/interpolates", Math.abs(half - (1 + (row.magnification - 1) * 0.5)) < 1e-9, "scale@0.5=" + half.toFixed(6));

        console.log("");
        console.log("SUMMARY " + (root.checks - root.failures) + "/" + root.checks + " passed");
        Qt.exit(root.failures > 0 ? 1 : 0);
    }
}
