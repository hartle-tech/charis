import QtQuick

/*!
    A ballistic bounce: something thrown upward that falls back and bounces.

    \section2 Why this is not a Spring

    A spring is the right primitive for "go to a value and settle there". It is
    the wrong one for a bounce, and the difference is visible in the first
    second.

    The dock's launch animation used a spring clamped to its upward half —
    `Math.max(0, -spring.value)`. A spring oscillates symmetrically about its
    target, so clipping the downward half leaves the icon sitting motionless on
    the floor for half of every cycle and then leaving abruptly. There is no
    acceleration into the floor and no deceleration out of it: the motion has a
    flat bottom and a corner at each end. Watched at size it reads exactly as
    "squared, no easing" — because that is what it is.

    A real hop is ballistic. It leaves fast, decelerates into a rounded apex,
    accelerates back down, and loses energy on each contact. Every one of those
    is what makes a moving thing look like it has mass, and none of them
    survives clamping a sine wave.

    \section2 The model

    Constant downward acceleration, one integration step per frame, a floor at
    zero, and a coefficient of restitution applied on contact:

    \list
      \li \c v -= gravity * dt
      \li \c value += v * dt
      \li on \c{value < 0}: \c{value = 0}, \c{v = -v * restitution}
    \endlist

    Semi-implicit Euler, substepped when a frame runs long, so a dropped frame
    cannot let the icon tunnel through the floor and vanish.

    \qml
    Hop { id: hop; gravity: 2600; restitution: 0.55 }
    Item { y: -hop.value }
    Timer { onTriggered: hop.launch(720) }
    \endqml
*/
QtObject {
    id: root

    /*! Height above the floor, in pixels. Never negative. */
    readonly property real value: root._y
    property real _y: 0
    property real _v: 0

    /*! Downward acceleration, px/s². Higher feels heavier and snappier; the
        apex arrives sooner and the fall is quicker. */
    property real gravity: 2600

    /*! Fraction of speed kept on each contact with the floor. 0 stops dead on
        landing, 1 bounces for ever. macOS's dock keeps a little over half. */
    property real restitution: 0.55

    /*! Below this upward speed a contact is treated as the end of the hop
        rather than as another bounce. Without it the tail is an infinite series
        of sub-pixel taps that never lets the frame clock stop. */
    property real restSpeed: 40

    readonly property bool animating: root._active
    property bool _active: false

    /*! Throw it upward at \a v pixels per second.

        The apex is v²/2g, so a hop one icon tall on a 52px icon at the default
        gravity wants v ≈ 520. \l launchToHeight does that arithmetic. */
    function launch(v: real): void {
        root._v = Math.abs(v);
        if (!root._active) {
            root._active = true;
            Ticker.subscribe(root);
        }
    }

    /*! Throw it so the first apex lands at \a h pixels. The useful form: a
        dock wants "one icon tall", not "720 pixels per second", and the two
        are only the same at one gravity. */
    function launchToHeight(h: real): void {
        root.launch(Math.sqrt(2 * root.gravity * Math.max(0, h)));
    }

    /*! Stop where it is. */
    function reset(): void {
        root._y = 0;
        root._v = 0;
        if (root._active) {
            root._active = false;
            Ticker.unsubscribe(root);
        }
    }

    readonly property bool needsAdvance: root._active

    /*!
        Integrate \a dt seconds. Returns true while still moving.

        ⚠️ SUBSTEPPED. At 2600 px/s² a hop reaches ~700 px/s, which is 12px per
        frame at 60Hz and 47px across a dropped 60ms frame. A single Euler step
        that large can place the icon below the floor by more than the bounce
        would have lifted it, and the correction then throws it upward harder
        than it arrived — one stutter turns into a visible extra bounce.
    */
    function advance(dt: real): bool {
        if (!root._active)
            return false;

        const steps = Math.max(1, Math.ceil(dt / 0.008));
        const h = dt / steps;
        let y = root._y;
        let v = root._v;

        for (let i = 0; i < steps; ++i) {
            v -= root.gravity * h;
            y += v * h;
            if (y <= 0) {
                y = 0;
                v = -v * root.restitution;
                if (v < root.restSpeed) {
                    root._y = 0;
                    root._v = 0;
                    root._active = false;
                    // Returning false is how a subscriber retires; the Ticker
                    // collects it after the frame. Calling unsubscribe() from
                    // in here as well would mutate the list the Ticker is
                    // walking, which is exactly the case its snapshot exists
                    // to survive — no reason to lean on that.
                    return false;
                }
            }
        }

        root._y = y;
        root._v = v;
        return true;
    }
}
