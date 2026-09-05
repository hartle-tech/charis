import QtQuick

/*!
    The way a CRT television switches off: the picture collapses to a bright
    horizontal line, the line contracts to a point, the point fades.

    \section2 Why a component and not three Behaviors

    The effect is three overlapping phases with different curves — a vertical
    collapse that accelerates, a horizontal one that follows it, and a
    brightness bloom that peaks in between — and none of them is a property
    transition. Written as `Behavior`s they interfere: any change to the target
    mid-animation restarts a curve that is supposed to be one continuous
    physical event.

    Driving one normalised \c progress and deriving all three from it keeps them
    in phase by construction, which is the same argument the dock's
    magnification makes for a single cursor spring.

    \section2 What it is for

    A gesture that has been REFUSED. The dock uses it when an icon is dragged
    out and released too close to home: the icon is not being deleted, it is
    being told "not far enough", and it needs to leave the pointer and come
    back. A fade would read as a bug; a snap-back reads as a failed drag. A CRT
    switching off reads as a deliberate answer.

    \qml
    CrtOff {
        id: crt
        onFinished: item.visible = false
    }
    Item {
        transform: [
            Scale { origin.x: w/2; origin.y: h/2; xScale: crt.xScale; yScale: crt.yScale }
        ]
        opacity: crt.opacity
    }
    \endqml
*/
QtObject {
    id: root

    /*! Seconds for the whole collapse. Shorter than it sounds right to make it:
        the effect is a full-screen memory scaled down to a 52px icon, and at
        anything over a third of a second it reads as sluggish rather than as
        snappy hardware. */
    property real duration: 0.34

    /*! Fraction of the run spent collapsing vertically. The horizontal squeeze
        takes the rest. */
    property real verticalShare: 0.58

    readonly property bool running: root._t >= 0
    property real _t: -1

    /*! 0 at rest, 1 when the collapse has finished. */
    readonly property real progress: root._t < 0 ? 0 : Math.min(1, root._t / Math.max(0.001, root.duration))

    readonly property real _p1: Math.min(1, root.progress / root.verticalShare)
    readonly property real _p2: Math.max(0, (root.progress - root.verticalShare) / (1 - root.verticalShare))

    /*! Vertical scale: 1 → a hairline. Eased so it accelerates into the
        collapse rather than starting at full speed. */
    readonly property real yScale: root._t < 0 ? 1 : Math.max(0.012, 1 - root._p1 * root._p1 * (3 - 2 * root._p1))

    /*! Horizontal scale: holds at 1 until the vertical collapse is nearly done,
        then contracts the remaining line to a point. */
    readonly property real xScale: root._t < 0 ? 1 : Math.max(0, 1 - root._p2 * root._p2)

    /*! Fades only at the very end — the line stays bright while it shrinks,
        which is what sells it as light rather than as a dissolve. */
    readonly property real opacity: root._t < 0 ? 1 : (root._p2 < 0.75 ? 1 : 1 - (root._p2 - 0.75) / 0.25)

    /*! Extra brightness as the picture's energy concentrates into the line.
        Peaks at the moment the vertical collapse completes. */
    readonly property real bloom: root._t < 0 ? 0 : Math.sin(Math.PI * Math.min(1, root.progress / root.verticalShare)) * 0.85

    signal finished

    function start(): void {
        root._t = 0;
        Ticker.subscribe(root);
    }

    function reset(): void {
        if (root._t >= 0)
            Ticker.unsubscribe(root);
        root._t = -1;
    }

    readonly property bool needsAdvance: root._t >= 0

    function advance(dt: real): bool {
        if (root._t < 0)
            return false;
        root._t += dt;
        if (root._t >= root.duration) {
            root._t = -1;
            root.finished();
            return false;
        }
        return true;
    }
}
