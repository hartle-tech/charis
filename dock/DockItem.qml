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

        Snapped to the freedesktop ladder rather than left as an odd number,
        because a theme stores 48/64/128/256 and asking for 124 makes Qt take
        the 128 and rescale it. Asking for 128 uses it as authored.
    */
    readonly property int decodeSize: {
        const want = root.maxIconSize * Math.max(1, Screen.devicePixelRatio);
        for (const s of [32, 48, 64, 96, 128, 256, 512])
            if (s >= want)
                return s;
        return 512;
    }

    /*! Which screen edge the dock is on — decides where the dot goes. */
    required property int edge

    /*! Used when no `.desktop` entry matched — normally the toplevel's appId. */
    property string fallbackLabel: ""

    /*! "app", "folder" or "separator". */
    property string kind: "app"

    /*! Absolute path, for kind == "folder". */
    property string folder: ""

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

        `axisPos` is along the row in the DOCK's coordinates, because the caller
        reorders in row space. `crossPos` is perpendicular and deliberately in
        THIS ITEM's own frame — how far the pointer is from the item's top edge.

        ⚠️ Mixing the two frames is a real bug that shipped for one round. The
        surface grows while a drag is active (so the pointer keeps producing
        motion events after it leaves the dock), which moves `content`, which
        moves the item — so a cross position expressed in surface coordinates
        JUMPS the instant the drag starts. The jump exceeded the tear-off
        threshold, and dragging an icon sideways to reorder it silently deleted
        it instead. A local frame cannot shift underneath the gesture.
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

    readonly property bool _horizontal: root.edge === Qt.BottomEdge || root.edge === Qt.TopEdge

    // ── Launch bounce ───────────────────────────────────────────────────
    //
    // A bounce IS a spring with an impulse, so this is the library's own
    // primitive rather than a bespoke animation: give it velocity and let the
    // physics do the arc. Under-damped, so it oscillates instead of gliding
    // back, which is what makes it read as bouncing.
    //
    // The value is clamped to the upward half. An unclamped oscillator swings
    // symmetrically and the icon would sink THROUGH the dock floor on every
    // other half-cycle; macOS's icon hops and lands, it never dips.
    Spring {
        id: bounce
        response: 0.34
        damping: 0.30
        epsilon: 0.05
    }

    Timer {
        id: bouncer
        interval: 560
        repeat: true
        running: root.launching
        triggeredOnStart: true
        onTriggered: bounce.impulse(-240)
    }

    // Stop bouncing whether or not the app ever appeared. An app that fails to
    // start would otherwise bounce for ever, which is worse than no feedback:
    // it says "still working" indefinitely.
    Timer {
        interval: 12000
        running: root.launching
        onTriggered: root.launching = false
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

    readonly property real _lift: Math.max(0, -bounce.value) + tearLift.value

    // The dragged icon's displacement. Very fast while held — it must feel
    // glued to the pointer — and slower on release so it eases home.
    Spring {
        id: fx
        target: root.dragOffset.x
        response: dragger.active ? 0.045 : 0.34
        damping: dragger.active ? 1.0 : 0.7
        epsilon: 0.05
    }
    Spring {
        id: fy
        target: root.dragOffset.y
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
        opacity: tearFade.value

        // ⚠️ A TRANSFORM, NOT x/y. iconBox is positioned by anchors, and in QML
        // anchors silently win over an x/y assignment — so the drag-follow was
        // written, deployed, and did absolutely nothing, with no warning. This
        // is the second time the same rule has bitten in this file.
        transform: Translate {
            x: fx.value
            y: fy.value
        }

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
        Rectangle {
            id: sep
            visible: root.isSeparator
            anchors.centerIn: parent
            width: sepHover.hovered || sepDrag.active ? 2 : 1
            height: parent.height * (sepHover.hovered || sepDrag.active ? 0.78 : 0.62)
            radius: 1
            color: Qt.rgba(1, 1, 1, sepHover.hovered || sepDrag.active ? 0.55 : 0.22)

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

        IconImage {
            id: icon
            visible: root.kind === "app" && icon.status === Image.Ready
            anchors.fill: parent
            source: root.iconOverride !== "" ? (root.iconOverride.startsWith("/") ? "file://" + root.iconOverride : root.iconOverride) : (root.entry ? Quickshell.iconPath(root.entry.icon, "application-x-executable") : "")
            implicitSize: root.decodeSize
            smooth: true
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
            root.dragMoved(root._horizontal ? root.x + p.x : root.y + p.y, root._horizontal ? p.y : p.x);
        }
    }
}
