pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Charis

/*!
    The long-press / right-click menu for a dock icon.

    Its contents are not invented here. Every `.desktop` file may declare
    ACTIONS — "New Window", "New Private Window", "Compose Message" — and
    almost nothing on Linux surfaces them, which is why the equivalent menu on
    macOS feels richer than the one most Linux docks show. \c DesktopEntry
    exposes them as \c actions, so the useful half of this menu costs nothing
    to build and is correct for every app that bothered to declare them.
*/
Item {
    id: root

    property int edge: Qt.BottomEdge

    /*! Distance from this item's edge-facing side to where the dock band
        starts. Popups anchor against the BAND, not against the surface, because
        the surface is deliberately much bigger than the dock (see Dock.mask). */
    property real bandOffset: 0

    /*! How much room this popup needs beyond the band — read by Dock to size
        its input mask. Zero when closed. */
    readonly property real popupExtent: popup.visible ? (root.horizontal ? popup.height : popup.width) + 14 : 0
    property real revealed: 1

    property var app: null
    property real anchorPos: 0

    readonly property bool open: root.app !== null
    readonly property bool horizontal: root.edge === Qt.BottomEdge || root.edge === Qt.TopEdge

    function openFor(app: var, pos: real): void {
        root.app = app;
        root.anchorPos = pos;
    }

    function close(): void {
        root.app = null;
    }

    readonly property var entries: {
        if (!root.app)
            return [];
        const out = [];
        const e = root.app.entry;
        const tls = root.app.toplevels;

        if (e && e.actions)
            for (const a of e.actions)
                out.push({
                    label: a.name,
                    kind: "action",
                    action: a
                });

        if (e)
            out.push({
                label: tls.length > 0 ? "New Window" : "Open",
                kind: "launch"
            });

        // One entry per window when there are several, so the menu doubles as
        // a window list — the thing people actually reach a dock icon for once
        // an app has four documents open.
        if (tls.length > 1)
            for (const t of tls)
                out.push({
                    label: t.title || "Window",
                    kind: "focus",
                    toplevel: t
                });

        if (tls.length > 0)
            out.push({
                label: tls.length > 1 ? "Quit All" : "Quit",
                kind: "quit"
            });

        return out;
    }

    function invoke(item: var): void {
        if (item.kind === "action")
            item.action.execute();
        else if (item.kind === "launch" && root.app.entry)
            root.app.entry.execute();
        else if (item.kind === "focus")
            item.toplevel.activate();
        else if (item.kind === "quit")
            for (const t of root.app.toplevels)
                t.close();
        root.close();
    }

    // A full-surface catcher so a click anywhere else dismisses the menu.
    // Without one the menu can only be closed by choosing something, which is
    // the most irritating possible way for a menu to behave.
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onPressed: root.close()
        z: -1
    }

    Spring {
        id: grow
        target: root.open ? 1 : 0
        response: 0.3
        damping: 0.78
    }

    Item {
        id: popup

        readonly property real pad: 8
        readonly property real rowH: 28

        width: Math.max(160, metrics.maxWidth + popup.pad * 4)
        height: root.entries.length * popup.rowH + popup.pad * 2
        visible: grow.value > 0.001

        x: root.horizontal ? Math.max(4, Math.min(root.width - popup.width - 4, root.anchorPos - popup.width / 2)) : (root.edge === Qt.LeftEdge ? root.bandOffset + 8 : root.width - root.bandOffset - popup.width - 8)
        y: root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - root.bandOffset - popup.height - 8 : root.bandOffset + 8) : Math.max(4, Math.min(root.height - popup.height - 4, root.anchorPos - popup.height / 2))

        // Grow from the icon it belongs to rather than fading in place, so the
        // menu visibly comes FROM the thing that was pressed.
        transform: Scale {
            origin.x: popup.width / 2
            origin.y: root.edge === Qt.BottomEdge ? popup.height : 0
            xScale: 0.86 + 0.14 * grow.value
            yScale: 0.86 + 0.14 * grow.value
        }
        opacity: grow.value

        TextMetrics {
            id: metrics
            property real maxWidth: {
                let w = 0;
                for (const e of root.entries)
                    w = Math.max(w, e.label.length * 7);
                return w;
            }
        }

        Squircle {
            anchors.fill: parent
            radius: 12
            smoothing: 1
            fillColor: Qt.rgba(0.11, 0.11, 0.12, 0.96)
            strokeColor: Qt.rgba(1, 1, 1, 0.12)
            strokeWidth: 1
        }

        Column {
            anchors.fill: parent
            anchors.margins: popup.pad

            Repeater {
                model: root.entries

                Item {
                    id: row
                    required property var modelData
                    width: popup.width - popup.pad * 2
                    height: popup.rowH

                    Squircle {
                        anchors.fill: parent
                        radius: 7
                        smoothing: 1
                        fillColor: rowHover.hovered ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        elide: Text.ElideRight
                        color: "white"
                        font.pixelSize: 13
                        text: row.modelData.label
                    }

                    HoverHandler {
                        id: rowHover
                    }
                    TapHandler {
                        onTapped: root.invoke(row.modelData)
                    }
                }
            }
        }
    }
}
