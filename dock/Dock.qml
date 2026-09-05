pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Charis

/*!
    The dock surface: one layer-shell panel per screen.

    \section2 The magnification, and why there are only two springs

    The obvious construction gives every icon its own scale spring and points
    each at a value derived from the cursor. It produces forty springs, forty
    subscriptions, and — because each settles on its own schedule — forty
    icons that are *individually* smooth and *collectively* soupy. The wave
    reads as a crowd rather than a ripple.

    Every icon's scale is in fact a pure function of one number: where the
    cursor is along the dock. So this smooths THAT — one spring for the
    cursor, one for how magnified the dock is at all — and derives all N
    scales and positions from the pair, declaratively. Two springs for any
    number of icons, perfectly in phase by construction, and the whole row
    re-lays-out from a single property change.

    \section2 Rest positions, deliberately

    The distance from cursor to icon is measured against each icon's RESTING
    centre, not its magnified one. Using the live position is a feedback loop —
    the icon grows, which moves its centre, which changes its distance, which
    changes how much it grows — and it oscillates around the cursor. Measuring
    against rest positions is stable by construction and is what Plank and
    Latte both settled on.
*/
PanelWindow {
    id: root

    /*! Which screen edge to sit on. */
    property int edge: Qt.BottomEdge

    /*! Icon size at rest. */
    property real baseIconSize: 48

    /*! How much the icon directly under the cursor grows. */
    property real magnification: 1.9

    /*! How far the magnification reaches, in resting cells. */
    property real influenceCells: 2.6

    /*! Gap between icons at rest. */
    property real spacing: 8

    /*! Pinned desktop-entry ids, in order. */
    property var pinned: []

    /*! Absolute folder paths, shown after a separator as macOS-style stacks. */
    property var folders: []

    /*! Hide until the pointer reaches the screen edge. */
    property bool autoHide: true

    property color panelColor: "#1e1e1e"
    property real panelOpacity: 0.55

    /*!
        Pin the magnification to a fixed position along the dock, as if the
        pointer were parked there. Negative disables it.

        A development affordance, and deliberately a supported one. A hover
        state cannot be screenshotted without a pointer, and this machine has
        no cursor-warping tool — Hyprland's own dispatcher reports success and
        moves nothing. Without this, the single most important visual property
        of the whole component is unverifiable except by a person putting their
        hand on the mouse, which is exactly the "ask the operator for a
        screenshot" loop this project does not do.
    */
    property real debugCursor: -1

    /*! Folder path to show as an open stack, driven externally (see the
        IpcHandler in shell.qml). Empty closes it. */
    property string stackRequest: ""

    /*! Bumped by the caller on every request. Needed because asking twice for
        the SAME folder must re-open it — a plain string property does not
        change, so nothing would happen the second time. */
    property int stackSerial: 0

    readonly property bool horizontal: root.edge === Qt.BottomEdge || root.edge === Qt.TopEdge
    readonly property real maxIconSize: root.baseIconSize * root.magnification
    readonly property real cell: root.baseIconSize + root.spacing

    // ── Model ───────────────────────────────────────────────────────────
    // Pinned entries first, in the order the user put them, then anything
    // running that is not pinned. That is Apple's rule and it is the right one:
    // a pinned icon must never move because an unrelated app opened.
    readonly property var items: {
        const byApp = {};
        const norm = s => (s || "").toLowerCase().replace(/\.desktop$/, "");

        for (const tl of ToplevelManager.toplevels.values) {
            const k = norm(tl.appId);
            if (!byApp[k])
                byApp[k] = [];
            byApp[k].push(tl);
        }

        const out = [];
        const taken = {};

        for (const id of root.pinned) {
            const entry = DesktopEntries.byId(id) ?? null;
            // Match on the entry's own id AND on StartupWMClass: an app whose
            // .desktop is `org.gnome.Loupe` can perfectly well set appId to
            // `loupe`, and matching only one of the two leaves a running app
            // with a dead pinned icon beside a duplicate live one.
            const keys = [norm(id)];
            if (entry) {
                keys.push(norm(entry.id));
                if (entry.startupClass)
                    keys.push(norm(entry.startupClass));
            }
            let tls = [];
            for (const k of keys) {
                if (byApp[k]) {
                    tls = tls.concat(byApp[k]);
                    taken[k] = true;
                }
            }
            out.push({
                entry: entry,
                toplevels: tls,
                kind: "app",
                pinned: true,
                key: norm(id)
            });
        }

        for (const k in byApp) {
            if (taken[k])
                continue;
            out.push({
                entry: DesktopEntries.byId(k) ?? null,
                toplevels: byApp[k],
                kind: "app",
                pinned: false,
                key: k
            });
        }

        // Folders live to the right of everything, behind a separator, exactly
        // as on macOS. The separator is a real row entry rather than a drawn
        // decoration so it participates in the magnification and shifts with
        // the icons instead of sitting still while they move around it.
        if (root.folders.length > 0) {
            out.push({
                kind: "separator",
                toplevels: [],
                entry: null,
                key: "__sep"
            });
            for (const path of root.folders)
                out.push({
                    kind: "folder",
                    folder: path,
                    // The basename, so the stack reads "Downloads" rather than
                    // "folder:/home/user/Downloads".
                    label: path.split("/").filter(x => x).pop() ?? path,
                    entry: null,
                    toplevels: [],
                    pinned: true,
                    key: `folder:${path}`
                });
        }
        return out;
    }

    readonly property int count: root.items.length

    // ── Geometry ────────────────────────────────────────────────────────
    // Everything below is a pure function of `cursor.value` and `magnify.value`.

    Spring {
        id: cursor
        // Short and critically damped: magnification must feel like it is
        // attached to the pointer, not chasing it. Anything slower than ~0.12s
        // reads as lag rather than as smoothing.
        response: 0.12
        damping: 1.0
        epsilon: 0.25
    }

    readonly property bool debugging: root.debugCursor >= 0

    Spring {
        id: magnify
        target: (hover.hovered || root.debugging) ? 1 : 0
        response: 0.28
        damping: 1.0
    }

    Spring {
        id: reveal
        // 1 = fully out, 0 = tucked away. Slightly under-damped so the dock
        // arrives with a hint of settle instead of stopping dead.
        target: (!root.autoHide || hover.hovered || root.debugging) ? 1 : 0
        response: 0.42
        damping: 0.82
    }

    MagnifiedRow {
        id: row
        count: root.count
        itemSize: root.baseIconSize
        spacing: root.spacing
        axisLength: root.horizontal ? root.width : root.height
        pointer: root.debugging ? root.debugCursor : cursor.value
        magnification: root.magnification
        influenceCells: root.influenceCells
        amount: magnify.value
    }

    readonly property var layout: row.metrics

    // ── Surface ─────────────────────────────────────────────────────────
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "charis-dock"
    // The dock must never take keyboard focus. A layer surface that does
    // steals input from whatever the person was typing into the moment the
    // pointer crosses it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Auto-hide means claiming no space. Reserving an exclusive zone AND
    // hiding gives the worst of both: a permanent gap with nothing in it.
    exclusionMode: root.autoHide ? ExclusionMode.Ignore : ExclusionMode.Auto

    anchors {
        bottom: root.edge === Qt.BottomEdge
        top: root.edge === Qt.TopEdge
        left: root.edge === Qt.LeftEdge || root.horizontal
        right: root.edge === Qt.RightEdge || root.horizontal
    }

    // ── Surface size, and why it is far bigger than the dock ────────────
    //
    // A menu or a stack opens ABOVE the dock. A layer surface clips its own
    // contents, so on a surface only as tall as the dock those popups render
    // outside it and are simply never seen — the IPC call succeeds, the item
    // is `visible: true`, and nothing appears. That cost a debugging round
    // here, because every piece of state says the popup is open.
    //
    // So the surface reserves room for popups, and an input MASK is used to
    // give back the space they are not using. Without the mask a transparent
    // 500px-tall surface across the bottom of the screen would swallow every
    // click in the lower third of the desktop, which is a far worse bug than
    // the one being fixed.
    readonly property real bandThickness: root.maxIconSize + root.spacing * 3

    // Exactly the dock at rest; exactly the dock plus the popup while one is
    // open. Two resizes per open/close cycle, because `popupExtent` is gated on
    // the popup's boolean visibility rather than on its animating scale.
    //
    // Growing on demand rather than reserving a permanent 460px strip is the
    // safer construction: a tall transparent surface that is even slightly
    // wrong about its input mask swallows every click in the lower third of the
    // desktop, and that failure is much worse — and much harder to attribute —
    // than the clipped popup it was fixing. The mask below is still set, so the
    // two mechanisms have to BOTH fail for input to be stolen.
    //
    // ⚠️ The usual objection to resizing a layer surface does not apply here.
    // That rule is about resizing every FRAME of a magnification, which
    // renegotiates with the compositor sixty times a second; this is once per
    // menu.
    readonly property real liveExtent: root.bandThickness + Math.max(stack.popupExtent, menu.popupExtent)

    implicitHeight: root.horizontal ? root.liveExtent : 0
    implicitWidth: root.horizontal ? 0 : root.liveExtent

    mask: Region {
        x: root.horizontal ? 0 : (root.edge === Qt.LeftEdge ? 0 : root.width - root.liveExtent)
        y: root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - root.liveExtent : 0) : 0
        width: root.horizontal ? root.width : root.liveExtent
        height: root.horizontal ? root.liveExtent : root.height
    }

    color: "transparent"

    HoverHandler {
        id: hover
        onPointChanged: {
            const p = hover.point.position;
            cursor.target = root.horizontal ? p.x : p.y;
        }
        onHoveredChanged: {
            if (!hover.hovered)
                return;
            // Enter the row without a swipe across it. Without this the cursor
            // spring starts from wherever it was left last time and the whole
            // dock visibly ripples on entry.
            const p = hover.point.position;
            cursor.reset(root.horizontal ? p.x : p.y);
        }
    }

    Item {
        id: content

        // ⚠️ NOT `anchors.fill: parent`. Filling sets x and y, so the slide
        // below would be silently overridden and the dock would never come
        // out of hiding — with no warning, because anchors simply win.
        //
        // Nor does it fill: the surface reserves room for popups above the
        // dock, so the band occupies only `bandThickness` at the screen edge.
        width: root.horizontal ? parent.width : root.bandThickness
        height: root.horizontal ? root.bandThickness : parent.height

        // Slide out of the screen edge when hidden, leaving a sliver to catch
        // the pointer on.
        readonly property real hidden: root.bandThickness - 3
        readonly property real bandOrigin: root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - root.bandThickness : 0) : 0
        readonly property real bandOriginX: root.horizontal ? 0 : (root.edge === Qt.RightEdge ? root.width - root.bandThickness : 0)

        y: content.bandOrigin + (root.edge === Qt.BottomEdge ? (1 - reveal.value) * content.hidden : (root.edge === Qt.TopEdge ? -(1 - reveal.value) * content.hidden : 0))
        x: content.bandOriginX + (root.edge === Qt.RightEdge ? (1 - reveal.value) * content.hidden : (root.edge === Qt.LeftEdge ? -(1 - reveal.value) * content.hidden : 0))

        // ── Where the icon row rests ────────────────────────────────────
        //
        // The panel is sized for the LARGEST the dock ever gets, so the row
        // cannot simply be centred in it: at rest the icons would float in the
        // middle of a mostly-empty surface, and the background — sized to the
        // resting icons — would sit somewhere else entirely. Both are pinned
        // to the same computed baseline instead.
        //
        // Icons grow UP from that baseline rather than about their centre,
        // which is what keeps a magnified icon from sinking into the screen
        // edge. The background stays at rest size while they do, so the icons
        // rise out of it exactly as Apple's do.
        readonly property real bgPad: root.spacing * 1.5
        readonly property real edgeGap: root.spacing
        readonly property real band: root.baseIconSize + content.bgPad * 2
        readonly property real thick: root.bandThickness
        readonly property real bandStart: content.thick - content.edgeGap - content.band

        Squircle {
            id: bg

            width: root.horizontal ? root.layout.total + content.bgPad * 2 : content.band
            height: root.horizontal ? content.band : root.layout.total + content.bgPad * 2

            x: root.horizontal ? (content.width - width) / 2 : (root.edge === Qt.LeftEdge ? content.edgeGap : content.bandStart)
            y: root.horizontal ? (root.edge === Qt.BottomEdge ? content.bandStart : content.edgeGap) : (content.height - height) / 2

            radius: Math.min(width, height) * 0.28
            smoothing: 1
            fillColor: Qt.rgba(root.panelColor.r, root.panelColor.g, root.panelColor.b, root.panelOpacity)
            strokeColor: Qt.rgba(1, 1, 1, 0.10)
            strokeWidth: 1
            opacity: reveal.value
        }

        Repeater {
            model: root.items

            DockItem {
                id: item

                required property int index
                required property var modelData

                maxIconSize: root.maxIconSize
                entry: item.modelData.entry
                kind: item.modelData.kind ?? "app"
                folder: item.modelData.folder ?? ""
                fallbackLabel: item.modelData.label ?? item.modelData.key
                toplevels: item.modelData.toplevels
                iconSize: root.layout.sizes[item.index] ?? root.baseIconSize
                edge: root.edge

                // Dim the icon being dragged so the gap it leaves reads as a
                // hole it came out of, rather than as the row having lost one.
                opacity: drag.active && drag.fromIndex === item.index ? 0.35 : 1

                // The item spans from the surface edge down to the row's
                // baseline; DockItem anchors its icon to whichever end faces
                // the screen edge, so the icon rests on the baseline and grows
                // away from it.
                x: root.horizontal ? (root.layout.offsets[item.index] ?? 0) : (root.edge === Qt.LeftEdge ? content.edgeGap + content.bgPad : 0)
                y: root.horizontal ? (root.edge === Qt.BottomEdge ? 0 : content.edgeGap + content.bgPad) : (root.layout.offsets[item.index] ?? 0)
                width: root.horizontal ? item.iconSize : content.thick - content.edgeGap - content.bgPad
                height: root.horizontal ? content.thick - content.edgeGap - content.bgPad : item.iconSize

                onActivated: {
                    if (item.modelData.kind === "folder") {
                        stack.toggleFor(item.modelData.folder, item.x + item.width / 2);
                        return;
                    }
                    if (item.modelData.kind === "separator")
                        return;

                    const tls = item.modelData.toplevels;
                    if (tls.length === 0) {
                        if (item.modelData.entry)
                            item.modelData.entry.execute();
                        return;
                    }
                    // Clicking a running app's icon focuses it; clicking the
                    // one already focused hides it again. That toggle is what
                    // makes a dock a switcher rather than a launcher.
                    const active = tls.find(t => t.activated);
                    if (active && tls.length === 1)
                        active.minimized = true;
                    else
                        (active ? tls[(tls.indexOf(active) + 1) % tls.length] : tls[0]).activate();
                }

                onSecondaryRequested: (mx, my) => menu.openFor(item.modelData, mx)

                onDragStarted: {
                    // Only pinned apps reorder. Dragging a running-but-unpinned
                    // icon around would imply an order that vanishes the moment
                    // the app quits, and dragging the separator is meaningless.
                    if (item.modelData.kind !== "app" || !item.modelData.pinned)
                        return;
                    drag.fromIndex = item.index;
                    drag.toIndex = item.index;
                    drag.active = true;
                }
                onDragMoved: axisPos => {
                    if (drag.active)
                        drag.toIndex = root.indexNear(axisPos);
                }
                onDragEnded: drag.commit()
            }
        }
    }

    // ── Reordering ──────────────────────────────────────────────────────
    QtObject {
        id: drag

        property bool active: false
        property int fromIndex: -1
        property int toIndex: -1

        function commit(): void {
            if (!drag.active) {
                drag.reset();
                return;
            }
            const from = drag.fromIndex;
            const to = drag.toIndex;
            drag.reset();
            if (from === to || from < 0 || to < 0)
                return;

            const next = root.pinned.slice();
            const [moved] = next.splice(from, 1);
            next.splice(to, 0, moved);
            // The dock does not own the config — it asks. Whoever supplied
            // `pinned` decides whether to persist it, which is what keeps this
            // component usable with a config file, a settings UI, or a caller
            // that hard-codes the list.
            root.pinnedReordered(next);
        }

        function reset(): void {
            drag.active = false;
            drag.fromIndex = -1;
            drag.toIndex = -1;
        }
    }

    /*! Emitted with the new pinned order after a drag. */
    signal pinnedReordered(var order)

    /*! Emitted when files are dropped on the dock background rather than on an
        icon — the caller decides whether that means "pin this folder". */
    signal urlsDropped(var urls, int index)

    /*! Index of the pinned slot nearest \a axisPos, clamped to the pinned run. */
    function indexNear(axisPos: real): int {
        let best = 0;
        let bestD = Infinity;
        const pinnedCount = root.pinned.length;
        for (let i = 0; i < pinnedCount; i++) {
            const d = Math.abs(row.restCentre(i) - axisPos);
            if (d < bestD) {
                bestD = d;
                best = i;
            }
        }
        return best;
    }

    // ── Drag and drop from outside ──────────────────────────────────────
    //
    // Dropping a file on an app icon opens it with that app; dropping a folder
    // on the dock pins it as a stack. Both are things people try on a dock
    // without being told to, and a dock that ignores a drop feels broken in a
    // way that is hard to articulate.
    DropArea {
        anchors.fill: parent

        onEntered: dropHover.target = 1
        onExited: dropHover.target = 0

        onDropped: event => {
            dropHover.target = 0;
            if (!event.hasUrls)
                return;

            const axis = root.horizontal ? event.x : event.y;
            const idx = root.indexNear(axis);
            const onIcon = Math.abs(row.restCentre(idx) - axis) < root.baseIconSize / 2;
            const target = onIcon ? root.items[idx] : null;

            if (target && target.kind === "app" && target.entry) {
                // Hand the files to the app rather than to xdg-open, which is
                // the entire point of dropping them on a specific icon.
                const paths = event.urls.map(u => u.toString().replace(/^file:\/\//, ""));
                Quickshell.execDetached([target.entry.execString.split(" ")[0]].concat(paths));
                event.accept();
                return;
            }

            root.urlsDropped(event.urls.map(u => u.toString()), idx);
            event.accept();
        }
    }

    Spring {
        id: dropHover
        response: 0.3
        damping: 0.9
    }

    DockStack {
        id: stack

        property string current: ""

        function toggleFor(path: string, pos: real): void {
            if (stack.current === path && stack.open) {
                stack.open = false;
                stack.current = "";
                return;
            }
            stack.current = path;
            stack.anchorPos = pos;
            stack.open = true;
        }

        anchors.fill: parent
        folder: stack.current
        edge: root.edge
        bandOffset: root.bandThickness

        Connections {
            target: root
            function onStackSerialChanged() {
                if (root.stackRequest === "") {
                    stack.open = false;
                    stack.current = "";
                    return;
                }
                const i = root.items.findIndex(it => it.kind === "folder" && it.folder === root.stackRequest);
                stack.current = root.stackRequest;
                stack.anchorPos = i >= 0 ? row.restCentre(i) : root.width / 2;
                stack.open = true;
            }
        }

        onRequestClose: {
            stack.open = false;
            stack.current = "";
        }
    }

    DockMenu {
        id: menu
        edge: root.edge
        anchors.fill: parent
        bandOffset: root.bandThickness
        revealed: reveal.value
    }
}
