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

    /*! Icon size at rest, as CONFIGURED. Read \l baseIconSize for the value
        the dock actually uses. */
    property real iconSize: 48

    /*!
        The smallest and largest icon this dock will accept.

        🔴 NOTHING CLAMPED THE CONFIGURED SIZE. The two drag handlers each
        carried their own literal `Math.max(24, Math.min(128, …))`, so the
        GESTURES were bounded and every other route in was not: a hand-edited
        config, the settings slider, the aphrOS configurator, or a stale file
        could ask for 4 or 4000 and the dock would try. At 4 the icons are
        smaller than their own running indicator; at 4000 the band is taller
        than the display, the exclusive zone swallows the desktop and the
        surface is placed off the top of the screen — which this project has
        already had once, from a resize that reached 131 on a 1152-tall output.

        The maximum is a fraction of the OUTPUT, not a constant, because
        "ridiculous" is a statement about the screen: 128px is a big dock on
        this ultrawide and would be most of a netbook's height.
    */
    readonly property real minIconSize: 32
    readonly property real maxIconSizeAllowed: Math.max(root.minIconSize + 8, Math.min(128, Math.round(root.travelExtent * 0.12)))

    /*! The size in force: what was asked for, brought inside the limits. */
    readonly property real baseIconSize: Math.max(root.minIconSize, Math.min(root.maxIconSizeAllowed, root.iconSize))

    /*! How much the icon directly under the cursor grows. */
    property real magnification: 1.9

    /*! Whether the row magnifies at all. macOS puts this on a checkbox next to
        the size slider, and plenty of people turn it off — a dock whose icons
        move under the pointer is exactly what some people do not want. Kept
        separate from \l magnification so switching it back on restores the
        amount they had chosen rather than resetting it to 1. */
    property bool magnify: true

    /*!
        Padding between the icons and the outside of the dock's background.

        🔴 IT WAS DERIVED FROM THE ICON SPACING, and those are different
        things. `spacing * 1.5` gave six pixels around a 128px icon — the
        artwork ran almost to the panel's edge, which is the single most
        obvious way this dock did not look like the one it is modelled on.
        macOS keeps roughly a tenth of an icon of air on every side, and it
        does not shrink when you tighten the gaps BETWEEN icons.

        Negative means "derive it", so an existing config keeps working and a
        person who wants it tighter can still say so.
    */
    property real iconPadding: -1

    /*! How far the magnification reaches, in resting cells. */
    property real influenceCells: 2.6

    /*! Gap between icons at rest. */
    property real spacing: 8

    /*! Pinned desktop-entry ids, in order. */
    property var pinned: []

    /*! Absolute folder paths, shown after a separator as macOS-style stacks. */
    property var folders: []

    /*! A fixed file-manager slot at the head of the row, like Finder's. */
    property bool showLauncher: true

    /*! Which icon that slot wears. */
    property string launcherIcon: "system-file-manager"

    /*! Folders the launcher's menu offers to reopen, most recent first. */
    property var recentFolders: []

    /*! The launcher was clicked, or one of its menu entries chosen. */
    signal launcherActivated
    signal launcherAction(string action, string path)

    /*! Hide until the pointer reaches the screen edge. */
    property bool autoHide: true

    property color panelColor: "#1e1e1e"
    property real panelOpacity: 0.55

    /*! Corner radius of the dock background, as a fraction of its thickness.
        0.5 is a full pill; macOS sits near 0.28. */
    property real cornerRoundness: 0.28

    /*! Border colour and width of the dock background. */
    property color borderColor: "#1affffff"
    property real borderWidth: 1

    /*! Use the refracting Glass material for the background instead of flat
        translucency.

        🔴 THIS TOGGLE RENDERED NOTHING FOR AS LONG AS IT EXISTED. The Glass
        item's `visible` was `useGlass && backdrop !== null`, and NOTHING EVER
        ASSIGNED `backdrop`. Flipping the switch in the settings panel changed
        0.0 pixels — measured, mean absolute difference across the whole panel
        region between glass on and glass off, twice. The shader was written,
        the shader was correct, the shader had no source item and therefore no
        turn to draw. "No proper liquid glass" was exactly right.

        The fix is not a wire, it is understanding what is behind a dock. A
        layer surface cannot sample the windows below it, which is why this sat
        unfinished. But this dock reserves an exclusive zone: **no window can
        ever be behind it.** The only thing there is the wallpaper. So the
        wallpaper IS the backdrop, completely and not approximately, and
        refracting it is not a cheat standing in for the real thing — for a
        dock anchored to a screen edge it is the real thing. */
    property bool useGlass: false

    /*! An explicit backdrop, if the embedder has something better than the
        wallpaper — a floating dock over a canvas, say. Left null, the dock
        makes its own from \l wallpaper. */
    property Item backdrop: null

    /*! Absolute path to the desktop wallpaper, used as the glass's backdrop
        when no explicit one is given. Empty means the glass has nothing to
        refract and stays off rather than drawing an invisible nothing. */
    property string wallpaper: ""

    /*! Why the glass is or is not drawing, in one string. A toggle that
        silently has nothing to refract is indistinguishable from a toggle that
        does nothing — this is how you tell them apart without guessing. */
    readonly property string glassDiag: `useGlass=${root.useGlass} wallpaper=${root.wallpaper !== ""} paperStatus=${paper.status} paperSize=${paper.implicitWidth}x${paper.implicitHeight} backdrop=${root._backdrop !== null} screen=${root.screenWidth}x${root.screenHeight} surface=${root.width}x${root.height}`

    readonly property Item _backdrop: root.backdrop ?? (paper.status === Image.Ready ? wallpaperImage : null)

    /*!
        The wallpaper, drawn at SCREEN size and offset so that this item's
        coordinate space lines up with the screen's.

        🔴 CLIPPED AT DECODE TIME, NOT MOVED INTO PLACE. The obvious way to get
        the right pixels under the panel is to draw the whole wallpaper at
        screen size and shift it up by the surface's inset — the band the dock
        occupies then lands at 0,0. It does not work, and the failure is silent:
        an item positioned entirely outside its window's bounds is not rendered
        at all, so the ShaderEffectSource that samples it gets an empty texture
        and the glass draws a flat black slab. Which is exactly what a dock with
        the glass switched off looks like, so it reads as the toggle doing
        nothing rather than as the backdrop being missing.

        ⚠️ STATE OF PLAY: the backdrop now resolves and the glass now DRAWS —
        measured, mean absolute difference across the panel between glass on
        and glass off went from 0.00 to 11.64 levels. Its appearance is not
        right yet: it renders far darker than the wallpaper behind it, so the
        panel reads as a black slab rather than as glass. `useGlass` stays
        false by default until the shader's output matches its intent. The
        shipping translucency is compositor blur, which is measured and works.

        ⚠️ Assumes the wallpaper covers the output — which is what a wallpaper
        does. A picture with a different aspect ratio, cropped by the desktop's
        own fill mode, would be sampled slightly off.
    */
    Item {
        id: wallpaperImage
        // ⚠️ VISIBLE. Qt renders nothing into a ShaderEffectSource for an item
        // whose `visible` is false, so an invisible backdrop yields a
        // transparent-black texture and the glass draws a flat slab. Glass
        // takes it out of the scene itself via `hideBackdrop`.
        visible: root.useGlass && root.backdrop === null
        x: 0
        y: 0
        width: root.width
        height: root.height

        // 🔴 A CLIPPING BOX AT 0,0 WITH THE PICTURE OFFSET INSIDE IT. Two
        // earlier shapes both failed silently and both looked like the glass
        // toggle doing nothing:
        //
        //   · The full-size wallpaper offset up into place. An item lying
        //     entirely outside its window's bounds is never rendered, so the
        //     ShaderEffectSource sampled an empty texture and the glass drew a
        //     flat black slab.
        //   · An Image with `sourceClipRect` computed from its own
        //     implicitWidth/implicitHeight. That is a circular binding: the
        //     clip needs the decoded size, the decode needs a non-empty clip,
        //     and the image never loads at all. `status` stays below Ready
        //     forever and nothing warns.
        //
        // A box that is inside the window, with the picture as a child pushed
        // up by the surface's inset, has neither problem. Qt renders the part
        // of the child that intersects the clip, which is exactly the band the
        // dock sits on.
        clip: true

        Image {
            id: paper
            source: root.wallpaper === "" ? "" : (root.wallpaper.startsWith("/") ? "file://" + root.wallpaper : root.wallpaper)
            width: root.screenWidth
            height: root.screenHeight
            x: -root.surfaceX
            y: -(root.screenHeight - root.height - root.surfaceY)
            fillMode: Image.PreserveAspectCrop
            cache: true
            asynchronous: true
            // Decoded at screen size, in device pixels. The default decodes at
            // the item's implicit size and upscales — the same mistake that
            // made every icon in this dock soft.
            sourceSize.width: root.screenWidth * Math.max(1, Screen.devicePixelRatio)
            sourceSize.height: root.screenHeight * Math.max(1, Screen.devicePixelRatio)
        }
    }

    /*! The output's logical size and this surface's position in it, so the
        wallpaper can be placed. Supplied by the shell, which knows. */
    property real screenWidth: Screen.width
    property real screenHeight: Screen.height
    property real surfaceX: 0
    property real surfaceY: 0

    /*! How hard the glass bends the backdrop at its rim, in pixels. */
    property real blurAmount: 12

    /*!
        Master switch for motion. False makes every spring settle instantly.

        Not a cosmetic preference: vestibular disorders make large sliding
        motion genuinely unpleasant, and the desktop is not a place to make
        somebody argue for that. Implemented by collapsing the springs' response
        rather than by branching every animation, so there is no second code
        path to keep correct.
    */
    property bool animations: true

    /*! Let the dock be resized by dragging its outer edge. */
    property bool resizable: true

    /*! How folder stacks display their contents: "grid", "list" or "icons". */
    property string folderView: "grid"

    /*! `{ "<key>": "/path/to/image.png" }` — per-app icon replacements. */
    property var iconOverrides: ({})

    readonly property real _resp: root.animations ? 1 : 0.0001

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
    readonly property real maxIconSize: root.baseIconSize * (root.magnify ? root.magnification : 1)
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

        // The permanent first slot, as macOS gives Finder. It is not pinned,
        // cannot be dragged out, and does not come and go with what is
        // running: a dock whose first icon moves is a dock you cannot build
        // muscle memory for.
        if (root.showLauncher)
            out.push({
                entry: null,
                toplevels: [],
                kind: "launcher",
                pinned: true,
                key: "__launcher"
            });

        for (const id of root.pinnedClean) {
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
                key: norm(id),
                // ⚠️ The ORIGINAL string from the pinned list, not the
                // normalised key. `key` is lower-cased for matching against a
                // Wayland appId, so unpinning by it silently misses every entry
                // with a capital in it — `org.gnome.Nautilus` was undraggable
                // out of the dock while `firefox` worked, which looks like a
                // gesture bug and is a string bug.
                pinId: id
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
        //
        // ⚠️ ALWAYS PRESENT, even with no folders pinned. It is not only a
        // divider — it is the dock's resize handle, which is where macOS puts
        // it and where people reach for it. Showing it only when a folder
        // happens to be pinned means the handle appears and disappears with an
        // unrelated setting, and a resize gesture that is sometimes impossible
        // is worse than one that is merely hidden.
        {
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

    /*! Keys whose app was launched from here and has not yet shown a window. */
    property var launching: ({})

    function beginLaunch(key: string): void {
        const next = Object.assign({}, root.launching);
        next[key] = true;
        root.launching = next;
    }

    /*! Stop bouncing `key`, whether or not its window ever appeared.

        The dock owns this map, so the dock clears it. The item that timed out
        cannot clear its own `launching`, because that property is bound from
        here and writing to it would kill the binding — see DockItem's
        \l{DockItem::launchTimedOut}{launchTimedOut}. */
    function endLaunch(key: string): void {
        if (root.launching[key] === undefined)
            return;
        const next = Object.assign({}, root.launching);
        delete next[key];
        root.launching = next;
    }

    // The moment a launching app owns a toplevel, stop bouncing. Watching the
    // model rather than a timer is what makes the bounce end exactly when the
    // window appears instead of a beat before or after it.
    onItemsChanged: {
        let changed = false;
        const next = Object.assign({}, root.launching);
        for (const it of root.items)
            if (next[it.key] && it.toplevels.length > 0) {
                delete next[it.key];
                changed = true;
            }
        if (changed)
            root.launching = next;
    }

    // ── Geometry ────────────────────────────────────────────────────────
    // Everything below is a pure function of `cursor.value` and `magnify.value`.

    Spring {
        id: cursor
        // Short and critically damped: magnification must feel like it is
        // attached to the pointer, not chasing it. Anything slower than ~0.12s
        // reads as lag rather than as smoothing.
        // Magnification tracks the pointer closely but is not glued to it:
        // a touch of lag and a touch of overshoot is what reads as MASS. Dead
        // critical damping at 0.12s feels like a cursor-follower, not an object.
        response: 0.14 * root._resp
        damping: 0.86
        epsilon: 0.25
    }

    readonly property bool debugging: root.debugCursor >= 0

    Spring {
        id: magnify
        target: (root.magnify && (root.overBand || root.debugging)) ? 1 : 0
        response: 0.28 * root._resp
        damping: 1.0
    }

    Spring {
        id: reveal
        // 1 = fully out, 0 = tucked away. Slightly under-damped so the dock
        // arrives with a hint of settle instead of stopping dead.
        // ⚠️ AN OPEN POPUP HOLDS THE DOCK OUT. A context menu is drawn ABOVE
        // the band, so travelling to it takes the pointer off the dock — and an
        // auto-hiding dock would slide away mid-reach, taking the menu with it.
        // The menu was reachable in principle and unusable in practice.
        // A drag holds it out for the same reason.
        // ⚠️ A SEPARATOR RESIZE HOLDS IT OUT TOO. Dragging the divider moves the
        // pointer toward the screen edge the dock hides into, and without this
        // the dock slid away underneath the gesture that was resizing it.
        target: (!root.autoHide || root.pointerPresent || root.popupOpen || drag.active || sepResize.active || gripDrag.active || root.debugging) ? 1 : 0
        // Slower and softer than a menu: the dock is a large, heavy object and
        // should arrive like one. Caelestia's own panels sit near 0.38s.
        response: 0.46 * root._resp
        damping: 0.78
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
        // The divider gets a fraction of a cell instead of a whole one. A full
        // empty slot either side of a one-pixel line is most of what made the
        // row read as loosely packed.
        widthScale: root.items.map(i => i.kind === "separator" ? 0.34 : 1)
    }

    readonly property var layout: row.metrics

    /*! Position of item \a i along the dock's axis, at rest, IN THE SURFACE'S
        OWN FRAME.

        ⚠️ Not screen coordinates. A layer-shell window has no `x`/`y` in QML —
        the compositor places it and never tells the client where. Returning
        window-frame numbers and letting the caller add the surface origin from
        `hyprctl layers` is honest; returning `root.x + …` produced `null` for
        every item, because `undefined + n` is NaN and JSON renders that as
        null. */
    function itemCentre(i: int): real {
        return row.restCentre(i);
    }

    /*! The panel's rectangle in the SURFACE's frame, and the numbers it is
        derived from.

        ⚠️ REPORTED, NOT INFERRED. Four separate attempts to measure this dock's
        panel from a screenshot picked out a dark run belonging to something
        else — a window, the wallpaper's shadow, the screen's own border — and
        each produced a different wrong answer with equal confidence. The dock
        computes this rectangle; it can simply say what it is. */
    function panelRect(): var {
        return {
            x: bg.x,
            y: bg.y,
            w: bg.width,
            h: bg.height,
            band: root.band,
            total: root.layout.total,
            sizes: root.layout.sizes,
            magnifyAmount: magnify.value,
            cursor: cursor.value,
            hovered: hover.hovered,
            pointerPresent: root.pointerPresent,
            edge: root.edge,
            horizontal: root.horizontal,
            // Everything the auto-hide decision is made from. Reported rather
            // than inferred for the same reason the rectangle is: a dock that
            // hides while the pointer is on it cannot be diagnosed from a
            // screenshot, and the two candidate causes — the pointer leaving
            // the input mask, and the reveal spring being told to retract —
            // look identical on screen.
            reveal: reveal.value,
            revealTarget: reveal.target,
            liveExtent: root.liveExtent,
            tuckedAway: root.tuckedAway,
            autoHide: root.autoHide,
            pointerEdgeDistance: root.pointerEdgeDistance,
            overBand: root.overBand,
            popupOpen: root.popupOpen,
            // Every latch that can hold the reveal out. One of these staying
            // set after its gesture ended is how auto-hide died last time, and
            // from outside the dock that is indistinguishable from the setting
            // being off.
            minIconSize: root.minIconSize,
            maxIconSizeAllowed: root.maxIconSizeAllowed,
            iconSizeRequested: root.iconSize,
            baseIconSize: root.baseIconSize,
            bgPad: root.bgPad,
            magnify: root.magnify,
            resizing: sepResize.active,
            gripping: gripDrag.active,
            dragging: drag.active,
            start: root.layout.start
        };
    }

    /*! What item \a i resolved its artwork to, and whether that artwork
        loaded.

        🔴 THREE GUESSES WERE MADE ABOUT WHY TWO ICONS WERE LETTER TILES —
        a missing theme, a missing size, a missing plugin — and the files were
        present every time. The dock knows exactly which URL it asked for and
        exactly what Image said about it; asking is not a debug hook, it is the
        difference between a diagnosis and a theory. */
    function itemIcon(i: int): string {
        const c = rowItems.itemAt(i);
        return c ? String(c.iconSource) : "";
    }

    function itemIconOk(i: int): bool {
        const c = rowItems.itemAt(i);
        return c ? c.iconReady : false;
    }

    /*! The rendered icon box and the slot it sits in, for item \a i. */
    function itemBox(i: int): real {
        const c = rowItems.itemAt(i);
        return c ? c.boxSize : -1;
    }

    /*! The pinned list with anything unusable removed.

        A config written by a version that did not refuse `undefined` still has
        it, and the dock must not need the operator to hand-edit JSON to get rid
        of two tiles it should never have drawn. Filtered on the way in, and
        written back the next time the list is saved for any reason. */
    readonly property var pinnedClean: (root.pinned ?? []).filter(k => root._usableId(k))

    function itemSlot(i: int): var {
        const c = rowItems.itemAt(i);
        return c ? { w: c.width, h: c.height, x: c.x, y: c.y } : null;
    }

    /*! Position across the dock's axis — the middle of the resting band, which
        is where a pointer has to be to hit an icon. Surface frame. */
    function itemCross(): real {
        const far = root.horizontal ? root.height : root.width;
        const inset = root.edgeGap + root.bgPad + root.baseIconSize / 2;
        return (root.edge === Qt.BottomEdge || root.edge === Qt.RightEdge) ? far - inset : inset;
    }

    // ── Surface ─────────────────────────────────────────────────────────
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "charis-dock"
    // The dock must never take keyboard focus. A layer surface that does
    // steals input from whatever the person was typing into the moment the
    // pointer crosses it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // 🔴 NEVER ExclusionMode.Auto HERE. Auto reserves the whole surface, and
    // this surface deliberately grows when a menu or a stack opens — so every
    // right-click pushed every window on the screen upwards and dropped them
    // back when the menu closed. Everything bounced, and it looked like the
    // dock was fighting the window manager rather than like a reserved-space
    // bug, because the menu itself animated perfectly.
    //
    // The reservation must describe what the dock OCCUPIES, not what its
    // surface happens to be big enough for. A popup is drawn over the desktop
    // like any other floating panel; it does not claim space, so windows do
    // not move at all.
    exclusionMode: root.autoHide ? ExclusionMode.Ignore : ExclusionMode.Normal

    /*! The reservation, LATCHED while the dock is being resized.

        🔴 EVERY FRAME OF A RESIZE DRAG USED TO RESERVE A DIFFERENT AMOUNT.
        `restExtent` is derived from `baseIconSize`, the drag changes that
        continuously, and each change asks the compositor to re-reserve space —
        which re-lays-out every tiled window on the output. The dock stuttered,
        and so did the window above it, while the operator was doing nothing
        but dragging the dock's own edge. A dock resize is not a request to
        reflow the desktop sixty times.

        The reservation follows the dock everywhere else; during the gesture it
        holds still and catches up on release. */
    property real _latchedExtent: root.restExtent
    exclusiveZone: root.autoHide ? 0 : Math.round(root._latchedExtent)

    // ⚠️ A SETTLE, NOT JUST A DRAG GUARD. Latching only while the resize GRIP
    // is held missed the other way to resize a dock: the Icon size slider in
    // the settings panel, which emits continuously and reflowed every tiled
    // window on the output for as long as the operator kept dragging it. The
    // reservation is a statement about the finished dock, so it waits until the
    // dock has stopped changing.
    onRestExtentChanged: extentSettle.restart()

    Timer {
        id: extentSettle
        interval: 180
        onTriggered: if (!gripDrag.active)
            root._latchedExtent = root.restExtent
    }

    // 🔴 A VERTICAL DOCK HAD NO HEIGHT AT ALL. `implicitHeight` is
    // `horizontal ? surfaceExtent : 0`, so on a left- or right-hand dock the
    // surface's height had to come from anchors — and only ONE of top/bottom
    // was ever set. The compositor gave it a height of 1: `xywh: 10 581 1159 1`.
    // Every Edge except Bottom was broken from the day the setting shipped, and
    // the settings panel has offered all four the whole time.
    //
    // The rule is the same in both orientations: span the axis the dock runs
    // ALONG, and anchor to the single edge it sits on across the other.
    anchors {
        bottom: root.edge === Qt.BottomEdge || !root.horizontal
        top: root.edge === Qt.TopEdge || !root.horizontal
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
    /*! Distance between the screen edge and the dock. 0 sits flush, which is
        the default because macOS's dock touches the edge and a floating strip
        with a gap under it is the look of a third-party imitation. */
    property real edgeGap: 0

    /*! Padding between the icons and the dock's background edge. */
    readonly property real bgPad: root.iconPadding >= 0 ? root.iconPadding : Math.max(4, Math.round(root.baseIconSize * 0.09))

    /*! Thickness of the dock's background at rest. */
    readonly property real band: root.baseIconSize + root.bgPad * 2

    /*! What the dock actually occupies at rest, from the screen edge. This is
        the number the compositor is told to reserve — never the surface size,
        which is much larger. */
    readonly property real restExtent: root.edgeGap + root.band

    readonly property real bandThickness: root.maxIconSize + root.bgPad + root.edgeGap

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
    /*! Room above the dock to drag an icon out into.

        ⚠️ WITHOUT THIS THE TEAR-OFF GESTURE CANNOT BE DETECTED AT ALL. A layer
        surface stops receiving pointer motion the moment the pointer leaves it,
        even mid-drag with the button held — measured: dragging an icon 240px
        above the dock produced not one `centroidChanged`, so the handler never
        saw the pointer go anywhere and `tornOff` stayed false for ever.
        Reading code would never have found it; the arithmetic was right and
        simply never ran.

        So the surface grows while a drag is in progress and the pointer stays
        over it the whole way. The exclusive zone is unaffected — it describes
        what the dock occupies, not how big its surface is — so nothing on the
        desktop moves. */
    /*! The screen dimension the removal drag travels along. */
    readonly property real travelExtent: root.horizontal ? root.screenHeight : root.screenWidth

    /*! The largest surface the output can hold.

        🔴 THE SURFACE WENT OFF THE TOP OF THE SCREEN. With the icon size left
        at 131 by a resize, the computed surface came to 1159 on a 1152-tall
        output and the compositor placed it at y = −7. Everything downstream —
        the mask, the tear distance, where the row thinks the screen edge is —
        is measured from a surface that is partly not on the display. Nothing
        in the geometry may exceed the output it lives on. */
    readonly property real maxSurface: root.travelExtent - 8

    /*! Room above the dock for the removal gesture: as much as the output can
        spare. A layer surface stops receiving motion the moment the pointer
        leaves it, even with a button held, so anything past this simply stops
        being felt — which is why the threshold below is derived FROM this
        rather than the other way round. */
    readonly property real tearZone: Math.max(120, root.maxSurface - root.bandThickness)

    /*! How far from the dock's edge an icon must be dragged before releasing
        it removes the app.

        Half the screen, deliberately. Removal is destructive and used to fire
        at half an icon's distance, which is inside the slop of an ordinary
        reorder — a nudge upward while shuffling icons deleted one. macOS is
        similarly forgiving about small excursions and only lets go when you
        have clearly left. */
    readonly property real tearThreshold: Math.min(root.travelExtent / 2, root.tearZone - root.baseIconSize * 0.5)

    /*!
        How close to the screen edge the pointer must come to reveal a hidden
        dock.

        🔴 THE WHOLE SURFACE USED TO BE THE TRIGGER, so a hidden dock sprang out
        whenever the pointer came within ~140px of the bottom of the screen —
        most of the way across a window on a display this size. macOS wants the
        pointer at the edge.
        ⚠️ 16px rather than the 4 that seems right, because THE SURFACE DOES NOT
        REACH THE SCREEN EDGE. The compositor reserves a gap (10px here), so the
        layer surface ends short of the display and the last 10 rows of pixels
        are unreachable — a 4px strip sat entirely inside that dead zone and the
        dock could not be revealed by pushing the pointer to the bottom at all.
        Measured: nothing at y=1143/1146/1151, revealed at y=1137. */
    readonly property real revealStrip: 16

    /*!
        Fully tucked away: nothing but the trigger strip should accept input.

        🔴 THE MASK USED TO RETRACT OUT FROM UNDER THE POINTER. This was
        `reveal.value < 0.02` alone, and `reveal.target` follows `hover.hovered`
        — which is decided by the mask. So: pointer enters the 16px strip, the
        dock reveals, the mask grows; the dock finishes hiding from a previous
        cycle, the mask snaps back to 16px, the pointer is now outside it, hover
        goes false, the dock hides, the pointer is back in the strip, and it
        starts again. A feedback loop between an input region and the thing that
        decides the input region. On screen: the dock flashes, and hides while
        you are hovering it.

        Two changes break the loop. The mask stays open while the pointer is
        over the dock — an input region may not remove itself from under a
        pointer it is currently receiving — and the threshold is low enough that
        it only closes once the dock has genuinely finished leaving.
    */
    readonly property bool tuckedAway: root.autoHide && !root.debugging && !root.pointerPresent && !root.popupOpen && reveal.value < 0.005

    /*!
        The SURFACE always reserves room for the tear gesture; the INPUT MASK
        does not.

        🔴 GROWING THE SURFACE MID-DRAG CANCELS THE POINTER GRAB. Resizing a
        layer surface makes the compositor re-run enter/leave, which drops the
        implicit grab a held button had established — measured as a centroid
        frozen at its press value for an entire 220px gesture while the item
        index still changed, so the tear-off could never fire and dragging an
        icon out of the dock silently did nothing.
        The surface is therefore a constant size and only the mask changes.
        Input outside the mask is not stolen, and during a grab the compositor
        keeps delivering motion to the grabbed surface regardless of it — which
        is the whole reason this split works.
    */
    /*! Room kept for a menu or a stack, always — so opening one never touches
        the surface. */
    readonly property real popupReserve: 460

    /*!
        🔴 THE SURFACE MUST NOT CHANGE SIZE WHILE THE DOCK IS BEING USED, AND
        IT DID — twice per right-click and sixty times a second during a resize.

        It used to be `bandThickness + tearZone + max(stack, menu) popupExtent`.
        Opening a menu therefore RESIZED the layer surface; the surface is
        anchored to the screen edge, so growing it moves its top, the content
        re-lays-out and the compositor renegotiates. The dock visibly jumped up
        and settled back on every open and every close — reported as the dock
        bouncing up and down on every right-click. The same term made a resize
        drag renegotiate the surface every frame, which is the one case this
        file already knew was forbidden, and it stuttered the window above too.

        ⚠️ SIZED FROM THE CONFIGURATION, NOT FROM THE WORST CASE. The first fix
        here reserved for the largest icon the resize gesture allows, which came
        to 1072 of the 1152 rows on this display — a transparent surface across
        nine tenths of the screen, held off the desktop by an input mask alone.
        The mask is correct, but "one bug away from swallowing every click on
        the desktop" is not a trade worth making to avoid a resize that happens
        when the user drags the dock's edge and at no other time.

        So it follows the config, and holds still during a gesture. Everything
        that varies moment to moment lives in the mask, which is a client-side
        input region and costs nothing to change.
    */
    /*! ⚠️ THE LARGER OF THE TWO, NOT THE SUM. A popup is never open during a
        drag and a drag never happens with a popup open, so the surface needs
        room for whichever of them is bigger — not for both at once. Adding
        them put the surface past the top of the screen once the tear distance
        became half the display. */
    readonly property real wantedSurface: Math.min(root.maxSurface, root.bandThickness + Math.max(root.tearZone, root.popupReserve))
    property real surfaceExtent: root.wantedSurface

    onWantedSurfaceChanged: if (!gripDrag.active)
        root.surfaceExtent = root.wantedSurface

    /*! What actually accepts input when no button is held. */
    readonly property real liveExtent: root.tuckedAway ? root.revealStrip : root.bandThickness + Math.max(stack.popupExtent, menu.popupExtent)

    implicitHeight: root.horizontal ? root.surfaceExtent : 0
    implicitWidth: root.horizontal ? 0 : root.surfaceExtent

    mask: Region {
        x: root.horizontal ? 0 : (root.edge === Qt.LeftEdge ? 0 : root.width - root.liveExtent)
        y: root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - root.liveExtent : 0) : 0
        width: root.horizontal ? root.width : root.liveExtent
        height: root.horizontal ? root.liveExtent : root.height
    }

    color: "transparent"

    /*!
        🔴 THE POINTER'S DISTANCE FROM THE EDGE, NOT A SEPARATE HOVER ITEM.

        Two failures bracket this, and the second was worse than the first.

        Originally the magnification followed the WHOLE surface's hover. The
        input mask is `bandThickness + whichever popup is open`, so a stack left
        open stretched it up the screen and the dock magnified with the pointer
        nowhere near it — settled at full size, permanently.

        The fix was a separate Item covering just the band, with its own
        HoverHandler. It stopped reporting hover at all: with the pointer at
        (1282, 1115), squarely on a 1070..1152 band, `hovered` was false. So the
        dock stopped magnifying entirely — the icons held their size and only
        the gaps between them opened up, which is exactly what a magnification
        with `amount` stuck at 0 looks like — and, because reveal followed that
        same handler, the dock hid itself the moment the pointer moved onto the
        resize grip or up toward an open menu. The menu could be opened and
        never reached.

        Both are answered by asking the question directly. One handler on the
        surface, and the two things that depend on the pointer ask different
        questions of it:

          · magnification — is the pointer over the BAND?
          · reveal — is the pointer anywhere on the dock, INCLUDING the grip
            just outside the panel and an open popup above it?

        No second item, no stacking order, no input region that can disagree
        with the thing it is supposed to describe.
    */
    /*!
        Hover, with a short tail — and the tail is not a nicety.

        🔴 THE LAST ROW OF PIXELS ON THE SCREEN DROPS HOVER WHILE THE POINTER
        MOVES ALONG IT. Measured by sliding the pointer left across the bottom
        of the display in 90px steps and asking the dock what it thought after
        each one:

        \badcode
        y = 1151:  T F F T F F T F F T F F T F F T F F T F F T
        y = 1148:  T T T T T T T T T T T T T T T T T T T T T T
        y = 1145:  T T T T T T T T T T T T T T T T T T T T T T
        y = 1120:  T T T T T T T T T T T T T T T T T T T T T T
        \endcode

        Only y = 1151 — the very last row of an 1152-tall output, which is the
        row the pointer sits on the moment you push it into the bottom of the
        screen. Held STILL there it is hovered indefinitely; it is motion along
        that row that drops it, two samples in three. Reported exactly as: the
        dock pops up as you approach, hides when you touch the border, and
        "either comes up or glitches" when you lift off it again.

        Whatever the compositor is doing on its last row, the dock has no
        business believing it. A pointer does not leave a dock and come back
        thirty times a second, so a hover that blinks off is a lie about the
        world and the dock rides through it — for how long is decided by WHERE
        it was lost, which is the whole trick; see \c hoverTail.

        This is also what makes travelling to a menu survive: it is the same
        problem with a different cause, and the same answer.
    */
    readonly property bool pointerPresent: hover.hovered || hoverTail.running

    /*!
        The last 200 hover transitions, with where the pointer was and what the
        dock decided.

        🔴 THREE ROUNDS OF THIS BUG WERE FIXED BY REASONING AND TWO OF THEM CAME
        BACK. A hover that blinks is invisible in a screenshot, invisible in the
        journal, and indistinguishable from the setting being off — the only way
        to see it is to write down every transition with the pointer's position
        and compare it against what the mouse was actually doing. So the dock
        keeps that log itself, and `hoverLog` hands it over.
    */
    property var hoverLog: []

    /*! Longest gap between a leave and the enter that followed it, in ms.
        The number the tail has to beat; if it ever approaches the tail's own
        interval, the rule is about to start failing. */
    property real longestBlink: 0
    property real _leftAt: 0

    function _noteHover(kind: string, d: real): void {
        const now = Date.now();
        let gap = -1;
        if (kind === "leave") {
            root._leftAt = now;
        } else if (root._leftAt > 0) {
            gap = now - root._leftAt;
            if (gap > root.longestBlink)
                root.longestBlink = gap;
            root._leftAt = 0;
        }
        const l = root.hoverLog.length > 199 ? root.hoverLog.slice(-199) : root.hoverLog.slice();
        l.push({
            t: now,
            e: kind,
            gap: gap,
            // ⚠️ MAX_VALUE * 10 is Infinity and JSON renders that as null,
            // which crashed the reader rather than telling it "no pointer".
            dist: isFinite(d) ? Math.round(d * 10) / 10 : -1,
            reveal: Math.round(reveal.value * 100) / 100,
            live: Math.round(root.liveExtent),
            tail: hoverTail.interval,
            tucked: root.tuckedAway
        });
        root.hoverLog = l;
    }

    Timer {
        id: hoverTail

        // 🔴 220ms WAS NOT ENOUGH, AND THE REASON SAYS WHICH NUMBER IS RIGHT.
        // On the last row the hover does not blink for a frame — it goes away
        // for stretches of half a second at a time while the pointer moves, and
        // the reveal spring, sampled through one of those, had fallen to 0.4.
        //
        // Rather than pick a bigger number and hope, ask WHERE the pointer was
        // when it vanished. Leaving a dock means moving AWAY from the edge it
        // lives on, which loses hover at a distance of at least the band. A
        // hover lost with the pointer one pixel from the screen's own border is
        // not a departure — there is nowhere further to go. So that case gets a
        // long hold and every other case keeps the short one, and the dock
        // still hides promptly when you actually leave.
        //
        // Bounded rather than indefinite: a pointer that leaves fast enough for
        // its last sample to land on the border would otherwise hold the dock
        // out for ever. And a dock held out while the pointer sits on the
        // screen edge is not a compromise — that is the reveal strip's own
        // behaviour.
        // 🔴 TWO BRANCHES, AND THE LOG CHOSE BOTH NUMBERS.
        //
        // A flat 400ms was tried first, on the theory that a blink returns fast
        // and a departure never does. Flattening it is what finally MEASURED
        // the blink, because the previous six-second hold had been covering it:
        //
        //   +24033ms leave dist=0.5  reveal=0.44   +24722ms enter  (689ms)
        //   +24828ms leave dist=0.5  reveal=0.42   +25529ms enter  (701ms)
        //
        // Seven hundred milliseconds, with the pointer sitting on the screen's
        // last row — and the reveal already half way down by the time it came
        // back. No tail short enough to hide promptly can ride that out, so
        // duration alone cannot be the whole rule.
        //
        // What separates those from a real departure is unambiguous in the same
        // log: the blinks are at dist 0.5 to 2.4, the departures at 67 of a
        // 117-deep mask. The pointer cannot leave through the bottom of the
        // display — there is nowhere below it — so a hover lost against the
        // border is never a departure and the dock can hold on for as long as
        // it likes. Anywhere else, 400ms: long enough for an ordinary blink,
        // short enough that hiding still reads as immediate.
        interval: root._lastEdgeDistance <= 10 ? 6000 : 400
        repeat: false
    }

    /*! The last edge distance seen while the pointer was genuinely on the
        surface. Latched, so the magnification does not collapse and re-expand
        during a hover blink — `hover.point.position` is meaningless once the
        handler says the pointer is gone. */
    property real _lastEdgeDistance: Number.MAX_VALUE

    /*! Edge distance for a point in the surface's frame. */
    function edgeDistanceOf(p: point): real {
        return root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - p.y : p.y) : (root.edge === Qt.RightEdge ? root.width - p.x : p.x);
    }

    // ⚠️ The latch is written from the handler, never from inside this binding.
    // Assigning `_lastEdgeDistance` in a binding that also READS it is a
    // binding loop, and QML's answer to a loop is to stop evaluating — which
    // would freeze the magnification rather than fix it.
    readonly property real pointerEdgeDistance: hover.hovered ? root.edgeDistanceOf(hover.point.position) : (root.pointerPresent ? root._lastEdgeDistance : Number.MAX_VALUE)

    /*! The pointer is on the dock itself, rather than merely on its surface. */
    readonly property bool overBand: root.pointerPresent && root.pointerEdgeDistance <= root.bandThickness + 8

    /*! Something is open that the pointer has to be able to travel to. */
    readonly property bool popupOpen: menu.popupExtent > 0 || stack.popupExtent > 0

    HoverHandler {
        id: hover
        onPointChanged: {
            const p = hover.point.position;
            cursor.target = root.horizontal ? p.x : p.y;
            // Latched here rather than in the binding that reads it: see
            // pointerEdgeDistance.
            if (hover.hovered)
                root._lastEdgeDistance = root.edgeDistanceOf(p);
        }
        onHoveredChanged: {
            // The tail that rides through a hover that blinks off; see
            // Dock.pointerPresent.
            const wasPresent = hoverTail.running;
            if (hover.hovered)
                hoverTail.stop();
            else
                hoverTail.restart();
            root._noteHover(hover.hovered ? "enter" : "leave", root._lastEdgeDistance);
            if (!hover.hovered)
                return;
            // Enter the row without a swipe across it. Without this the cursor
            // spring starts from wherever it was left last time and the whole
            // dock visibly ripples on entry.
            //
            // 🔴 BUT NOT WHEN THE POINTER NEVER ACTUALLY LEFT. `reset` SNAPS the
            // magnification peak to wherever the pointer is. On the screen's
            // bottom row the hover blinks off and on several times a second, and
            // every re-entry snapped the peak — so sliding along the edge under
            // the dock made the animation stutter and reappear somewhere else
            // along the row, exactly as if the cursor had dived under the dock
            // and touched it again in a different place. If the tail was still
            // running this is not an entry, it is the same hover continuing, and
            // the spring must be left to travel.
            if (wasPresent)
                return;
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
        readonly property real bgPad: root.bgPad
        readonly property real edgeGap: root.edgeGap
        readonly property real band: root.band
        readonly property real thick: root.bandThickness
        readonly property real bandStart: content.thick - content.edgeGap - content.band

        // 🔴 A BARE RIGHT-CLICK USED TO OPEN SETTINGS AND IT WAS INTOLERABLE.
        // The gaps between icons are a few pixels wide, so aiming at an icon
        // and missing — which happens constantly — threw a settings window
        // across the screen. Settings now live in the icon menu, where a
        // right-click is already deliberate, and behind a modifier here for
        // people who want the shortcut.
        TapHandler {
            acceptedButtons: Qt.RightButton
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: e => {
                if (e.modifiers & Qt.ControlModifier)
                    root.settingsRequested();
            }
        }

        Squircle {
            id: bg

            width: root.horizontal ? root.layout.total + content.bgPad * 2 : content.band
            height: root.horizontal ? content.band : root.layout.total + content.bgPad * 2

            // 🔴 FROM THE ROW'S START, NOT FROM THE CENTRE OF THE SURFACE.
            // The row is no longer centred: it is anchored so the icon under
            // the pointer stays under the pointer, which means it SLIDES as
            // the pointer moves along it (see MagnifiedRow.metrics). A
            // background that stays centred while the row slides leaves the
            // icons hanging off one end of it.
            x: root.horizontal ? root.layout.start - content.bgPad : (root.edge === Qt.LeftEdge ? content.edgeGap : content.bandStart)
            y: root.horizontal ? (root.edge === Qt.BottomEdge ? content.bandStart : content.edgeGap) : root.layout.start - content.bgPad

            radius: Math.min(width, height) * root.cornerRoundness
            smoothing: 1
            fillColor: Qt.rgba(root.panelColor.r, root.panelColor.g, root.panelColor.b, root.panelOpacity)
            strokeColor: root.borderColor
            strokeWidth: root.borderWidth
            opacity: reveal.value
            visible: !glassBg.visible
        }

        // ── The glass edge ──────────────────────────────────────────────
        //
        // Compositor blur alone is FROSTING, not glass — it is what every
        // Linux panel has had for a decade and it reads as flat because a real
        // sheet of glass is defined by its EDGE: a bright specular line where
        // the light catches the top bevel, and a darker one underneath where it
        // does not. Two hairlines are most of the difference between "a
        // translucent rectangle" and "an object lying on top of the desktop",
        // and they cost two rectangles.
        Item {
            id: glassEdge
            x: bg.x
            y: bg.y
            width: bg.width
            height: bg.height
            opacity: reveal.value * (root.useGlass || root.blurAmount > 0 ? 1 : 0)
            visible: opacity > 0.01

            // Top bevel: brightest in the middle, fading at the corners, the
            // way a curved edge catches light.
            Rectangle {
                x: parent.width * 0.06
                y: 1
                width: parent.width * 0.88
                height: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0
                        color: "transparent"
                    }
                    GradientStop {
                        position: 0.5
                        color: Qt.rgba(1, 1, 1, 0.30)
                    }
                    GradientStop {
                        position: 1
                        color: "transparent"
                    }
                }
            }

            // Bottom shadow line — the underside of the same bevel.
            Rectangle {
                x: parent.width * 0.06
                y: parent.height - 1
                width: parent.width * 0.88
                height: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0
                        color: "transparent"
                    }
                    GradientStop {
                        position: 0.5
                        color: Qt.rgba(0, 0, 0, 0.28)
                    }
                    GradientStop {
                        position: 1
                        color: "transparent"
                    }
                }
            }
        }

        // The refracting background. Off by default: it needs a backdrop item
        // and costs a texture plus a fragment pass, which is real money on
        // integrated graphics. Bind `useGlass` to taste, not to fashion.
        Glass {
            id: glassBg
            visible: root.useGlass && root._backdrop !== null
            x: bg.x
            y: bg.y
            width: bg.width
            height: bg.height
            backdrop: root._backdrop
            // The dock's own wallpaper exists only to be sampled; it must not
            // be painted over the desktop through a transparent surface.
            hideBackdrop: root.backdrop === null
            radius: Math.min(width, height) * root.cornerRoundness
            smoothing: 1
            refraction: root.blurAmount
            thickness: Math.max(6, root.blurAmount * 1.4)
            tint: root.panelColor
            tintAmount: root.panelOpacity * 0.5
            opacity: reveal.value
            enabled: FrameBudget.quality > 0.5
        }

        // ── Resize grip ─────────────────────────────────────────────────
        //
        // Drag the dock's outer edge to resize it, as on macOS. Deliberately
        // the EDGE and not a separate widget: an affordance that has to be
        // found first is not the same gesture, and the whole point is that
        // people already know this one.
        //
        // The strip is 6px and sits astride the border, half in and half out.
        // Entirely inside, it steals clicks from the icons behind it; entirely
        // outside, it is off the surface and unreachable.
        Item {
            id: grip

            visible: root.resizable && reveal.value > 0.9
            width: root.horizontal ? bg.width : 6
            height: root.horizontal ? 6 : bg.height
            x: root.horizontal ? bg.x : (root.edge === Qt.LeftEdge ? bg.x + bg.width - 3 : bg.x - 3)
            y: root.horizontal ? (root.edge === Qt.BottomEdge ? bg.y - 3 : bg.y + bg.height - 3) : bg.y

            property real startSize: 0

            HoverHandler {
                id: gripHover
                cursorShape: root.horizontal ? Qt.SizeVerCursor : Qt.SizeHorCursor
            }

            // A hairline that only appears on hover — visible enough to say
            // "this is draggable", quiet enough not to be a permanent line
            // across the top of the dock.
            Rectangle {
                anchors.centerIn: parent
                width: root.horizontal ? 46 : 3
                height: root.horizontal ? 3 : 46
                radius: 1.5
                color: Qt.rgba(1, 1, 1, gripHover.hovered || gripDrag.active ? 0.45 : 0)

                Behavior on color {
                    ColorAnimation {
                        duration: 140
                    }
                }
            }

            DragHandler {
                id: gripDrag
                target: null
                dragThreshold: 2

                onActiveChanged: {
                    if (gripDrag.active) {
                        grip.startSize = root.baseIconSize;
                    } else {
                        root.iconSizeRequested(root.baseIconSize);
                        // The reservation held still through the gesture so the
                        // desktop was not reflowed sixty times a second; this
                        // is where it catches up, once.
                        root._latchedExtent = root.restExtent;
                        root.surfaceExtent = root.wantedSurface;
                    }
                }

                onCentroidChanged: {
                    if (!gripDrag.active)
                        return;
                    // Delta from where the drag STARTED, against the size the
                    // dock had then. Using the live size instead makes the
                    // gesture compound with itself and the dock runs away from
                    // the pointer.
                    const d = root.horizontal ? -(gripDrag.centroid.position.y - gripDrag.centroid.pressPosition.y) : (gripDrag.centroid.position.x - gripDrag.centroid.pressPosition.x);
                    const dir = (root.edge === Qt.BottomEdge || root.edge === Qt.RightEdge) ? 1 : -1;
                    // Emitted, not assigned. Assigning root.baseIconSize here
                    // would destroy its binding to the config exactly as the
                    // settings panel used to, and the dock would stop
                    // following its own config file after one drag.
                    root.iconSizeLive(Math.max(root.minIconSize, Math.min(root.maxIconSizeAllowed, grip.startSize + d * dir)));
                }
            }
        }

        Repeater {
            id: rowItems
            model: root.items

            DockItem {
                id: item

                required property int index
                required property var modelData

                maxIconSize: root.maxIconSize
                restIconSize: root.baseIconSize
                launcherIcon: root.launcherIcon
                entry: item.modelData.entry
                kind: item.modelData.kind ?? "app"
                folder: item.modelData.folder ?? ""
                fallbackLabel: item.modelData.label ?? item.modelData.key
                launching: root.launching[item.modelData.key] === true
                iconOverride: root.iconOverrides[item.modelData.key] ?? ""
                toplevels: item.modelData.toplevels
                iconSize: root.layout.sizes[item.index] ?? root.baseIconSize
                edge: root.edge
                // The padding the dock keeps between the row and the outside
                // of its background — the strip the running indicator lives in.
                // The item is laid out flush with the icons and cannot see it.
                edgeInset: content.bgPad + content.edgeGap

                // Dim the icon being dragged so the gap it leaves reads as a
                // hole it came out of, rather than as the row having lost one.
                opacity: drag.active && drag.fromIndex === item.index ? 0.35 : 1

                // The item spans from the surface edge down to the row's
                // baseline; DockItem anchors its icon to whichever end faces
                // the screen edge, so the icon rests on the baseline and grows
                // away from it.
                tornOff: drag.active && drag.fromIndex === item.index && drag.tornOff
                x: root.horizontal ? (root.layout.offsets[item.index] ?? 0) : (root.edge === Qt.LeftEdge ? content.edgeGap + content.bgPad : 0)
                y: root.horizontal ? (root.edge === Qt.BottomEdge ? 0 : content.edgeGap + content.bgPad) : (root.layout.offsets[item.index] ?? 0)
                width: root.horizontal ? item.iconSize : content.thick - content.edgeGap - content.bgPad
                height: root.horizontal ? content.thick - content.edgeGap - content.bgPad : item.iconSize

                onActivated: {
                    if (item.modelData.kind === "launcher") {
                        root.launcherActivated();
                        return;
                    }
                    if (item.modelData.kind === "folder") {
                        stack.toggleFor(item.modelData.folder, item.x + item.width / 2);
                        return;
                    }
                    if (item.modelData.kind === "separator")
                        return;

                    const tls = item.modelData.toplevels;
                    if (tls.length === 0) {
                        if (item.modelData.entry) {
                            item.modelData.entry.execute();
                            root.beginLaunch(item.modelData.key);
                        }
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

                onLaunchTimedOut: root.endLaunch(item.modelData.key)

                onDragStarted: {
                    // Separators and folders do not reorder; everything else
                    // does.
                    //
                    // ⚠️ AN UNPINNED APP IS DRAGGABLE TOO, and dropping it is
                    // how it gets pinned. It used to be refused outright on the
                    // grounds that ordering something transient is meaningless
                    // — true, and the answer is not to refuse the gesture but
                    // to make it MEAN something: an app on the dock only
                    // because it is running becomes a permanent resident at
                    // wherever you put it down. That is the shortest path from
                    // "I use this a lot" to "keep it", and it is the one macOS
                    // offers.
                    // The launcher is a fixed slot. Dragging it would either
                    // reorder something that is not in the pinned list or
                    // remove a control the dock guarantees is there.
                    if (item.modelData.kind !== "app")
                        return;
                    drag.fromIndex = item.index;
                    drag.toIndex = item.index;
                    drag.wasUnpinned = !item.modelData.pinned;
                    drag.active = true;
                }
                onDragMoved: (axisPos, crossPos) => {
                    if (!drag.active)
                        return;
                    // Distance from the screen edge the dock sits on. Both
                    // coordinates arrive in the window's frame, and the window
                    // is anchored to that edge and no longer resizes during a
                    // drag — so this is the one measure the gesture cannot move.
                    const edgeDist = root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - crossPos : crossPos) : (root.edge === Qt.RightEdge ? root.width - crossPos : crossPos);
                    // Torn off once the pointer is clear of the dock by half an
                    // icon. Expressed against what the dock OCCUPIES rather
                    // than as a tuned constant, so it stays correct at every
                    // icon size and edge gap.
                    // 🔴 HALF AN ICON WAS FAR TOO LITTLE. Removing an app from
                    // the dock is destructive and it was happening on a slip:
                    // nudge an icon up while reordering and it was gone. The
                    // threshold is the SCREEN'S CENTRE now — you have to mean
                    // it, and the distance is one nobody reaches by accident.
                    drag.tornOff = edgeDist > root.tearThreshold;
                    // Clearly out of the dock, whether or not far enough to
                    // remove. This is what separates "I meant to take it out"
                    // from "I was shuffling the order and wobbled".
                    // ⚠️ MORE THAN HALFWAY TO THE THRESHOLD. At "clear of the
                    // dock by one icon" the refusal fired on an 85px nudge, and
                    // an icon that vanishes and comes back reads as an
                    // accidental removal even though nothing was removed. The
                    // answer only appears once the gesture was plainly aimed
                    // at getting rid of the thing.
                    drag.attempted = edgeDist > root.restExtent + root.tearThreshold * 0.5;
                    if (!drag.tornOff)
                        drag.toIndex = root.indexNear(axisPos);
                }
                onDragEnded: drag.commit()

                // The two answers to a removal gesture. Which one plays is
                // decided by how far the icon went; the icon itself decides
                // what that looks like.
                onDropRefused: item.opacity = 1
                onDropAccepted: root.setPinned(item.modelData.kind === "folder" ? item.modelData.folder : (item.modelData.pinId ?? item.modelData.key), false)

                // The separator resizes the dock, exactly as it does on macOS.
                onSeparatorPressed: {
                    sepResize.active = true;
                    sepResize.start = root.baseIconSize;
                    sepResize.startEdgeDist = -1;
                }

                onSeparatorMoved: (sceneY, sceneX) => {
                    // Distance from the screen edge the dock is anchored to.
                    // That edge does not move when the surface resizes, so this
                    // is the one measure the gesture cannot contaminate.
                    const d = root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - sceneY : sceneY) : (root.edge === Qt.RightEdge ? root.width - sceneX : sceneX);
                    if (sepResize.startEdgeDist < 0) {
                        sepResize.startEdgeDist = d;
                        return;
                    }
                    // 🔴 GAIN OF TWO, AND IT IS NOT A FEEL ADJUSTMENT — AT 1:1
                    // THE DOCK COULD NOT REACH ITS OWN MINIMUM.
                    //
                    // The divider is grabbed at the icons' CENTRE line, which
                    // sits `edgeGap + bgPad + iconSize/2` from the screen edge.
                    // Shrink the dock by 1px at 1:1 and that line only descends
                    // by half a pixel — so the pointer runs out of screen long
                    // before the dock runs out of size. Measured on this
                    // machine: from 128px the drag reached 78 and then did
                    // nothing at all for seven further steps because the cursor
                    // was pinned at y=1151 on a 1152-tall output. Reported as
                    // "it stops triggering when hovering towards the edge of
                    // the screen where it's hidden", and that is exactly what
                    // it is.
                    //
                    // Doubling the gain makes the divider track the pointer
                    // one-for-one — d_divider = bgPad + size/2, so Δsize = 2Δd
                    // means Δd_divider = Δd — which is both the fix and the
                    // reason macOS's handle feels glued to the cursor.
                    root.iconSizeLive(Math.max(root.minIconSize, Math.min(root.maxIconSizeAllowed, sepResize.start + 2 * (d - sepResize.startEdgeDist))));
                }

                onSeparatorReleased: {
                    root.iconSizeRequested(root.baseIconSize);
                    // 🔴 ALL OF IT. `start` was cleared here and
                    // `startEdgeDist` was not, and the reveal used to be held
                    // out by `startEdgeDist >= 0` — a value that is only ever
                    // negative before the first frame of a drag. So one resize
                    // pinned the dock open for the rest of the process's life:
                    // auto-hide stopped working and toggling the setting off
                    // and on could not help, because the term was ORed in
                    // beside it. Reported as "after changing its size via the
                    // separator it stopped auto-hiding".
                    sepResize.active = false;
                    sepResize.start = 0;
                    sepResize.startEdgeDist = -1;
                }
            }
        }
    }

    QtObject {
        id: sepResize

        /*! A divider drag is in progress.

            ⚠️ A FLAG SET BY THE GESTURE, NOT A COORDINATE THAT HAPPENS TO BE
            SET. The reveal used to ask `startEdgeDist >= 0`, which is a
            question about a measurement, not about whether anything is being
            dragged — and a measurement that is only negative before the first
            frame of a drag answers "yes, still resizing" forever afterwards.
            One resize and the dock never auto-hid again. Whether a gesture is
            running is the gesture's own business to state. */
        property bool active: false

        // The size the dock had when this drag began. Measuring each frame
        // against the LIVE size instead makes the gesture compound with itself
        // and the dock runs away from the pointer.
        property real start: 0
        property real startEdgeDist: -1
    }

    // ── Reordering ──────────────────────────────────────────────────────
    QtObject {
        id: drag

        property bool active: false
        property bool tornOff: false
        property bool wasUnpinned: false
        /*! Dragged clearly out of the dock, but not far enough to remove. */
        property bool attempted: false
        property int fromIndex: -1
        property int toIndex: -1

        function commit(): void {
            if (!drag.active) {
                drag.reset();
                return;
            }
            const from = drag.fromIndex;
            const to = drag.toIndex;
            const removed = drag.tornOff;
            const tried = drag.attempted;
            const wasUnpinned = drag.wasUnpinned;
            drag.reset();
            if (from < 0)
                return;

            const cell = rowItems.itemAt(from);

            // Dragged past the threshold: the icon's own pixels are blown
            // apart, and it is unpinned when they land. Unpinning first would
            // destroy the item — and with it the artwork the burst is made of —
            // before a single frame had drawn.
            if (removed) {
                if (cell)
                    cell.vaporise();
                else {
                    const it = root.items[from];
                    if (it)
                        root.setPinned(it.kind === "folder" ? it.folder : (it.pinId ?? it.key), false);
                }
                return;
            }

            // Dragged out but not far enough. The gesture is REFUSED, and it
            // has to look like an answer rather than like a dropped frame: the
            // icon switches off like a CRT and comes back in its slot.
            if (tried && cell) {
                cell.refuse();
                return;
            }

            // An app that was only on the dock because it is running, put down
            // somewhere deliberate: that is a request to keep it.
            if (wasUnpinned) {
                const it = root.items[from];
                if (!it)
                    return;
                const id = it.pinId ?? it.key;
                const next = root.pinnedClean.slice();
                // `to` indexes the whole row — pinned apps, then running ones,
                // then the separator and folders — so it has to be clamped into
                // the pinned list's own range before it means anything there.
                next.splice(Math.max(0, Math.min(next.length, to)), 0, id);
                root.pinnedReordered(next);
                return;
            }

            if (from === to || to < 0)
                return;

            const next = root.pinnedClean.slice();
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
            drag.tornOff = false;
            drag.attempted = false;
            drag.wasUnpinned = false;
            drag.fromIndex = -1;
            drag.toIndex = -1;
        }
    }

    /*! Emitted with the new pinned list after a drag, a pin or an unpin. */
    signal pinnedReordered(var order)

    /*! Emitted when the resize grip is released, so the size can be persisted.
        Emitted on RELEASE rather than continuously: writing a config file on
        every frame of a drag is a hundred writes for one decision. */
    signal iconSizeRequested(real size)

    /*! Emitted continuously while the resize grip is dragged. */
    signal iconSizeLive(real size)

    /*! Emitted when the folder view mode is changed from a stack's menu. */
    signal folderViewRequested(string mode)

    /*! The dock asks to be hidden or shown; the config decides. */
    signal autoHideRequested(bool on)

    /*! Right-click on empty dock space. */
    signal settingsRequested()

    /*! Add or remove `key` from the pinned list and publish the result. */
    /*! Emitted with the new folder list when a stack is added or removed.
        ⚠️ NOT `foldersChanged` — that is the auto-generated change signal for
        the `folders` property, and declaring it is a hard load error. */
    signal foldersUpdated(var list)

    /*! Is this something we can put in the pinned list and find again? */
    function _usableId(key: var): bool {
        return typeof key === "string" && key.length > 0 && key !== "undefined" && key !== "null";
    }

    function setPinned(key: string, pinned: bool): void {
        // 🔴 THE STRING "undefined" GOT WRITTEN INTO THE PINNED LIST. TWICE.
        // A running application with no matching `.desktop` has no key, and
        // both routes that pin something — the menu's "Keep in Dock" and
        // dropping an unpinned running app back onto the row — passed that
        // straight through. QML stringifies it on the way into JSON, so the
        // config came back with `"pinned": [… "undefined", "undefined", …]`,
        // and every restart since drew two tiles lettered U that no click could
        // ever launch and no menu could remove, because unpinning them looks up
        // a key that never matched anything in the first place.
        //
        // Refused here rather than at each call site: this is the only function
        // that writes the list, so this is the only place that can be sure.
        if (!root._usableId(key)) {
            console.warn("charis-dock: refusing to pin an item with no id —", key);
            return;
        }

        // A folder lives in `folders`, not `pinned`. Routing it through the
        // app list would quietly drop it: the key is an absolute path, no
        // DesktopEntry resolves it, and it would come back as an unlaunchable
        // tile after the next restart.
        const fi = root.folders.indexOf(key);
        if (fi !== -1 || key.startsWith("/")) {
            if (!pinned && fi !== -1) {
                const f = root.folders.slice();
                f.splice(fi, 1);
                root.foldersUpdated(f);
            } else if (pinned && fi === -1) {
                root.foldersUpdated(root.folders.concat([key]));
            }
            return;
        }

        const cur = root.pinnedClean.slice();
        const i = cur.indexOf(key);
        if (pinned && i === -1) {
            // Prefer the desktop entry's own id: a running app's appId is not
            // always its .desktop id, and pinning the appId would produce an
            // entry that never resolves to an icon after a restart.
            const entry = DesktopEntries.byId(key);
            cur.push(entry ? entry.id : key);
        } else if (!pinned && i !== -1) {
            cur.splice(i, 1);
        } else {
            return;
        }
        root.pinnedReordered(cur);
    }

    /*! Emitted when files are dropped on the dock background rather than on an
        icon — the caller decides whether that means "pin this folder". */
    signal urlsDropped(var urls, int index)

    /*! Index of the pinned slot nearest \a axisPos, clamped to the pinned run. */
    function indexNear(axisPos: real): int {
        let best = 0;
        let bestD = Infinity;
        const pinnedCount = root.pinnedClean.length;
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
        viewMode: root.folderView
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
        onPinRequested: (key, pinned) => root.setPinned(key, pinned)
        onViewModeRequested: mode => root.folderViewRequested(mode)
        onAutoHideRequested: on => root.autoHideRequested(on)
        onSettingsRequested: root.settingsRequested()
        folderView: root.folderView
        autoHide: root.autoHide
        recentFolders: root.recentFolders
        allToplevels: ToplevelManager.toplevels.values
        onLauncherAction: (a, path) => root.launcherAction(a, path)
        anchors.fill: parent
        bandOffset: root.bandThickness
        revealed: reveal.value
    }
}
