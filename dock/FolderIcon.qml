pragma ComponentBehavior: Bound

import QtQuick
import Charis

/*!
    A folder, drawn rather than looked up.

    WHY NOT THE ICON THEME. The obvious implementation is
    `Quickshell.iconPath("folder")`, and on this machine it returns an empty
    string — as does every other name tried, including
    `application-x-executable`. Qt has no icon theme configured at all unless a
    platform-theme plugin sets one, and nothing in a bare Wayland session does.
    Papirus-Dark is installed and has `64x64/places/folder.svg` sitting right
    there; Qt simply never looks at it. App icons work only because their
    `.desktop` entries happen to give absolute paths.

    That could be fixed with `QT_QPA_PLATFORMTHEME` and another package, but it
    would be fixing it for THIS machine. A library that intends to look the same
    on any distribution cannot have its folder icon depend on which platform
    theme plugin the user's distro happens to ship, and on whether their icon
    theme is one of the ones that includes a folder. Apple does not use the
    system icon theme for its stacks either — it draws its own.

    So this is drawn from the same primitives as everything else: two squircles
    and a gradient. It costs nothing, it is themeable by one property, and it is
    identical everywhere.
*/
Item {
    id: root

    /*! Base colour; the two halves are shaded from it. */
    property color tint: "#7cb0e8"

    readonly property real w: Math.min(width, height)

    // The back tab, peeking above the body on the left — the shape that makes
    // a rounded rectangle read as "folder" rather than "note".
    Squircle {
        id: tab
        x: root.width / 2 - root.w * 0.44
        y: root.height / 2 - root.w * 0.36
        width: root.w * 0.46
        height: root.w * 0.26
        radius: root.w * 0.09
        smoothing: 1
        fillColor: Qt.darker(root.tint, 1.35)
    }

    // The body. Overlaps the tab so the join is invisible, and the tab's
    // rounded top corners are all that shows.
    Squircle {
        id: body
        x: root.width / 2 - root.w * 0.44
        y: root.height / 2 - root.w * 0.24
        width: root.w * 0.88
        height: root.w * 0.60
        radius: root.w * 0.12
        smoothing: 1
        fillColor: root.tint
    }

    // A single highlight across the top of the body. One gradient stop rather
    // than a full sheen: at 48px most of a gradient is invisible, and the part
    // that is visible just muddies the colour.
    Rectangle {
        x: body.x
        y: body.y
        width: body.width
        height: body.height * 0.42
        radius: root.w * 0.12
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Qt.rgba(1, 1, 1, 0.18)
            }
            GradientStop {
                position: 1
                color: Qt.rgba(1, 1, 1, 0)
            }
        }
    }
}
