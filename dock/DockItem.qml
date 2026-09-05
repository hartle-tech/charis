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

    /*! Which screen edge the dock is on — decides where the dot goes. */
    required property int edge

    /*! Used when no `.desktop` entry matched — normally the toplevel's appId. */
    property string fallbackLabel: ""

    /*! "app", "folder" or "separator". */
    property string kind: "app"

    /*! Absolute path, for kind == "folder". */
    property string folder: ""

    readonly property bool isSeparator: root.kind === "separator"

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

    /*! Emitted while this icon is being dragged. `axisPos` is along the row and
        `crossPos` is perpendicular to it, both in the DOCK's coordinates — the
        caller works in row space, not in this item's, which moves underneath
        the drag as the row re-lays-out. */
    signal dragMoved(real axisPos, real crossPos)
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

    Item {
        id: iconBox

        width: root.iconSize
        height: root.iconSize
        opacity: tearFade.value

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
        // move around it.
        Rectangle {
            visible: root.isSeparator
            anchors.centerIn: parent
            width: 1
            height: parent.height * 0.62
            color: Qt.rgba(1, 1, 1, 0.22)
        }

        IconImage {
            id: icon
            visible: false
            anchors.fill: parent
            source: root.entry ? Quickshell.iconPath(root.entry.icon, "application-x-executable") : ""
            implicitSize: Math.ceil(root.maxIconSize)
            smooth: true
        }

        Squircle {
            id: mask
            anchors.fill: parent
            radius: parent.width * 0.2237   // Apple's icon-grid corner ratio
            smoothing: 1
            fillColor: "white"
            visible: false
            layer.enabled: true
        }

        // Most app icons already carry their own silhouette, so masking every
        // one would clip logos that are deliberately not square. The mask is
        // applied only where it helps: nothing here forces a shape onto an
        // icon that already has one.
        //
        // ⚠️ GUARDED ON A NON-EMPTY SOURCE. A MultiEffect whose source has no
        // texture does not draw nothing — it draws Qt's magenta-and-black
        // "missing texture" checkerboard, at full size, in the middle of the
        // dock. That is how an unset XDG_DATA_DIRS first showed up here: every
        // DesktopEntry lookup returned null, so every icon path was empty, and
        // the only visible result was one checkerboard where an icon should
        // have been.
        FolderIcon {
            anchors.fill: parent
            visible: root.kind === "folder"
            // A folder's tint comes from its name, so Downloads and Pictures
            // are told apart at a glance without anyone configuring colours,
            // and deterministically, so it keeps that colour between sessions.
            tint: {
                let h = 0;
                for (let i = 0; i < root.label.length; i++)
                    h = (h * 31 + root.label.charCodeAt(i)) & 0xffff;
                return Qt.hsla((h % 360) / 360, 0.45, 0.62, 1);
            }
        }

        MultiEffect {
            anchors.fill: parent
            source: icon
            visible: root.kind === "app" && icon.status === Image.Ready
            maskEnabled: false
            // Shadows are the first thing to go when the machine is busy —
            // they are pure decoration and the most expensive per pixel.
            shadowEnabled: FrameBudget.quality > 0.4
            shadowBlur: 0.6
            shadowVerticalOffset: root.iconSize * 0.04
            shadowOpacity: 0.35 * FrameBudget.quality
        }

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
            if (dragger.active)
                root.dragStarted();
            else
                root.dragEnded();
        }

        onCentroidChanged: {
            if (!dragger.active)
                return;
            // Report in the DOCK's coordinate space. The item's own frame moves
            // as the row re-lays-out underneath the drag, so a position
            // measured in it chases itself.
            const p = dragger.centroid.position;
            root.dragMoved(root._horizontal ? root.x + p.x : root.y + p.y, root._horizontal ? root.y + p.y : root.x + p.x);
        }
    }
}
