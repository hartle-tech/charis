// Charis Dock — standalone Quickshell entry point.
//
// ⚠️ DELIBERATELY ITS OWN PROCESS, not a module inside somebody's bar.
//
// A dock welded into a shell configuration can only be used by people running
// that shell. Its own instance is independently startable, testable and
// crashable, works alongside any bar, and is what lets the same code be a
// product rather than one person's dotfile.
//
// Run it by hand:
//   QML2_IMPORT_PATH=<…>/qml quickshell -p code/nix/pkgs/charis/dock

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Charis
import QtQuick

ShellRoot {
    id: root

    // Shared, because `Variants` builds one Dock per screen and an IpcHandler
    // per dock would register the same target several times. The handler lives
    // here and the docks bind to these.
    property bool settingsOpen: false
    property var settingsDock: null
    property real magnifyOverride: -1
    property string stackRequest: ""
    property int stackSerial: 0

    // ── Scripting surface ───────────────────────────────────────────────
    //
    // Not only a test hook, though it started as one: this machine has no
    // cursor-warping tool and Hyprland's own dispatcher reports success while
    // moving nothing, so a hover state could not otherwise be reached without a
    // human hand on the mouse. Having built it, a dock that can be driven from
    // a script is worth keeping — bind a key to `openStack ~/Downloads` and it
    // is a launcher.
    //
    //   quickshell ipc -p <dock-config-dir> call dock openStack /path
    IpcHandler {
        target: "dock"

        function openStack(path: string): void {
            root.stackRequest = path;
            root.stackSerial += 1;
        }

        /*!
            Live frame statistics, as JSON.

            Reported from the shell's OWN FrameBudget rather than from an
            external profiler, because what matters is the frame time this
            process actually observes — an external sampler measures the
            compositor's cadence, which is not the same thing and stays smooth
            while the dock stutters.
        */
        function metrics(): string {
            return JSON.stringify({
                fps: FrameBudget.fps,
                medianFrameMs: FrameBudget.pressure > 0 ? (1000 / Math.max(1, FrameBudget.fps)) : 0,
                quality: FrameBudget.quality,
                pressure: FrameBudget.pressure,
                stressed: FrameBudget.stressed,
                ticking: Ticker.running,
                subscribers: Ticker.subscriberCount
            });
        }

        /*!
            Start and stop a frame-time trace, and hand back every delta.

            The only honest answer to "is the motion smooth" from outside the
            process. A screen recorder cannot answer it: wf-recorder pushes
            captured frames through an `fps` filter that duplicates them to
            reach the requested rate, so it reports its own capture cadence no
            matter what the dock is doing.
        */
        function traceStart(): void {
            FrameBudget.startTrace();
        }

        function traceStop(): string {
            return FrameBudget.stopTrace();
        }

        /*! Tell FrameBudget the real refresh rate, so `pressure` is measured
            against this display's budget rather than the 60Hz default. */
        function setRefresh(hz: real): void {
            FrameBudget.refreshRate = hz;
            FrameBudget.recalibrate();
        }

        /*! Pin or unpin an app by desktop id, from anywhere.

            Exposed over IPC so a launcher, a file manager or a keybind can add
            something to the dock without the dock having to integrate with any
            of them — "Pin to Dock" belongs in whatever menu the user is already
            looking at, and this is the seam that lets that exist. */
        function pin(id: string): void {
            const cur = cfg.pinned.slice();
            if (cur.indexOf(id) === -1) {
                cur.push(id);
                cfg.pinned = cur;
                config.writeAdapter();
            }
        }

        function unpin(id: string): void {
            const cur = cfg.pinned.slice();
            const i = cur.indexOf(id);
            if (i !== -1) {
                cur.splice(i, 1);
                cfg.pinned = cur;
                config.writeAdapter();
            }
        }

        /*!
            Announce that `id` is starting, so its icon bounces until a window
            appears.

            The dock already does this for launches it performs itself, but it
            is not the only thing that starts applications: a launcher, a
            terminal, a keybind or a file manager's "Open With" all leave the
            dock with no idea anything is happening, and the user watching the
            dock sees nothing for the several seconds a cold start takes. This
            is the seam that lets any of them say so.

            Lower-cased on the way in, because item keys are normalised for
            matching against Wayland appIds — `org.gnome.Nautilus` from a
            caller has to find `org.gnome.nautilus` in the map.
        */
        function bounce(id: string): void {
            if (root.settingsDock)
                root.settingsDock.beginLaunch(id.toLowerCase().replace(/\.desktop$/, ""));
        }

        /*! Stop bouncing `id` — for a caller that knows the app finished
            starting, or failed to. Without a window of its own the dock cannot
            tell the difference, and would otherwise wait out the timeout. */
        function endBounce(id: string): void {
            if (root.settingsDock)
                root.settingsDock.endLaunch(id.toLowerCase().replace(/\.desktop$/, ""));
        }

        /*! The configuration the dock is ACTUALLY using, as opposed to what is
            on disk. The two diverging silently is exactly the class of bug this
            exists to catch. */
        function config(): string {
            return JSON.stringify({
                iconSize: cfg.iconSize,
                magnify: cfg.magnify,
                iconPadding: cfg.iconPadding,
                magnification: cfg.magnification,
                edgeGap: cfg.edgeGap,
                autoHide: cfg.autoHide,
                pinned: cfg.pinned,
                loaded: root.configFileLoaded,
                // The glass's backdrop, and whether it resolved. A toggle that
                // silently has nothing to refract is indistinguishable from a
                // toggle that does nothing, which is what it was.
                wallpaperFrom: cfg.wallpaperFrom,
                wallpaper: root.livePaper,
                useGlass: cfg.useGlass,
                glassReady: root.settingsDock ? root.settingsDock.glassDiag : "no dock",
                // What the DOCK believes, as opposed to what the config says.
                // These diverging is the bug this readout exists to expose.
                dockIconSize: root.settingsDock ? root.settingsDock.baseIconSize : -1,
                dockEdgeGap: root.settingsDock ? root.settingsDock.edgeGap : -1
            });
        }

        /*!
            Where every item in the row actually is, in SCREEN logical
            coordinates, as JSON.

            🔴 EVERY HARNESS THAT DROVE THIS DOCK COMPUTED ICON POSITIONS FROM
            THE CONFIG, AND EVERY ONE OF THEM WENT WRONG. The row is centred in
            the surface, so its start depends on the total width — which depends
            on the icon size, the spacing, how many apps are running, whether a
            separator is present, and now on the separator being 0.34 of a cell
            rather than a whole one. The last change moved the first icon 133
            pixels and a scripted drag pressed on bare panel: the pointer moved,
            the button went down, and the recording showed a dock doing nothing.

            The dock knows where its icons are. Asking it is not a test hook
            bolted on — it is the same seam `pin` and `bounce` use, and any
            external launcher wanting to point at a dock icon needs it too.
        */
        function layout(): string {
            const d = root.settingsDock;
            if (!d)
                return "[]";
            const out = [];
            for (let i = 0; i < d.count; ++i) {
                const it = d.items[i];
                out.push({
                    key: it.key,
                    kind: it.kind,
                    pinned: it.pinned === true,
                    // ⚠️ Raw, not Math.round()ed. Rounding here turned every
                    // number into JSON `null` — the values were right the whole
                    // time and the readout said the geometry was missing.
                    centre: d.itemCentre(i),
                    icon: d.itemIcon(i),
                    iconOk: d.itemIconOk(i),
                    cross: d.itemCross(),
                    box: d.itemBox(i),
                    box: d.itemBox(i),
                    slot: d.itemSlot(i)
                });
            }
            return JSON.stringify({
                items: out,
                panel: d.panelRect()
            });
        }

        /*! Every hover transition the dock has seen, with the pointer's
            distance from the screen edge and what the dock decided.

            The only way to match "it hid while I was hovering it" to what the
            mouse was doing. A blink is invisible in a screenshot, absent from
            the journal, and indistinguishable from auto-hide being switched
            off. */
        function hoverLog(): string {
            const d = root.settingsDock;
            if (!d)
                return "{}";
            return JSON.stringify({
                longestBlink: d.longestBlink,
                revealMax: d.revealMax,
                revealMin: d.revealMin,
                events: d.hoverLog
            });
        }

        function hoverLogClear(): void {
            const d = root.settingsDock;
            if (d) {
                d.hoverLog = [];
                d.longestBlink = 0;
                d.revealMax = 0;
                d.revealMin = 1;
                // ⚠️ And the pending leave, or the first enter after a clear is
                // timed against a departure from before it — which reported a
                // 16.7-second "blink" and made the readout call a healthy rule
                // about to fail.
                d._leftAt = 0;
            }
        }

        /*! Open the settings window. Also reachable by right-clicking empty
            space on the dock — an IPC-only settings panel is one nobody finds. */
        function settings(): void {
            root.settingsOpen = true;
        }

        function closeStack(): void {
            root.stackRequest = "";
            root.stackSerial += 1;
        }

        // Park the magnification as if the pointer were at `x`, so a hover can
        // be screenshotted. Negative restores real pointer tracking.
        function magnifyAt(x: real): void {
            root.magnifyOverride = x;
        }
    }

    /*!
        The file manager, and Finder's menu behind it.

        ⚠️ `xdg-open` ON A DIRECTORY, NOT A HARD-CODED APPLICATION. Which
        program opens a folder is the user's choice and the desktop already
        records it; a dock that launches Nautilus because the author used
        Nautilus is one more thing to reconfigure. (Worth knowing: on this
        machine `xdg-mime query default inode/directory` answers
        `org.gnome.baobab` — the Disk Usage Analyser — so the setting is not
        merely theoretical, it is wrong here and the dock will faithfully honour
        it until it is fixed.)
    */
    function openFiles(path: string): void {
        Quickshell.execDetached(["xdg-open", path]);
    }

    /*! The desktop id of whatever opens a folder here.

        ⚠️ ASKED, NOT ASSUMED. The launcher's icon has to be the icon of the
        thing clicking it actually opens, or the dock is lying about its own
        first slot — and "system-file-manager" is a name plenty of themes do
        not carry, which is how that slot ended up a blank blue tile. */
    property string filesEntryId: ""

    Process {
        id: filesHandler
        running: true
        command: ["/bin/sh", "-c", "xdg-mime query default inode/directory 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: root.filesEntryId = text.trim().replace(/\.desktop$/, "")
        }
    }

    readonly property string filesIcon: {
        const e = root.filesEntryId === "" ? null : DesktopEntries.byId(root.filesEntryId);
        return e && e.icon ? e.icon : "system-file-manager";
    }

    /*! Recently-visited folders, newest first.

        Read from the freedesktop recent-files store that every GTK and Qt file
        dialog already writes. Nothing here has to be told what the user has
        been doing — the desktop knows, and a "Recent Folders" list assembled
        from anywhere else would disagree with every other application's. */
    property var recentFolders: []

    Process {
        id: recents
        running: true
        // ⚠️ /bin/sh, NOT "sh". Quickshell resolves a bare name against the
        // process's PATH, and a systemd user unit's PATH is whatever the unit
        // says — which for a while was hyprland's bin and nothing else. The
        // command then fails with "binary could not be found" and the recent
        // list is silently empty. /bin/sh is the one path every distribution
        // guarantees.
        command: ["/bin/sh", "-c", "tr '<' '\\n' < \"$HOME/.local/share/recently-used.xbel\" 2>/dev/null | grep -o 'file:///[^\"]*' | tail -80"]
        stdout: StdioCollector {
            onStreamFinished: {
                const seen = {};
                const dirs = [];
                for (const raw of text.trim().split("\n")) {
                    if (!raw)
                        continue;
                    const dir = decodeURIComponent(raw).replace(/\/[^\/]*$/, "");
                    if (dir && !seen[dir]) {
                        seen[dir] = true;
                        dirs.push(dir);
                    }
                    if (dirs.length >= 6)
                        break;
                }
                root.recentFolders = dirs;
            }
        }
    }

    Timer {
        // The recent list changes as the user works; re-read it occasionally
        // rather than once at startup, and never on a timer fast enough to
        // matter for power.
        interval: 60000
        running: true
        repeat: true
        onTriggered: recents.running = true
    }

    /*! Finder's menu, minus the parts that need a file manager's own UI. */
    function runLauncherAction(action: string, path: string): void {
        const home = Quickshell.env("HOME");
        if (action === "open" && path !== "")
            root.openFiles(path);
        else if (action === "new")
            root.openFiles(home);
        else if (action === "goto")
            root.openFiles(home);
        else if (action === "find")
            Quickshell.execDetached(["xdg-open", home]);
        else if (action === "connect")
            Quickshell.execDetached(["xdg-open", "network:///"]);
        else if (action === "showAll")
            root.eachToplevel(t => t.activate());
        else if (action === "hide")
            root.eachToplevel(t => t.minimized = true);
    }

    function eachToplevel(fn: var): void {
        const list = ToplevelManager.toplevels.values;
        for (const t of list)
            fn(t);
    }

    /*! The wallpaper the glass refracts: the explicit path when one is given,
        otherwise whatever `wallpaperFrom` currently names. */
    readonly property string livePaper: cfg.wallpaper !== "" ? cfg.wallpaper : root.paperFromFile

    property string paperFromFile: ""

    FileView {
        // ⚠️ `watchChanges` plus an explicit reload. FileView does not re-read
        // on its own, and a wallpaper that rotates every ten minutes would
        // otherwise be sampled once at startup and then be wrong for the rest
        // of the session — with the glass looking subtly, unexplainably off.
        path: cfg.wallpaperFrom
        watchChanges: cfg.wallpaperFrom !== ""
        onFileChanged: reload()
        onLoaded: root.paperFromFile = text().trim()
        onLoadFailed: root.paperFromFile = ""
    }

    // Pinned apps, read from a plain JSON file so it can be edited by hand,
    // by a settings UI, or by the dock itself when icons are reordered —
    // without any of the three needing to know about the others.
    property bool configFileLoaded: false

    // Apply the backdrop blur through the compositor.
    //
    // Hyprland's Lua parser refuses `hyprctl keyword`, and hl.config({...})
    // via the socket reports ok while doing nothing for layer rules — but the
    // decoration table set through `eval` does land. Verified: blur size went
    // 8 → 20 → 2 and the measured detail behind the dock moved with it.
    //
    // ⚠️ execDetached, NOT a Process with `running: true`. Re-asserting `running`
    // on a Process that has already run does not start it again, so the FIRST
    // change applied and every subsequent one silently did not.
    //
    // 🔴 THIS SETS THE COMPOSITOR'S GLOBAL BLUR, NOT THE DOCK'S.
    //
    // Hyprland layer rules can turn blur on for a namespace but cannot give it
    // its own radius, so there is no way to blur harder behind the dock than
    // behind everything else. That makes this slider a system setting wearing a
    // dock setting's clothes: moving it changes every blurred surface on the
    // desktop, and starting the dock silently overwrites whatever the user's
    // own Hyprland configuration chose.
    //
    // It is labelled accordingly in the settings panel. It is not hidden and it
    // is not pretended away, because a control whose true blast radius is only
    // discoverable by noticing your terminal changed is worse than one that
    // says so.
    //
    // ⚠️ execDetached, NOT a Process with `running: true`. Re-asserting `running`
    // on a Process that has already run does not start it again, so the FIRST
    // change applied and every subsequent one silently did not.
    //
    // ⚠️ The systemd unit must put hyprctl on PATH. It used to be an absolute
    // /nix/store path hard-coded here, which worked on exactly one machine and
    // made the dock un-shippable to any other distribution — the opposite of
    // what this project is for. A bare name fails silently if PATH is empty, so
    // the unit sets it; see modules/home/charis-dock.nix.
    function applyBackdropBlur(): void {
        Quickshell.execDetached(["hyprctl", "eval", `hl.config({ decoration = { blur = { size = ${Math.round(cfg.backdropBlur)}, passes = ${cfg.backdropBlurPasses} } } })`]);
    }

    // ⚠️ Called explicitly, not driven by a Connections on the adapter.
    // `Connections { target: cfg }` on a JsonAdapter property did not fire at
    // all here — the slider moved, the value reached the config, and the
    // compositor was never told. Called from the settings handlers and once at
    // startup, which is code that provably runs.
    Component.onCompleted: root.applyBackdropBlur()

    FileView {
        id: config
        path: `${Quickshell.env("HOME")}/.config/charis/dock.json`
        watchChanges: true
        onFileChanged: config.reload()
        // A missing config is the FIRST-RUN case, not an error. Falling over
        // here would mean the dock never appears on a fresh install, which is
        // the one moment it most needs to.
        onLoaded: {
            root.configFileLoaded = true;
            root.applyBackdropBlur();
        }
        // ⚠️ Only seed on a genuinely MISSING file. `writeAdapter()` on any
        // failure will happily write the adapter's DEFAULTS over a config that
        // merely failed to parse this once — silently destroying the user's
        // dock because of a transient read.
        onLoadFailed: err => {
            if (err === FileViewError.FileNotFound)
                config.writeAdapter();
        }

        // ⚠️ `adapter:`, NOT a bare child. FileView's default property is its
        // children, so `JsonAdapter { … }` written without this assignment is
        // constructed, parented, and never connected to the file — every
        // property silently keeps its declared default and the config appears
        // to be ignored. Nothing warns: the file loads fine, the adapter
        // exists fine, they are simply not attached to each other. It cost an
        // hour here, visible only because a panel came out 115px tall, which
        // is exactly `48 * 1.9 + 24` — the default icon size, not the
        // configured one.
        adapter: JsonAdapter {
            id: cfg
            property list<string> pinned: ["firefox", "chromium-browser", "org.gnome.Nautilus", "kitty", "code", "obsidian"]
            property string edge: "bottom"
            property real iconSize: 48
            property real magnification: 1.9
            property bool autoHide: true
            property list<string> folders: []

            // ── Appearance ──────────────────────────────────────────────
            property real edgeGap: 8

            /*! Whether the row magnifies at all. */
            property bool magnify: true

            /*! Air around the icons inside the panel. Negative derives it from
                the icon size, which is what macOS's proportions amount to. */
            property real iconPadding: -1
            /*! Gap between icons.
                🔴 8 WAS TOO LOOSE. With `bgPad` at 1.5x the spacing, 8 put 12
                pixels of panel above and below the icons and 8 between every
                pair — a row that reads as separate buttons rather than as one
                object. macOS sits nearer 4. Reported as wanting the icons, the
                separator and the folders comfortably tighter. */
            property real spacing: 4
            property real cornerRoundness: 0.28
            /*! The desktop wallpaper, for the refracting glass to bend.

                A dock with an exclusive zone has nothing but the wallpaper
                behind it — no window can be there — so this is the complete
                backdrop, not an approximation of one. Empty leaves the glass
                off rather than drawing an invisible nothing, which is what it
                did for its whole existence before this. */
            /*! The fixed file-manager slot at the head of the row. */
            property bool showLauncher: true
            /*! Empty means "whatever opens a folder on this system". */
            property string launcherIcon: ""

            property string wallpaper: ""

            /*! A file whose CONTENTS is the wallpaper's path, watched for
                changes.

                ⚠️ THE WALLPAPER MOVES. On this desktop it rotates per virtual
                desktop and the current one is written to a state file — a
                static path in the config would refract yesterday's picture
                within the hour, which is worse than no glass because it looks
                like a rendering bug. Any desktop that can write its current
                wallpaper to a file can drive this; nothing here knows or cares
                which desktop that is. */
            property string wallpaperFrom: ""

            property string panelColor: "#1e1e1e"
            property real panelOpacity: 0.55
            property string borderColor: "#1affffff"
            property real borderWidth: 1
            property real influenceCells: 2.6

            // ── Material ────────────────────────────────────────────────
            property bool useGlass: false
            property real blurAmount: 12

            // Compositor blur behind the dock. Applied through Hyprland rather
            // than drawn by us: a compositor already has the backdrop and can
            // blur it for free, whereas a shader would need the screen captured
            // into a texture every frame just to blur what is already there.
            // 🔴 8/2 SHIPPED AND IT LOOKED CHEAP. Measured on the running dock,
            // standard deviation of the wallpaper still visible through the
            // panel: 15.0 at size 1, 9.9 at 8/2, 0.85 at 20/4. At the old
            // default the wallpaper's texture was plainly legible through the
            // dock — blur was on, doing almost nothing, and reading as a flat
            // dark tint over a busy photograph. Glass that does not actually
            // diffuse what is behind it is the cheapest-looking thing a dock
            // can do. 16/3 lands where a real frosted panel does.
            property real backdropBlur: 16
            property int backdropBlurPasses: 3

            // ── Behaviour ───────────────────────────────────────────────
            property bool animations: true
            property bool resizable: true
            property string folderView: "grid"

            // { "<desktop id or appId>": "/path/to/image.png" }
            property var iconOverrides: ({})

            property real debugCursor: -1
        }
    }

    // One dock per screen. `Variants` rebuilds this set when monitors come and
    // go, so hot-plugging a display does not leave a dock on a screen that no
    // longer exists — the failure mode being an invisible layer surface
    // holding an exclusive zone on nothing.
    Variants {
        model: Quickshell.screens

        Dock {
            id: dock
            required property var modelData
            screen: dock.modelData

            pinned: cfg.pinned
            iconSize: cfg.iconSize
            magnify: cfg.magnify
            iconPadding: cfg.iconPadding
            // Told, not guessed: the settings window is a separate overlay
            // surface, so opening it takes the pointer off the dock and an
            // auto-hiding dock would tuck away while you configure it.
            settingsOpen: root.settingsOpen
            magnification: cfg.magnification
            autoHide: cfg.autoHide
            folders: cfg.folders
            edgeGap: cfg.edgeGap
            spacing: cfg.spacing
            cornerRoundness: cfg.cornerRoundness
            panelColor: cfg.panelColor
            panelOpacity: cfg.panelOpacity
            borderColor: cfg.borderColor
            borderWidth: cfg.borderWidth
            influenceCells: cfg.influenceCells
            useGlass: cfg.useGlass
            blurAmount: cfg.blurAmount
            wallpaper: root.livePaper
            showLauncher: cfg.showLauncher
            launcherIcon: cfg.launcherIcon === "" ? root.filesIcon : cfg.launcherIcon
            recentFolders: root.recentFolders

            // Click: open the default file manager at home.
            onLauncherActivated: root.openFiles(Quickshell.env("HOME"))

            onLauncherAction: (action, path) => root.runLauncherAction(action, path)

            // Where this surface sits on its output, so the wallpaper the
            // glass refracts can be positioned to line up with the real one
            // rather than starting at the surface's own top-left.
            screenWidth: dock.screen ? dock.screen.width : Screen.width
            screenHeight: dock.screen ? dock.screen.height : Screen.height
            surfaceX: 0
            surfaceY: 0
            animations: cfg.animations
            resizable: cfg.resizable
            folderView: cfg.folderView
            iconOverrides: cfg.iconOverrides
            debugCursor: root.magnifyOverride >= 0 ? root.magnifyOverride : cfg.debugCursor
            stackRequest: root.stackRequest
            stackSerial: root.stackSerial

            // The dock asks; the config decides. Persisting here rather than
            // inside Dock is what lets the same component be driven by a
            // settings UI, or by a caller with a hard-coded list, without it
            // trying to write to a file that caller never had.
            onPinnedReordered: order => {
                cfg.pinned = order;
                config.writeAdapter();
            }

            onIconSizeLive: size => cfg.iconSize = Math.round(size)

            onIconSizeRequested: size => {
                cfg.iconSize = Math.round(size);
                config.writeAdapter();
            }

            onFoldersUpdated: list => {
                cfg.folders = list;
                config.writeAdapter();
            }

            // ⚠️ PERSISTED, like every other setting the dock asks for. A
            // right-click toggle that only lives until the next restart is a
            // worse control than none: it teaches the user the setting does not
            // stick.
            onAutoHideRequested: on => {
                cfg.autoHide = on;
                config.writeAdapter();
            }

            onFolderViewRequested: mode => {
                cfg.folderView = mode;
                config.writeAdapter();
            }

            onSettingsRequested: {
                root.settingsDock = dock;
                root.settingsOpen = true;
            }

            // ⚠️ Adopt the first dock as the one the settings panel drives.
            // Without this, opening settings over IPC left `settingsDock` null,
            // DockSettings' `required property var dock` could not be
            // satisfied, and the window silently never appeared — no error
            // anywhere, because LazyLoader simply had nothing to show.
            Component.onCompleted: if (!root.settingsDock)
                root.settingsDock = dock

            onUrlsDropped: (urls, index) => {
                // Only folders are pinnable. A dropped file that landed on the
                // background rather than on an app icon has no obvious meaning,
                // and inventing one (pin its parent? open it?) is worse than
                // doing nothing.
                const next = cfg.folders.slice();
                let added = false;
                for (const u of urls) {
                    const path = u.replace(/^file:\/\//, "");
                    if (!path.includes(".") && next.indexOf(path) === -1) {
                        next.push(path);
                        added = true;
                    }
                }
                if (added) {
                    cfg.folders = next;
                    config.writeAdapter();
                }
            }
            edge: cfg.edge === "left" ? Qt.LeftEdge : cfg.edge === "right" ? Qt.RightEdge : cfg.edge === "top" ? Qt.TopEdge : Qt.BottomEdge
        }
    }

    // ── Settings ────────────────────────────────────────────────────────
    //
    // 🔴 A LAYER-SHELL PANEL, NOT A FloatingWindow. As a window it was TILED by
    // the compositor to 2708x1012 — on this 34" ultrawide a "0 to 100%" slider
    // became two and a half feet long, which is absurd and which I should have
    // seen without being told. A layer surface has exactly the size it asks
    // for, on any wlroots compositor, and cannot be tiled.
    LazyLoader {
        active: root.settingsOpen && root.settingsDock !== null

        PanelWindow {
            id: settingsWin

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "charis-dock-settings"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            anchors { top: true; bottom: true; left: true; right: true }

            // Dismiss by clicking away from the panel.
            MouseArea {
                anchors.fill: parent
                onClicked: root.settingsOpen = false
            }

            Rectangle {
                anchors.centerIn: parent
                width: 400
                height: Math.min(720, parent.height - 80)
                radius: 16
                color: "#17171b"
                border.color: "#2f2f38"
                border.width: 1

                // Swallow clicks so they do not reach the dismiss layer.
                MouseArea {
                    anchors.fill: parent
                }

                DockSettings {
                    anchors.fill: parent
                    anchors.margins: 2
                    dock: root.settingsDock
                    backdropBlur: cfg.backdropBlur

                    onChanged: (key, value) => {
                        cfg[key] = value;
                        if (key === "backdropBlur" || key === "backdropBlurPasses")
                            root.applyBackdropBlur();
                    }
                    onCommitted: (key, value) => {
                        cfg[key] = value;
                        config.writeAdapter();
                        if (key === "backdropBlur" || key === "backdropBlurPasses")
                            root.applyBackdropBlur();
                    }
                }
            }
        }
    }
}