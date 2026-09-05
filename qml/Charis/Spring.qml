pragma ComponentBehavior: Bound

import QtQuick

/*!
    \qmltype Spring
    \brief A physical spring you can re-aim mid-flight without it flinching.

    WHY THIS EXISTS, AND WHY IT IS THE FIRST FILE IN THIS LIBRARY.

    Qt Quick's ordinary animation is a DURATION and an EASING CURVE. You say
    "take 300ms and follow this curve", and it does, from wherever it started
    to wherever it was told. That is a perfectly good way to animate a thing
    that is not being touched.

    It falls apart the moment a person interrupts it. Change the target
    half-way and the curve restarts: the item stops dead, then accelerates
    again from zero, because an easing curve has no idea how fast the thing
    was already moving. Everyone has felt this — it is the difference between
    a panel that follows your finger and one that argues with it. Caelestia
    has 351 `Behavior on <property>` blocks and every one of them is
    duration-based, which is why its motion reads as *animated* rather than
    as *physical*.

    Apple's does not, and the reason is not taste or budget: since iOS 7 their
    interruptible animations have been springs, integrated per frame from
    current position AND CURRENT VELOCITY. Retarget a spring mid-flight and
    nothing restarts — the force changes, the mass keeps its momentum, and the
    result curves smoothly into the new destination. That single property is
    the largest share of what "feels Apple" and it cannot be approximated with
    a curve, however carefully the curve is chosen.

    So: a real damped harmonic oscillator, in the parameterisation SwiftUI
    uses, driven by a FrameAnimation so it integrates against REAL elapsed
    time.

    \section2 Parameters, and why these two rather than mass/stiffness

    Physics texts use mass, stiffness and damping coefficient. Those are
    miserable to tune: changing stiffness changes both speed AND bounce, so
    you chase your own tail. SwiftUI's parameterisation is the humane one and
    is what this copies:

    \list
    \li \c response — roughly how long the move takes, in seconds. It is the
        oscillator's natural period: ω = 2π / response. Bigger is slower.
    \li \c damping — the damping FRACTION. 1.0 is critically damped: fastest
        approach with no overshoot at all. Below 1.0 overshoots and settles
        (0.7 gives one gentle bounce). Above 1.0 is sluggish.
    \endlist

    Both are independent, which is the whole point: change the speed without
    changing the character, or the character without changing the speed.

    \section2 Why FrameAnimation and not Timer

    A Timer fires on a wall clock and knows nothing about the display. This
    machine runs 144 Hz; a laptop panel runs 60; an external 4K might be 30
    under load. A spring integrated with a FIXED dt runs at a different speed
    on each of them — the same UI would feel different on two monitors of the
    same machine, which is exactly the bug this library exists to prevent.

    FrameAnimation ticks once per rendered frame and hands over the real
    elapsed time, so the motion is defined in SECONDS and comes out identical
    at any refresh rate. That is the honest way to satisfy "adapts to the
    screen's refresh rate": not by measuring FPS and compensating, but by
    never having assumed a frame rate in the first place.

    \section2 Substepping, which is not optional

    Semi-implicit Euler is stable only while dt is small relative to the
    period. Drop three frames on a 144 Hz panel — a compositor hiccup, a
    heavy page load — and a stiff spring integrated in one big step can gain
    energy and visibly explode. So the step is subdivided to a ceiling, and a
    pathological dt is clamped rather than trusted: after a long stall the
    right behaviour is to arrive, not to catapult.

    \section2 Usage

    \qml
    Spring {
        id: springX
        target: dragging ? pointerX : restX
        response: 0.35
        damping: 0.8
    }
    Item { x: springX.value }
    \endqml

    Nothing needs to be started or stopped: it sleeps when settled and wakes
    when the target moves, so an idle dock costs nothing.
*/
QtObject {
    id: root

    /*! Where the spring is being pulled to. Change it whenever you like. */
    property real target: 0

    /*! The current position. Bind your property to THIS. */
    property real value: 0

    /*! Current velocity, in units per second. Readable so one spring can
        hand momentum to another — a flick that becomes a fling. */
    property real velocity: 0

    /*! Natural period in seconds. */
    property real response: 0.4

    /*! Damping fraction. 1.0 = critically damped, no overshoot. */
    property real damping: 1.0

    /*!
        Distance below which the spring is declared settled, snapped exactly
        onto the target and switched off.

        A spring approaches its target asymptotically and never mathematically
        arrives, so without a threshold it burns a frame forever, on every
        animated property, for motion nobody can see. On a dock of forty icons
        that is the difference between an idle cost of zero and an idle cost of
        the whole compositor.

        ⚠️ THIS IS AN UPPER BOUND, NOT THE THRESHOLD ITSELF. 0.5 is the right
        number for a spring animating PIXELS and completely wrong for one
        animating a scale factor from 1.0 to 1.3: `|x − target| < 0.5` is true
        on the very first frame, so the spring would snap instantly and the
        magnification would have no animation at all. That footgun is silent —
        the property arrives at the right value, just immediately — so the
        effective threshold is also scaled to the size of the move actually
        being made, and the smaller of the two wins. A 500px slide settles at
        0.5px; a 0.3 scale change settles at 0.0003. Neither needs configuring.
    */
    property real epsilon: 0.5

    // Magnitude of the current move, captured at each retarget. See epsilon.
    property real _span: 0

    /*! True while moving. Useful for `layer.enabled: spring.animating`, so
        expensive effects only exist while they can be perceived. */
    readonly property bool animating: root._active

    /*! Jump to a value with no animation, cancelling any motion. For setting
        an initial position without watching it fly in from zero. */
    function reset(v: real): void {
        root.velocity = 0;
        root.value = v;
        root.target = v;
        // AFTER the target assignment, which would otherwise re-arm the spring
        // through onTargetChanged and animate the very jump this function
        // exists to avoid.
        root._active = false;
        root._span = 0;
        Ticker.unsubscribe(root);
    }

    /*! Add velocity without moving the value — hand a gesture's throw speed
        to the spring so the release continues the motion instead of
        restarting it. */
    function impulse(v: real): void {
        root.velocity += v;
        root._active = true;
        // A flick can start motion without the target ever changing, so this
        // has to arm the clock itself rather than rely on onTargetChanged.
        if (root._span <= 0)
            root._span = Math.abs(root.target - root.value);
        if (root.autoDrive)
            Ticker.subscribe(root);
    }

    /*!
        Whether this spring runs its own per-frame clock.

        True is the convenient default and is right for a handful of springs.
        Set it false and call \l advance yourself when you have MANY — a dock
        with forty icons, each with a scale and an offset spring, is eighty
        FrameAnimation objects each waking the scene graph independently. One
        shared ticker calling advance() on all eighty is one callback instead,
        and they stay in lockstep, which matters when their motion is supposed
        to read as a single coordinated wave rather than eighty things that
        happen to be moving.
    */
    property bool autoDrive: true

    /*! True while moving under its own clock, or while not yet settled when
        driven externally. */
    readonly property bool needsAdvance: root._active

    property bool _active: false

    /*!
        Integrate one step of \a dt seconds. Returns true while still moving.

        Public and explicit so the physics can be driven from any clock — a
        shared ticker, a test harness feeding fixed timesteps, or a gesture
        recogniser stepping in sync with input events rather than frames.

        This being callable is also the only way the refresh-rate-independence
        claim is TESTABLE rather than merely asserted: feed it 1/30, 1/60 and
        1/144 and the settling time in seconds has to come out the same.
    */
    function advance(dt: real): bool {
        if (!root._active)
            return false;

        // ⚠️ CLAMPED, NOT TRUSTED. Real elapsed time after a stall — a
        // converge, a GC pause, a monitor waking — can be a whole second.
        // Integrating that faithfully would fling the item across the screen
        // and back. Someone who looked away expects to find things where they
        // settled, so a long gap is treated as one slow frame and the spring
        // simply arrives.
        const step = Math.min(dt, 0.05);
        if (step <= 0)
            return true;

        const omega = 2 * Math.PI / Math.max(root.response, 0.0001);
        const zeta = root.damping;

        // Substep so stiffness cannot outrun the integrator.
        //
        // 2ms rather than a whole frame is not only about stability — at one
        // step per frame semi-implicit Euler is stable here but adds damping
        // nobody asked for, and the error grows with ωh. It shows up as a
        // shallow overshoot: at a 4ms step the ζ=0.6 peak measured 108.876
        // against the closed-form 109.478, and halving the step moved it to
        // 109.169. Under-shooting the bounce is precisely the defect a person
        // would describe as "mushy" without being able to name it. The cost is
        // about four extra multiply-adds per frame, which is free next to
        // drawing a single rounded rectangle.
        const steps = Math.max(1, Math.ceil(step / 0.002));
        const h = step / steps;

        let x = root.value;
        let v = root.velocity;
        const t = root.target;

        for (let i = 0; i < steps; i++) {
            // Semi-implicit Euler: velocity first, then position with the NEW
            // velocity. Explicit Euler is unstable here and gains energy on
            // every step; the swap costs nothing and fixes it.
            const a = -(omega * omega) * (x - t) - 2 * zeta * omega * v;
            v += a * h;
            x += v * h;
        }

        // Scale the threshold to the move being made, capped by `epsilon`, so
        // a spring animating a 0.3 scale factor is not declared settled on its
        // first frame by a threshold meant for pixels.
        const thresh = Math.max(Math.min(root.epsilon, root._span * 0.001), 1e-9);

        // Settle on BOTH conditions. Position alone stops a spring at the
        // exact moment it is passing through the target at full speed, which
        // is a visible snap in the middle of a bounce.
        if (Math.abs(x - t) < thresh && Math.abs(v) < thresh * 10) {
            root.value = t;
            root.velocity = 0;
            root._active = false;
            return false;
        }

        root.value = x;
        root.velocity = v;
        return true;
    }

    onTargetChanged: {
        root._active = true;
        root._span = Math.abs(root.target - root.value);
        // Subscribing to the shared clock rather than owning a FrameAnimation
        // is what keeps an idle shell at zero frames — see Ticker for the
        // measurement that forced this. Ticker drops the subscription itself
        // the moment advance() reports settled, so nothing here has to
        // remember to clean up.
        if (root.autoDrive)
            Ticker.subscribe(root);
    }

    Component.onDestruction: Ticker.unsubscribe(root)
}
