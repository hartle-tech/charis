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
        target: (hover.hovered || root.debugging) ? 1 : 0
        response: 0.28 * root._resp
        damping: 1.0
    }

    Spring {
        id: reveal
        // 1 = fully out, 0 = tucked away. Slightly under-damped so the dock
        // arrives with a hint of settle instead of stopping dead.
        target: (!root.autoHide || hover.hovered || root.debugging) ? 1 : 0
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
    }

    readonly property var layout: row.metrics

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

    onRestExtentChanged: if (!gripDrag.active)
        root._latchedExtent = root.restExtent

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
    /*! Distance between the screen edge and the dock. 0 sits flush, which is
        the default because macOS's dock touches the edge and a floating strip
        with a gap under it is the look of a third-party imitation. */
    property real edgeGap: 0

    /*! Padding between the icons and the dock's background edge. */
    readonly property real bgPad: root.spacing * 1.5

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
    readonly property real tearZone: 240

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
    readonly property bool tuckedAway: root.autoHide && !root.debugging && !hover.hovered && reveal.value < 0.005

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
    readonly property real wantedSurface: root.bandThickness + root.tearZone + root.popupReserve
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

            x: root.horizontal ? (content.width - width) / 2 : (root.edge === Qt.LeftEdge ? content.edgeGap : content.bandStart)
            y: root.horizontal ? (root.edge === Qt.BottomEdge ? content.bandStart : content.edgeGap) : (content.height - height) / 2

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
                    root.iconSizeLive(Math.max(24, Math.min(128, grip.startSize + d * dir)));
                }
            }
        }

        Repeater {
            model: root.items

            DockItem {
                id: item

                required property int index
                required property var modelData

                maxIconSize: root.maxIconSize
                restIconSize: root.baseIconSize
                entry: item.modelData.entry
                kind: item.modelData.kind ?? "app"
                folder: item.modelData.folder ?? ""
                fallbackLabel: item.modelData.label ?? item.modelData.key
                launching: root.launching[item.modelData.key] === true
                iconOverride: root.iconOverrides[item.modelData.key] ?? ""
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
                tornOff: drag.active && drag.fromIndex === item.index && drag.tornOff
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
                    // Only pinned apps reorder. Dragging a running-but-unpinned
                    // icon around would imply an order that vanishes the moment
                    // the app quits, and dragging the separator is meaningless.
                    if (item.modelData.kind !== "app" || !item.modelData.pinned)
                        return;
                    drag.fromIndex = item.index;
                    drag.toIndex = item.index;
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
                    drag.tornOff = edgeDist > root.restExtent + root.baseIconSize * 0.4;
                    if (!drag.tornOff)
                        drag.toIndex = root.indexNear(axisPos);
                }
                onDragEnded: drag.commit()

                // The separator resizes the dock, exactly as it does on macOS.
                onSeparatorPressed: {
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
                    root.iconSizeLive(Math.max(24, Math.min(128, sepResize.start + (d - sepResize.startEdgeDist))));
                }

                onSeparatorReleased: {
                    root.iconSizeRequested(root.baseIconSize);
                    sepResize.start = 0;
                }
            }
        }
    }

    QtObject {
        id: sepResize
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
            drag.reset();
            if (from < 0)
                return;

            // Dragged clear of the dock and released: unpin it, as on macOS.
            if (removed) {
                const it = root.items[from];
                if (it)
                    root.setPinned(it.kind === "folder" ? it.folder : (it.pinId ?? it.key), false);
                return;
            }

            if (from === to || to < 0)
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
            drag.tornOff = false;
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

    /*! Right-click on empty dock space. */
    signal settingsRequested()

    /*! Add or remove `key` from the pinned list and publish the result. */
    /*! Emitted with the new folder list when a stack is added or removed.
        ⚠️ NOT `foldersChanged` — that is the auto-generated change signal for
        the `folders` property, and declaring it is a hard load error. */
    signal foldersUpdated(var list)

    function setPinned(key: string, pinned: bool): void {
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

        const cur = root.pinned.slice();
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
        onSettingsRequested: root.settingsRequested()
        folderView: root.folderView
        anchors.fill: parent
        bandOffset: root.bandThickness
        revealed: reveal.value
    }
}
