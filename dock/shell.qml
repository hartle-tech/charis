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
import QtQuick

ShellRoot {
    id: root

    // Shared, because `Variants` builds one Dock per screen and an IpcHandler
    // per dock would register the same target several times. The handler lives
    // here and the docks bind to these.
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

    // Pinned apps, read from a plain JSON file so it can be edited by hand,
    // by a settings UI, or by the dock itself when icons are reordered —
    // without any of the three needing to know about the others.
    FileView {
        id: config
        path: `${Quickshell.env("HOME")}/.config/charis/dock.json`
        watchChanges: true
        onFileChanged: config.reload()
        // A missing config is the FIRST-RUN case, not an error. Falling over
        // here would mean the dock never appears on a fresh install, which is
        // the one moment it most needs to.
        onLoadFailed: err => config.writeAdapter()

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
            baseIconSize: cfg.iconSize
            magnification: cfg.magnification
            autoHide: cfg.autoHide
            folders: cfg.folders
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
}
