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

    /*!
        The cadence this process actually achieves when it is healthy, in Hz,
        learned from observation.

        ⚠️ DELIBERATELY NOT THE DISPLAY'S REFRESH RATE, and that was a real bug.
        Comparing against the panel assumes the toolkit can drive animations at
        panel rate, and on this platform it cannot: Qt's animation timer runs at
        a fixed 16 ms — 62.5 Hz — unless a vsync-based animation driver is
        installed, and neither the threaded nor the basic render loop installs
        one here. Measured on a 144 Hz display, with the surface committing 130
        frames a second: animations advanced 62.5 times a second under both.

        Told the panel was 144 Hz, this singleton therefore concluded the
        machine was failing by a factor of two and shed EVERY effect — shadows
        and glass switched off permanently, on hardware that was keeping up
        perfectly with everything it was being asked to do. Quality must ask
        "are we keeping up with what this platform can do", never "are we
        matching the panel", because the second question has an answer nobody
        can act on.

        So the baseline is the fastest sustained cadence observed, and pressure
        is measured against that. A machine that degrades from its own baseline
        sheds effects; one that was never able to hit panel rate in the first
        place is left alone.
    */
    property real baselineHz: 0

    /*! Kept for callers that want to record it; not used for judging. */
    property real refreshRate: 60

    /*!
        Frame interval as a multiple of the display's period.

        1.0 means frames are arriving exactly on cadence. 2.0 means every other
        frame is being missed.

        ⚠️ THIS IS NOT "HOW MUCH OF THE BUDGET THE WORK USED", and reading it
        that way is a mistake this file made and shipped. On a vsynced surface
        the interval between frames is pinned to the display period whatever the
        work costs — a shell drawing one rectangle and a shell drawing a
        thousand both report 1.0 until one of them actually misses a deadline.
        There is no headroom information here at all; the only thing the
        interval reveals is DROPPED frames.
    */
    readonly property real pressure: root.baselineHz > 0 ? root._median * root.baselineHz : 1

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

    /*!
        \section2 Frame tracing

        Records every frame delta, in milliseconds, for as long as it is on.

        🔴 WHY THIS HAD TO EXIST. "The animation has no weight, it is not
        smooth" is a real complaint and it was unanswerable, because the only
        instrument to hand was a screen recorder — and a screen recorder is not
        one. `wf-recorder` at `-r 120` on a 3414×438 region pushes captured
        frames through an `fps` filter that DUPLICATES them to reach the
        requested rate, so the file always has 120 frames per second and the
        icon's position changes in every fourth one. That measures the capture
        pipeline, not the dock, and it cannot tell 28 Hz of rendering from 28 Hz
        of screen-grabbing.

        The dock knows its own frame times. It is the only thing that does. This
        hands them over.

        Off by default and costing one branch per frame when off: a permanently
        recording profiler in a shell component is the same mistake as the
        always-on FrameAnimation this file already describes.

        \qml
        FrameBudget.startTrace();
        // … drive the interaction …
        console.log(FrameBudget.stopTrace());   // "[6.94,6.95,6.93,…]"
        \endqml
    */
    property bool tracing: false
    property var _trace: []

    /*! Begin recording frame deltas, discarding anything from a previous run. */
    function startTrace(): void {
        root._trace = [];
        root.tracing = true;
    }

    /*! Stop recording and return the deltas as a JSON array of milliseconds. */
    function stopTrace(): string {
        root.tracing = false;
        return JSON.stringify(root._trace);
    }

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

    /*! Forget the learned baseline as well — after a resolution change, or a
        move to a different monitor. */
    function relearn(): void {
        root.recalibrate();
        root.baselineHz = 0;
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

        // Capped, so a trace left running cannot grow without bound in a
        // process that is meant to outlive every application on the desktop.
        // 6000 frames is 40s at 144Hz, far longer than any interaction.
        if (root.tracing && root._trace.length < 6000)
            root._trace.push(Math.round(dt * 1e6) / 1e3);

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

        // Learn the baseline: the FASTEST sustained cadence seen so far. The
        // first full window establishes it, and any later window that is faster
        // raises it — a machine that was briefly busy at startup is not
        // condemned to a slow baseline for the rest of the session.
        const hz = 1 / root._median;
        if (root.baselineHz <= 0 || hz > root.baselineHz)
            root.baselineHz = hz;

        // 🔴 THE THRESHOLD WAS 0.8 OF THE DISPLAY PERIOD AND IT WAS WRONG IN
        // THE WORST DIRECTION. "Target 80% of the budget" sounds prudent and is
        // meaningless: on a vsynced surface the interval between frames is the
        // display period whatever the work costs, so pressure was 1.0 by
        // definition and 1.0 > 0.8. Quality collapsed to zero the moment
        // anything animated, and every effect was shed precisely when
        // everything was working.
        //
        // The interval only carries information about MISSED frames, measured
        // against a cadence this platform can actually reach.
        const p = root._median * root.baselineHz;
        const want = p <= 1.25 ? 1 : Math.max(0, 1 - (p - 1.25) / 1.25);

        // Asymmetric: down in ~0.15s, up over ~2s. Dropping quality the moment
        // the machine is in trouble is what keeps an interaction responsive;
        // restoring it eagerly walks straight back into the load that caused
        // the problem.
        const rate = want < root._quality ? 0.15 : 0.01;
        root._quality = root._quality + (want - root._quality) * rate;
    }
}
