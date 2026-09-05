import QtQuick

/*!
    An image blown apart into chunky pixels that fly outward and fall — the
    8-bit firework.

    \section2 How the pixels are the image's own

    A particle system would emit coloured dots that resemble the icon's palette.
    This cuts the icon into a grid and gives each cell its own \l{QtQuick.Image}
    clipped to that cell, so what flies apart IS the artwork: Firefox's flame
    leaves as flame-coloured chunks, Steam's rim as blue ones. Nothing samples
    pixels or reads back a texture, which QML cannot do anyway — each fragment
    is the source image with a \c sourceClipRect.

    \c cells × \c cells fragments. Eight is the retro number and 64 items is
    cheap; sixteen is 256 items and starts to cost.

    \section2 The physics

    Each fragment gets an outward velocity from the burst centre, scaled by its
    distance so the rim leaves faster than the middle, plus a deterministic
    jitter. Then gravity, and a spin. Deterministic because a burst that looks
    different every time cannot be screenshotted and compared — and because a
    seeded pattern reads as designed where noise reads as noise.

    \qml
    PixelBurst {
        id: burst
        anchors.fill: icon
        source: icon.source
        onFinished: root.removed()
    }
    MouseArea { onClicked: burst.fire() }
    \endqml
*/
Item {
    id: root

    /*! The artwork to blow apart. */
    property url source

    /*! Grid resolution. 8 gives the chunky look the effect is named for. */
    property int cells: 8

    /*! Seconds before the last fragment is gone. */
    property real duration: 0.85

    /*! Pixels per second the rim fragments leave at. */
    property real speed: 420

    /*! Downward acceleration, px/s². Enough that the arc is visibly ballistic
        rather than a uniform spray. */
    property real gravity: 1500

    readonly property bool running: root._t >= 0
    property real _t: -1

    signal finished

    visible: root._t >= 0

    function fire(): void {
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

    // 🔴 BUILT ONLY WHILE IT IS FIRING. This used to instantiate cells x cells
    // Images unconditionally — 64 per dock item, 512 across a row, each one
    // decoding the icon and holding a texture, all of them invisible and all of
    // them costing layout and memory for ever. The dock's own frame meter went
    // to 41ms a frame and 24fps, and the whole shell felt sluggish: an effect
    // that plays for eight tenths of a second was being paid for continuously.
    Repeater {
        model: root._t < 0 ? 0 : root.cells * root.cells

        Image {
            id: frag
            required property int index

            readonly property int col: frag.index % root.cells
            readonly property int row: Math.floor(frag.index / root.cells)
            readonly property real cw: root.width / root.cells
            readonly property real ch: root.height / root.cells

            // Direction from the centre of the grid, so fragments leave
            // radially. Half-cell offsets put the centre between cells rather
            // than on one, which stops the middle four sitting still.
            readonly property real dx: (frag.col + 0.5) / root.cells - 0.5
            readonly property real dy: (frag.row + 0.5) / root.cells - 0.5
            readonly property real dist: Math.max(0.08, Math.sqrt(frag.dx * frag.dx + frag.dy * frag.dy))

            // ⚠️ DETERMINISTIC JITTER, not Math.random(). A burst that differs
            // every run cannot be captured and compared against a later one,
            // and the whole reason this project measures its animations is that
            // "it looks right" has been wrong before. A hash of the index gives
            // scatter that is stable across runs.
            readonly property real seed: (Math.sin(frag.index * 12.9898) * 43758.5453) % 1
            readonly property real jitter: 0.65 + 0.7 * Math.abs(frag.seed)

            readonly property real vx: (frag.dx / frag.dist) * root.speed * frag.jitter
            readonly property real vy: (frag.dy / frag.dist) * root.speed * frag.jitter - root.speed * 0.45

            width: frag.cw
            height: frag.ch
            x: frag.col * frag.cw + (root._t < 0 ? 0 : frag.vx * root._t)
            y: frag.row * frag.ch + (root._t < 0 ? 0 : frag.vy * root._t + 0.5 * root.gravity * root._t * root._t)

            rotation: root._t < 0 ? 0 : frag.seed * 540 * root._t
            // Fragments fade late and unevenly, so the burst thins out instead
            // of switching off all at once.
            opacity: root._t < 0 ? 1 : Math.max(0, 1 - Math.pow(root._t / root.duration, 1.6) * (0.75 + 0.5 * Math.abs(frag.seed)))

            source: root.source
            smooth: false          // nearest-neighbour: this is meant to look 8-bit
            fillMode: Image.Stretch
            asynchronous: true
            cache: true

            // Each fragment decodes the whole icon once — Qt caches it, so the
            // 64 fragments share one decode — and shows only its own cell.
            sourceSize.width: root.width
            sourceSize.height: root.height
            sourceClipRect: Qt.rect(Math.round(frag.col * root.width / root.cells), Math.round(frag.row * root.height / root.cells), Math.ceil(root.width / root.cells), Math.ceil(root.height / root.cells))
        }
    }
}
