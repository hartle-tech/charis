pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick

/*!
    \qmltype Ticker
    \brief The one frame clock in the process, running only while something
           needs it.

    WHY THIS EXISTS — A MEASURED BUG, NOT A TIDINESS ARGUMENT.

    A running \c FrameAnimation is a running \c QAbstractAnimation, and Qt
    Quick's render loop draws a frame for as long as any animation is running.
    On a Wayland layer-shell surface that means committing a new buffer every
    frame, which means the compositor recomposites the whole screen every
    frame, for as long as the animation exists.

    This was measured on aphrOS rather than assumed. Two identical Quickshell
    configs, each a 10×10 invisible layer-shell surface in a corner, run for
    eight seconds under \c{WAYLAND_DEBUG=1}, counting \c wl_surface.commit:

    \badcode
    without a always-on FrameAnimation:     5 commits   (startup, then idle)
    with one always-on FrameAnimation:  1,077 commits   (~135/second, forever)
    \endcode

    A 215× difference, from a ten-pixel invisible square, on behalf of an
    object whose entire purpose was to make the shell CHEAPER. Multiply that by
    a dock of forty icons each owning two springs and the shell never lets the
    GPU idle — which on this machine had already been reported once as
    "GPU usage up to 60%" with nothing on screen moving.

    \section2 What this does about it

    One \c FrameAnimation for the whole process, \c running bound to whether
    anything is actually subscribed. Nothing moving means no animation running
    means no frame drawn means no buffer committed means the compositor sleeps.
    Idle costs exactly zero, by construction rather than by discipline.

    It is also cheaper when things ARE moving: eighty springs is eighty
    animation objects each independently waking the scene graph, against one
    callback that walks a list. And they stay in lockstep — the same \c dt for
    every subscriber in a frame — which matters when the motion is meant to
    read as one coordinated wave rather than eighty things that happen to be
    moving at once.

    \section2 Subscribers

    Anything with an \c{advance(dt) -> bool} method. Returning false means
    "settled, drop me", so subscribers unsubscribe themselves by finishing and
    nobody has to remember to clean up. \l Spring does this automatically
    unless \c autoDrive is false.
*/
QtObject {
    id: root

    property var _subs: []

    /*! Number of live subscribers. Zero means the process is drawing nothing. */
    readonly property int subscriberCount: root._subs.length

    /*! True while a frame clock is running. */
    readonly property bool running: driver.running

    /*! Start advancing \a obj every frame. Idempotent. */
    function subscribe(obj: var): void {
        if (!obj || root._subs.indexOf(obj) !== -1)
            return;
        // Copy-on-write: _subs is a plain JS array behind a QML property, and
        // mutating it in place does not emit a change signal, so `running`
        // would never re-evaluate and the clock would never start.
        const next = root._subs.slice();
        next.push(obj);
        root._subs = next;
    }

    /*! Stop advancing \a obj. Safe to call for something never subscribed. */
    function unsubscribe(obj: var): void {
        const i = root._subs.indexOf(obj);
        if (i === -1)
            return;
        const next = root._subs.slice();
        next.splice(i, 1);
        root._subs = next;
    }

    property FrameAnimation _driver: FrameAnimation {
        id: driver

        running: root._subs.length > 0

        onTriggered: {
            const dt = frameTime;

            // Iterate a SNAPSHOT. A subscriber's advance() can settle and
            // unsubscribe itself, or start another animation and subscribe
            // something new; mutating the array under a live index skips
            // whichever element shifted into the vacated slot. That failure is
            // intermittent, load-dependent, and looks exactly like a random
            // stuck animation.
            const subs = root._subs;
            let finished = null;

            for (let i = 0; i < subs.length; i++) {
                const s = subs[i];
                // A subscriber can be destroyed between frames — a dock icon
                // for an app that just quit. QML nulls the reference, and
                // calling advance() on it would take down the frame callback
                // and freeze every other animation in the process.
                if (!s || typeof s.advance !== "function" || !s.advance(dt)) {
                    if (!finished)
                        finished = [];
                    finished.push(s);
                }
            }

            if (finished)
                for (const f of finished)
                    root.unsubscribe(f);

            // Sample the budget exactly ONCE per frame, here, rather than from
            // each subscriber — forty springs calling sample() would put forty
            // copies of the same frame into a 32-frame window and the median
            // would describe one frame rather than the last half second.
            FrameBudget.sample(dt);
        }
    }
}
