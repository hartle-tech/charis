pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets
import Charis

/*!
    One icon in the dock: the app's icon, clipped to a continuous-curvature
    squircle, with a running indicator underneath.

    Deliberately DUMB. It owns no springs and no animation — its size and
    position are handed to it by \l Dock, because every icon's scale is a pure
    function of one smoothed cursor position, and computing that once for the
    whole row is both cheaper and the only way the motion reads as a single
    coordinated wave rather than N icons that happen to be moving.
*/
Item {
    id: root

    /*! The `.desktop` entry, or null for a running app with no matching one. */
    required property var entry

    /*! Live toplevels belonging to this app. Empty means not running. */
    property var toplevels: []

    /*! Icon edge length in px, driven by the parent's magnification. */
    required property real iconSize

    /*! The icon size at REST, before any magnification.

        Needed by anything that must stay inside the dock's background: the
        background keeps its resting thickness while icons grow out of it, so a
        divider measured against the magnified item box grows straight through
        the top of the panel. */
    required property real restIconSize

    /*! The largest \l iconSize will ever be. The icon's backing store is
        requested at THIS size and never at the current one: binding the
        decode size to a magnifying value re-decodes the icon on almost every
        frame of a hover, which is a stutter and a steady stream of texture
        uploads for an image that never actually changes. */
    required property real maxIconSize

    /*!
        Decode size in DEVICE pixels, snapped up to a standard icon size.

        🔴 THIS WAS IN LOGICAL PIXELS AND EVERY ICON IN THE DOCK WAS SOFT.
        This display runs at scale 1.25, so a 52pt icon occupies 65 real pixels
        and a magnified one 124 — but the icon was decoded at 52 and 99 and then
        upscaled by the compositor. Steam was the obvious victim because its
        artwork has fine detail; Firefox survived because a smooth gradient
        hides resampling. Side by side at 2x it was unmistakable, and it is the
        exact "Linux looks cheap" tell this project exists to remove.
        A screenshot at native resolution is the only way to see it — at any
        smaller magnification the softness reads as anti-aliasing.

        🔴 AND THEN IT ASKED FOR 128 AND STEAM WAS STILL A BLURRED SMUDGE.
        Icon lookup does NOT round up to the next available size — it picks the
        size with the smallest absolute distance from what you asked for. Steam
        ships 16, 24, 32, 48 and 256, with nothing in between; against a request
        of 128 the 48 is 80 away and the 256 is 128 away, so the resolver hands
        back the FORTY-EIGHT and it gets stretched to 124 device pixels.
        Obsidian looked fine two icons over purely because it happens to ship a
        128 and not a 48. Measured on the running dock, Laplacian variance
        across the icon: Nautilus 1969, Steam 24 — eighty times softer, sitting
        in the same row.

        So ask for the top of the ladder. An exact request of 256 exact-matches
        every theme that has a 256, which in practice is every application icon
        that ships large artwork at all; a theme that stops at 48 returns the 48
        either way, so nothing is made worse. Downscaling 256 → 124 is
        resampling with information to spare and stays crisp; upscaling 48 → 124
        invents three quarters of its pixels and cannot.

        The cost is one 256×256 decode per dock item, once, at startup.
    */
    readonly property int decodeSize: {
        const want = root.maxIconSize * Math.max(1, Screen.devicePixelRatio);
        return want > 256 ? 512 : 256;
    }

    /*! Which screen edge the dock is on — decides where the dot goes. */
    required property int edge

    /*! Used when no `.desktop` entry matched — normally the toplevel's appId. */
    property string fallbackLabel: ""

    /*! "app", "folder" or "separator". */
    property string kind: "app"

    /*! Absolute path, for kind == "folder". */
    property string folder: ""

    /*!
        Icon name for a folder in the row.

        🔴 A FOLDER USED TO DRAW ABSOLUTELY NOTHING. Both the icon and the
        letter-tile fallback were gated on `kind === "app"`, so a configured
        folder took a full slot in the row, magnified with its neighbours,
        opened its stack when clicked — and was invisible. On screen it read as
        a gap in the dock right where the dock is widest, which is the single
        most "unfinished" thing a dock can look like. Directories were in the
        brief from the first sentence.

        The freedesktop names are used where they exist, because a themed
        Downloads folder is part of what makes a dock look native rather than
        drawn by someone who had never seen the desktop it runs on.
    */
    readonly property string folderIconName: {
        const base = root.folder.replace(/\/+$/, "").split("/").pop().toLowerCase();
        const known = {
            downloads: "folder-download",
            download: "folder-download",
            documents: "folder-documents",
            pictures: "folder-pictures",
            music: "folder-music",
            videos: "folder-videos",
            desktop: "user-desktop",
            public: "folder-publicshare",
            templates: "folder-templates"
        };
        return known[base] ?? "folder";
    }

    /*! An image path that replaces this app's icon. Empty uses the app's own.
        A dock full of vendor artwork at six different visual weights is the
        commonest reason people give up on Linux docks looking tidy, and the
        only fix is letting them substitute one. */
    property string iconOverride: ""

    readonly property bool isSeparator: root.kind === "separator"

    /*! Offset from where the drag started, so the icon FOLLOWS THE POINTER.

        🔴 IT DID NOT BEFORE, AND THE GESTURE FELT BROKEN. The row re-laid-out
        underneath the drag, which is correct, but the icon being dragged stayed
        pinned to its slot — so there was no trace, no feedback and nothing
        attached to the cursor. Picking something up and seeing it not move is
        the difference between a drag and a guess. */
    property point dragOffset: Qt.point(0, 0)

    /*! Dragged far enough out of the dock that releasing will remove it.
        Shown, not merely tracked — a removal gesture with no feedback until
        after the fact is how people delete the thing they meant to move. */
    property bool tornOff: false

    /*! True from the moment an app is launched until its first window appears.
        Without it, clicking a cold-starting application does nothing visible
        for several seconds and everyone clicks again — which starts it twice. */
    property bool launching: false

    readonly property bool running: root.toplevels.length > 0
    readonly property string label: root.entry ? (root.entry.name || root.entry.id) : root.fallbackLabel

    signal activated
    signal secondaryRequested(real x, real y)

    /*!
        Emitted while this icon is being dragged.

        Both are in the WINDOW's frame.

        🔴 NEITHER MAY BE ITEM-LOCAL, and the reason is the opposite of
        intuition. During a drag the row re-lays-out so the dragged item follows
        the pointer — which means the pointer never moves RELATIVE TO THE ITEM.
        Measured: `centroid.position.y` sat at 73.2 for an entire 220px upward
        gesture while the item's index still marched from 1 to 4. An item-local
        frame is exactly the one frame that cannot see this gesture.
    */
    signal dragMoved(real axisPos, real crossPos)

    /*! Emitted while the SEPARATOR is dragged, with the pointer's position in
        the WINDOW's frame. macOS puts its resize handle on the divider, not on
        the dock's outer edge, and that is where people reach for it.

        ⚠️ The raw position, not a delta. Resizing the dock changes the surface
        HEIGHT, the surface is anchored to the screen edge, so its top moves —
        and a delta measured against a press point in that frame is contaminated
        by the resize it just caused. Measured: the value oscillated +25, −12,
        +8 within one drag and the dock slammed to its minimum. The caller
        converts to a distance from the screen edge, which does not move. */
    signal separatorMoved(real sceneY, real sceneX)
    signal separatorPressed
    signal separatorReleased
    signal dragStarted
    signal dragEnded

    /*! The launch gave up waiting for a window.

        🔴 A SIGNAL, NOT AN ASSIGNMENT. `launching` is bound from the dock's
        `launching` map, and this timer used to clear it by writing
        `root.launching = false` — which destroys that binding, permanently,
        for this item. One slow application, or one whose toplevel `app_id`
        never matches its desktop id (Steam does exactly this), and the icon
        could never bounce again for the rest of the session. Nothing reports
        it: the code is still there, the timer still fires, the property just
        stops listening. The owner of the state clears the state. */
    signal launchTimedOut

    /*! The removal gesture was released short of the threshold: play the
        refusal and put the icon back. */
    signal dropRefused

    /*! The removal gesture succeeded: the icon is gone. Emitted when the burst
        finishes, so the caller unpins only once the pixels have landed. */
    signal dropAccepted

    /*! Play the "not far enough" answer — a CRT switching off, then the icon
        returns to its slot.

        ⚠️ THE OFFSET IS HELD FOR THE DURATION. Releasing the drag clears
        `dragOffset`, so without this the icon springs home WHILE the collapse
        plays and the effect happens somewhere the user never released
        anything — two animations at once, neither legible. It switches off
        where you let go, and only then comes back. */
    function refuse(): void {
        root._holdX = fx.value;
        root._holdY = fy.value;
        root._holding = true;
        crt.start();
    }

    property real _holdX: 0
    property real _holdY: 0
    property bool _holding: false

    /*! Play the removal — the icon's own pixels blown apart.

        ⚠️ THE OFFSET IS HELD, exactly as the refusal holds it. Releasing the
        drag clears `dragOffset`, so the burst played at the icon's SLOT in the
        dock rather than where the icon was let go — half a screen away from
        the gesture that caused it. */
    function vaporise(): void {
        root._holdX = fx.value;
        root._holdY = fy.value;
        root._holding = true;
        burst.fire();
    }

    readonly property bool _leaving: crt.running || burst.running

    readonly property bool _horizontal: root.edge === Qt.BottomEdge || root.edge === Qt.TopEdge

    // ── Launch bounce ───────────────────────────────────────────────────
    //
    // 🔴 THIS WAS A SPRING CLAMPED TO ITS UPWARD HALF, AND THAT IS WHY THE
    // ANIMATION LOOKED SQUARE. A spring oscillates symmetrically about its
    // target; `Math.max(0, -spring.value)` throws away the downward half, so
    // the icon sat motionless on the floor for half of every cycle and then
    // left abruptly — no acceleration into the floor, no deceleration out of
    // it, a flat bottom with a corner at each end. Reported as "all squared,
    // no easing at all", which is an exact description of a clipped sine.
    //
    // A hop is ballistic, not harmonic. Hop integrates gravity, so the icon
    // leaves fast, rounds off into its apex, accelerates back down and loses
    // energy on each contact — which is the whole of what makes a moving thing
    // read as having mass.
    Hop {
        id: bounce
        // Heavy enough to fall convincingly on a display this size. At 2600
        // px/s² a one-icon hop takes about 0.42s up and down, which is close to
        // macOS and comfortably slower than a UI transition.
        gravity: 2600
        // A little over half the speed kept per contact: three visible hops of
        // decreasing height per impulse, then rest.
        restitution: 0.55
    }

    Timer {
        id: bouncer
        // One full hop is about 0.86s at this gravity — 0.41s for the first
        // arc and three decaying ones after it. 620ms re-launched the icon
        // mid-decay and the bounces ran into each other; a beat of rest is
        // what makes it read as a repeating hop rather than as jitter.
        interval: 1100
        repeat: true
        running: root.launching
        triggeredOnStart: true
        // Stated as a HEIGHT, not as an impulse. The apex of a ballistic hop
        // is v²/2g, so "one icon tall" and "720 px/s" are only the same at one
        // gravity — and an impulse expressed in spring units meant nothing at
        // all to read. An earlier version used a flat -240 impulse, which
        // lifted a 52px icon by thirteen pixels: present in the code, invisible
        // on the screen, and exactly the kind of "it is implemented" that is
        // worth nothing.
        onTriggered: bounce.launchToHeight(root.iconSize * 1.05)
    }

    // Stop bouncing whether or not the app ever appeared. An app that fails to
    // start would otherwise bounce for ever, which is worse than no feedback:
    // it says "still working" indefinitely.
    Timer {
        interval: 12000
        running: root.launching
        onTriggered: root.launchTimedOut()
    }

    Spring {
        id: tearLift
        target: root.tornOff ? 26 : 0
        response: 0.3
        damping: 0.75
    }

    Spring {
        id: tearFade
        target: root.tornOff ? 0.45 : 1
        response: 0.25
        damping: 1.0
        Component.onCompleted: tearFade.reset(1)
    }

    // ── Leaving the dock ────────────────────────────────────────────────
    //
    // Two answers to the same gesture, and they have to be different enough to
    // read at a glance: refused, and accepted. A fade for both would leave the
    // user unsure whether the app is still pinned.
    CrtOff {
        id: crt
        onFinished: {
            root._holding = false;
            root.dropRefused();
        }
    }

    // ⚠️ A SIBLING OF THE ICON, NOT A CHILD. `opacity` in Qt Quick applies to
    // the whole subtree, so hiding the intact icon by setting iconBox's opacity
    // to 0 would hide the burst with it — the explosion would be invisible and
    // the icon would simply vanish, which is the animation this replaces.
    PixelBurst {
        id: burst
        x: iconBox.x + fx.value
        y: iconBox.y + fy.value
        width: root.iconSize
        height: root.iconSize
        source: icon.source
        cells: 8
        onFinished: {
            root._holding = false;
            root.dropAccepted();
        }
    }

    readonly property real _lift: bounce.value + tearLift.value

    // The dragged icon's displacement. Very fast while held — it must feel
    // glued to the pointer — and slower on release so it eases home.
    Spring {
        id: fx
        target: root._holding ? root._holdX : root.dragOffset.x
        response: dragger.active ? 0.045 : 0.34
        damping: dragger.active ? 1.0 : 0.7
        epsilon: 0.05
    }
    Spring {
        id: fy
        target: root._holding ? root._holdY : root.dragOffset.y
        response: dragger.active ? 0.045 : 0.34
        damping: dragger.active ? 1.0 : 0.7
        epsilon: 0.05
    }

    Component.onCompleted: if (root.kind === "app")

    // Lifted above its neighbours while dragged, so it passes OVER them rather
    // than under — a dragged object that slides beneath the others reads as a
    // rendering bug.
    z: dragger.active ? 10 : 0

    Item {
        id: iconBox

        width: root.iconSize
        height: root.iconSize
        // The burst draws the icon's own fragments, so the intact icon must be
        // out of the way while it plays or the artwork sits behind its own
        // explosion.
        opacity: burst.running ? 0 : tearFade.value * crt.opacity

        // ⚠️ A TRANSFORM, NOT x/y. iconBox is positioned by anchors, and in QML
        // anchors silently win over an x/y assignment — so the drag-follow was
        // written, deployed, and did absolutely nothing, with no warning. This
        // is the second time the same rule has bitten in this file.
        // ⚠️ ORDER MATTERS. The Scale must come after the Translate so the
        // collapse happens about the icon where it currently IS, not about
        // where its slot is — a CRT that switches off somewhere other than
        // where you released the icon reads as a second, unrelated animation.
        transform: [
            Translate {
                x: fx.value
                y: fy.value
            },
            Scale {
                origin.x: iconBox.width / 2
                origin.y: iconBox.height / 2
                xScale: crt.xScale
                yScale: crt.yScale
            }
        ]

        // Grow from the dock's floor rather than from the centre. An icon that
        // magnifies about its own middle sinks INTO the edge of the screen,
        // which is the single most obvious tell that a dock is not Apple's.
        anchors.horizontalCenter: root._horizontal ? parent.horizontalCenter : undefined
        anchors.verticalCenter: root._horizontal ? undefined : parent.verticalCenter
        anchors.bottom: root.edge === Qt.BottomEdge ? parent.bottom : undefined

        // The bounce, pushed away from whichever edge the dock is on.
        anchors.bottomMargin: root.edge === Qt.BottomEdge ? root._lift : 0
        anchors.topMargin: root.edge === Qt.TopEdge ? root._lift : 0
        anchors.leftMargin: root.edge === Qt.LeftEdge ? root._lift : 0
        anchors.rightMargin: root.edge === Qt.RightEdge ? root._lift : 0
        anchors.top: root.edge === Qt.TopEdge ? parent.top : undefined
        anchors.left: root.edge === Qt.LeftEdge ? parent.left : undefined
        anchors.right: root.edge === Qt.RightEdge ? parent.right : undefined

        // A separator is a row entry like any other, so it magnifies and
        // shifts with its neighbours instead of standing still while they
        // move around it. It is also the dock's RESIZE HANDLE, as on macOS.
        // 🔴 SIZED AGAINST THE PANEL, NOT AGAINST THE ICON BOX. The separator is
        // a row item like any other, so its box MAGNIFIES on hover — and the
        // divider was a fraction of that box. Hovering it grew the line to
        // 0.78 × the magnified size, which on a 52px icon at 1.9× is 77px
        // against a 76px panel: the line reached out of the top of the dock and
        // hung over the desktop. The dock's background stays at its resting
        // thickness while icons grow out of it, so anything that must stay
        // INSIDE the background has to be measured against the background.
        Rectangle {
            id: sep
            visible: root.isSeparator
            // ⚠️ ORIENTED WITH THE DOCK. A divider in a vertical dock is a
            // HORIZONTAL line, and the previous version hard-coded a tall thin
            // rectangle positioned from the bottom of the item — correct on a
            // bottom dock and nonsense on the other three.
            anchors.horizontalCenter: root._horizontal ? parent.horizontalCenter : undefined
            anchors.verticalCenter: root._horizontal ? undefined : parent.verticalCenter

            // Centred on the panel's band rather than on the item, which grows
            // out of the band when magnified.
            // ⚠️ Binding, not a ternary onto `undefined`. QML cannot assign
            // undefined to a real — "Unable to assign [undefined] to x", eight
            // times a frame — and the value it keeps instead is whatever was
            // there last, which is not the same as leaving the anchor in
            // charge. `when` genuinely removes the binding on the axis the
            // anchor owns.

            readonly property real thin: sepHover.hovered || sepDrag.active ? 2 : 1
            readonly property real long: root.restIconSize * (sepHover.hovered || sepDrag.active ? 0.72 : 0.58)
            width: root._horizontal ? sep.thin : sep.long
            height: root._horizontal ? sep.long : sep.thin
            radius: 1
            color: Qt.rgba(1, 1, 1, sepHover.hovered || sepDrag.active ? 0.55 : 0.22)

            Binding {
                target: sep
                property: "y"
                when: root._horizontal
                value: root.edge === Qt.TopEdge ? root.restIconSize / 2 - sep.height / 2 : sep.parent.height - root.restIconSize / 2 - sep.height / 2
            }
            Binding {
                target: sep
                property: "x"
                when: !root._horizontal
                value: root.edge === Qt.LeftEdge ? root.restIconSize / 2 - sep.width / 2 : sep.parent.width - root.restIconSize / 2 - sep.width / 2
            }

            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
            Behavior on height {
                NumberAnimation {
                    duration: 120
                }
            }
        }

        // 🔴 A PLAIN Image, NOT Quickshell's IconImage — AND THIS IS THE WHOLE
        // REASON THE ICONS WERE SOFT.
        //
        // IconImage looks like it takes a decode size: it has an `implicitSize`
        // property and every example sets it. Read its source and implicitSize
        // is a default for implicitWidth/implicitHeight and NOTHING else — the
        // decode is driven by
        //
        //     sourceSize.width: Math.min(root.width, root.height)
        //
        // which, under `anchors.fill: parent`, is the item's LOGICAL layout
        // size. So the icon was requested at 52 and painted into 65 device
        // pixels on this 1.25-scale display, no matter what implicitSize said.
        // Two separate attempts to fix the softness by changing implicitSize
        // produced screenshots that were byte-for-byte identical to the ones
        // before them — a +0.0% A/B result that reads as "this is not the
        // cause" when it actually means "this property was never connected to
        // anything".
        //
        // Worse, that binding re-decodes the icon on every frame of a hover,
        // because the item's width IS the magnifying size.
        //
        // A plain Image with an explicit sourceSize fixes both: one decode, at
        // a size we choose, in device pixels.
        Image {
            id: icon
            visible: root.kind === "app" && icon.status === Image.Ready
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            source: root.iconOverride !== "" ? (root.iconOverride.startsWith("/") ? "file://" + root.iconOverride : root.iconOverride) : (root.entry ? Quickshell.iconPath(root.entry.icon, "application-x-executable") : "")
            sourceSize.width: root.decodeSize
            sourceSize.height: root.decodeSize
            asynchronous: true
            smooth: true
        }

        // The folder's own themed icon, resolved and decoded exactly like an
        // app's so it is as sharp as the rest of the row.
        Image {
            id: folderIcon
            visible: root.kind === "folder" && folderIcon.status === Image.Ready
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            // ⚠️ THE `check` OVERLOAD, not the string-fallback one. Asking for
            // a fallback NAME returns a URL either way, and Quickshell's image
            // provider answers a name that resolves to nothing with Qt's
            // magenta checkerboard at status Ready — so the drawn fallback
            // below never gets its turn and the dock displays the missing
            // texture. Passing `true` returns an empty string when the icon
            // genuinely is not there, which is the only answer this can act on.
            source: root.iconOverride !== "" ? (root.iconOverride.startsWith("/") ? "file://" + root.iconOverride : root.iconOverride) : (Quickshell.iconPath(root.folderIconName, true) || Quickshell.iconPath("folder", true))
            sourceSize.width: root.decodeSize
            sourceSize.height: root.decodeSize
            asynchronous: true
            smooth: true
        }

        // The CRT's energy collecting into the line. White, additive-ish, and
        // gone the moment the effect is not running.
        Rectangle {
            anchors.fill: parent
            visible: crt.running
            color: "white"
            opacity: crt.bloom
            radius: parent.width * 0.2237
        }

        // ⚠️ A DRAWN FALLBACK, NOT A COLOURED SQUARE.
        //
        // `folder` and `folder-download` do not resolve here at all: hicolor
        // carries application icons and almost no places icons, and Qt's icon
        // theme name is whatever the platform theme plugin says — which for a
        // bare Quickshell process started from a systemd unit is nothing. The
        // system HAS Papirus with both icons in it; Qt simply never looks
        // there. The log said so plainly:
        //
        //     WARN: Could not load icon "folder?fallback=folder"
        //
        // and Quickshell's provider answers a failed lookup with Qt's magenta
        // missing-texture checkerboard, so the dock shipped a magenta square
        // where the Downloads folder should be.
        //
        // Depending on the host's icon theme for something this central is the
        // wrong trade for a dock that has to look right on every distribution
        // on first run. The theme is tried first and used when it resolves;
        // this is what appears when it does not.
        Item {
            visible: root.kind === "folder" && folderIcon.status !== Image.Ready && folderIcon.status !== Image.Loading
            anchors.fill: parent

            // Two offset tiles, so it reads as a stack of things rather than
            // as a generic icon — which is also what it opens as.
            Squircle {
                x: parent.width * 0.10
                y: parent.height * 0.06
                width: parent.width * 0.80
                height: parent.height * 0.74
                radius: width * 0.2237
                smoothing: 1
                fillColor: "#8e93a8"
                opacity: 0.55
            }
            Squircle {
                x: parent.width * 0.04
                y: parent.height * 0.20
                width: parent.width * 0.92
                height: parent.height * 0.76
                radius: width * 0.2237
                smoothing: 1
                fillColor: "#5b6cc4"
            }
        }

        // 🔴 NO MultiEffect. It used to wrap the icon to add a drop shadow, and
        // it renders its source through an offscreen buffer that does not
        // preserve the device pixel ratio — so every icon in the dock came out
        // resampled. Measured side by side at 3x, Steam's hard-edged logo was
        // visibly mushy while the same icon in a plain window was razor sharp;
        // Firefox survived only because a smooth gradient hides resampling.
        //
        // A decorative shadow is not worth soft icons. This is the single most
        // visible "Linux looks cheap" tell there is, and it is not one this
        // project gets to ship.

        // Fallback for an app with no resolvable icon — a themed tile with its
        // initial. Every dock has this case (a Wayland toplevel whose appId
        // matches no `.desktop` file at all), and an empty gap in the row is
        // both uglier and harder to click than a plain tile.
        Item {
            anchors.fill: parent
            // ⚠️ NOT simply `status !== Ready`. IconImage loads asynchronously,
            // so `Loading` also fails that test and every icon in the dock
            // flashes its letter tile for a beat at startup before the real
            // artwork arrives. It looks like a broken dock that heals itself,
            // and it is purely the fallback being too eager: this is for icons
            // that will never arrive, not for ones still on their way.
            visible: root.kind === "app" && icon.status !== Image.Ready && icon.status !== Image.Loading

            Squircle {
                anchors.fill: parent
                radius: parent.width * 0.2237
                smoothing: 1
                fillColor: Qt.rgba(1, 1, 1, 0.16)
                strokeColor: Qt.rgba(1, 1, 1, 0.22)
                strokeWidth: 1
            }

            Text {
                anchors.centerIn: parent
                text: root.label.length > 0 ? root.label[0].toUpperCase() : "?"
                color: "white"
                font.pixelSize: parent.height * 0.42
                font.bold: true
            }
        }
    }

    // ── Running indicator ───────────────────────────────────────────────
    Rectangle {
        id: dot

        width: root.iconSize * 0.06
        height: width
        radius: width / 2
        color: "white"
        opacity: (root.running && !root.isSeparator) ? 0.85 : 0

        anchors.horizontalCenter: root._horizontal ? iconBox.horizontalCenter : undefined
        anchors.verticalCenter: root._horizontal ? undefined : iconBox.verticalCenter
        anchors.top: root.edge === Qt.BottomEdge ? iconBox.bottom : undefined
        anchors.bottom: root.edge === Qt.TopEdge ? iconBox.top : undefined
        anchors.left: root.edge === Qt.RightEdge ? undefined : (root.edge === Qt.LeftEdge ? iconBox.right : undefined)
        anchors.right: root.edge === Qt.LeftEdge ? undefined : (root.edge === Qt.RightEdge ? iconBox.left : undefined)
        anchors.margins: root.iconSize * 0.05

        Behavior on opacity {
            NumberAnimation {
                duration: 140
            }
        }
    }

    // ── The separator is the resize handle ──────────────────────────────
    //
    // Handlers on the DockItem ROOT, not nested inside iconBox. The whole
    // separator cell is the grab target, which is both far easier to hit than a
    // one-pixel line and free of the nesting that stopped the first attempt
    // receiving any events at all.
    HoverHandler {
        id: sepHover
        enabled: root.isSeparator
        cursorShape: root._horizontal ? Qt.SizeVerCursor : Qt.SizeHorCursor
    }

    DragHandler {
        id: sepDrag
        enabled: root.isSeparator
        target: null
        dragThreshold: 2

        onCentroidChanged: {
            if (!sepDrag.active)
                return;
            // ⚠️ scenePosition, NOT position. The separator MAGNIFIES while
            // being dragged, so its own frame moves under the gesture and a
            // delta measured in it is contaminated by the item growing —
            // measured: dragging up shrank the dock instead of growing it.
            root.separatorMoved(sepDrag.centroid.scenePosition.y, sepDrag.centroid.scenePosition.x);
        }
        onActiveChanged: {
            if (sepDrag.active)
                root.separatorPressed();
            else
                root.separatorReleased();
        }
    }

    // ── Input ───────────────────────────────────────────────────────────
    TapHandler {
        acceptedButtons: Qt.LeftButton
        enabled: !root.isSeparator
        onTapped: root.activated()
        // Long-press is the force-touch stand-in: a trackpad without a
        // pressure sensor reports no force at all under Wayland, so dwell time
        // is the only gesture that means the same thing on every device.
        onLongPressed: root.secondaryRequested(root.x + root.width / 2, root.y)
        longPressThreshold: 0.4
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        enabled: !root.isSeparator
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.secondaryRequested(root.x + root.width / 2, root.y)
    }

    // ── Drag to reorder ─────────────────────────────────────────────────
    //
    // A threshold, not an immediate grab. Every click on a dock icon moves the
    // pointer by a pixel or two, and a drag that starts on the first such
    // movement makes single clicks intermittently fail to launch anything —
    // the most infuriating possible bug in a launcher, because it works most
    // of the time.
    DragHandler {
        id: dragger
        enabled: !root.isSeparator
        target: null
        dragThreshold: 8

        onActiveChanged: {
            if (dragger.active) {
                root.dragStarted();
            } else {
                root.dragOffset = Qt.point(0, 0);
                root.dragEnded();
            }
        }

        onCentroidChanged: {
            if (!dragger.active)
                return;
            // Report in the DOCK's coordinate space. The item's own frame moves
            // as the row re-lays-out underneath the drag, so a position
            // measured in it chases itself.
            const p = dragger.centroid.position;
            const q = dragger.centroid.pressPosition;
            root.dragOffset = Qt.point(p.x - q.x, p.y - q.y);
            const sp = dragger.centroid.scenePosition;
            root.dragMoved(root._horizontal ? sp.x : sp.y, root._horizontal ? sp.y : sp.x);
        }
    }
}
