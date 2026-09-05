pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick

/*!
    \qmltype FrameBudget
    \brief Measures what the machine is actually managing, so effects can cost
           what the machine can actually afford.

    THE PROBLEM. Every expensive effect in a shell — blur, refraction, drop
    shadows, live thumbnails — is worth its cost on a 144 Hz desktop with a
    discrete GPU and ruinous on an integrated laptop panel driving 4K. The
    usual answers are both bad: hard-code the effects and be unusable on half
    the hardware, or expose a settings toggle and make every user diagnose
    their own graphics stack.

    The honest answer is to measure. This singleton watches how long frames
    are actually taking and publishes a single number, \c quality, that
    effects scale themselves against. Nobody configures anything; a slow
    machine quietly gets a simpler shell, and the same build is correct on
    both.

    \section2 Why the median and not the mean

    Frame times are spiky by nature — a GC pause, a window mapping, a
    wallpaper decode. A mean is dragged around by single outliers, so a
    quality signal built on one oscillates: effects switch off because of a
    hiccup, which makes the next frames cheap, which switches them back on,
    which makes them expensive again. That pumping is far more visible than
    the effect ever was.

    A median over a rolling window ignores isolated spikes entirely and only
    moves when frames are CONSISTENTLY late, which is exactly the condition
    worth reacting to.

    \section2 Why quality changes slowly and asymmetrically

    Degradation is fast and recovery is slow, deliberately. Dropping quality
    the moment the machine is in trouble is what keeps an interaction
    responsive; restoring it eagerly walks straight back into the load that
    caused the problem. So \c quality falls quickly and climbs back over
    seconds, and cannot flap.

    \section2 What it does NOT do

    It does not drive the springs. Motion is defined in seconds and
    integrated against real elapsed time (see \l Spring), so it is already
    refresh-rate correct without consulting anything here. This is only about
    how much the shell should try to DRAW. Conflating the two is how a UI
    ends up running in slow motion on a slow machine, which is the one
    outcome worse than dropping an effect.
*/
QtObject {
    id: root

    /*! Smoothed frames per second, from the median frame time. */
    readonly property real fps: root._median > 0 ? 1 / root._median : 60

    /*! The display's refresh rate, as reported by the window's screen. Set by
        whoever creates the shell surface; defaults to the safe assumption. */
    property real refreshRate: 60

    /*! How much of the frame budget is being consumed, 0..1+. Above 1 means
        frames are missing their deadline. */
    readonly property real pressure: root._median * root.refreshRate

    /*!
        0..1, how expensive the shell may currently be.

        1.0 — everything: refraction, blur, shadows, live previews.
        0.5 — cheap approximations: flat translucency instead of refraction.
        0.0 — motion and layout only.

        Bind effect properties to this rather than testing it, so the
        transition is continuous:
        \qml
        opacity: 0.4 + 0.6 * FrameBudget.quality
        layer.enabled: FrameBudget.quality > 0.3
        \endqml
    */
    readonly property real quality: root._quality
    property real _quality: 1

    /*! True when the machine has been struggling long enough to be believed. */
    readonly property bool stressed: root._quality < 0.9

    // Rolling window of recent frame times. Half a second at 60 Hz, a quarter
    // at 144 — long enough to be stable, short enough to react within one
    // interaction rather than after it.
    property var _window: []
    property real _median: 1 / 60
    readonly property int _windowSize: 32

    /*! Reset the measurement — after a converge, a resolution change, or
        anything else that makes the recent past a bad predictor. */
    function recalibrate(): void {
        root._window = [];
        root._quality = 1;
    }

    /*!
        Record one frame of \a dt seconds.

        ⚠️ CALLED BY \l Ticker, ONCE PER FRAME. Do not call this from anywhere
        else, and in particular not from each animating object: forty springs
        calling it would push forty copies of the same frame into a 32-frame
        window, and the median would then describe a single frame rather than
        the last half second.

        This singleton deliberately owns NO clock of its own. It did once, and
        it was the most expensive object in the library: an always-running
        FrameAnimation keeps Qt Quick's render loop drawing, which on a
        layer-shell surface keeps the compositor recompositing the whole screen
        forever. Measured on aphrOS at 1,077 wl_surface.commit in eight seconds
        against 5 without it — a 215× difference from an object whose entire
        purpose is to make the shell cheaper. A budget meter that has to burn
        the budget to measure it is worse than no budget meter.

        The consequence, which is the right behaviour rather than a compromise:
        quality is only updated while something is animating. That is exactly
        when it matters, and between animations it retains what it last
        measured — so a machine that was struggling a moment ago is still
        treated as struggling when the next animation starts, instead of
        optimistically resetting to full quality every time the screen goes
        still.
    */
    function sample(dt: real): void {
        // Ignore absurd deltas outright. After a DPMS wake or a converge the
        // first frame can be seconds long; feeding that in would declare the
        // machine overloaded for the next half second of healthy frames.
        if (dt <= 0 || dt > 0.5)
            return;

        const w = root._window;
        w.push(dt);
        if (w.length > root._windowSize)
            w.shift();

        // Sort a COPY. Sorting in place would destroy the chronological order
        // that shift() relies on to expire old samples, and the window would
        // slowly fill with whatever the sort left at the end.
        const sorted = w.slice().sort((a, b) => a - b);
        root._median = sorted[Math.floor(sorted.length / 2)];

        // Wait for a full window before judging anything. Early samples are
        // dominated by first-frame shader compilation and texture uploads, and
        // would condemn a machine for work it only ever does once.
        if (w.length < root._windowSize)
            return;

        // Target: comfortably inside the frame budget. 0.8 rather than 1.0
        // because a shell sharing the GPU with a game or a video should yield
        // BEFORE it starts costing that app frames, not after.
        const p = root._median * root.refreshRate;
        const want = p <= 0.8 ? 1 : Math.max(0, 1 - (p - 0.8) * 2);

        // Asymmetric: down in ~0.15s, up over ~2s. Dropping quality the moment
        // the machine is in trouble is what keeps an interaction responsive;
        // restoring it eagerly walks straight back into the load that caused
        // the problem.
        const rate = want < root._quality ? 0.15 : 0.01;
        root._quality = root._quality + (want - root._quality) * rate;
    }
}
