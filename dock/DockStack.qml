pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Widgets
import Charis

/*!
    A folder pinned to the dock, opened as a grid of its contents — Apple's
    "stack".

    \section2 Why a grid and not a fan

    macOS offers fan, grid and list. The fan is the memorable one and the worst:
    it can only show a handful of items before it runs off the top of the
    screen, and it degrades into a grid anyway past that point. The grid is what
    people actually end up using, so it is what this implements — with the
    honest consequence that a folder of four hundred files shows the first
    \l maxItems and a footer saying how many were not shown, rather than
    pretending to be a file manager.

    \section2 Thumbnails where they help

    An image file shows the image. Everything else shows its icon. That is a
    small thing that makes a Downloads or Screenshots stack immediately useful
    rather than a wall of identical page glyphs — and it costs nothing, because
    the thumbnails are decoded at grid-cell size via `sourceSize` rather than
    at whatever resolution the camera happened to produce.
*/
Item {
    id: root

    /*! Absolute path of the folder. */
    property string folder: ""

    property bool open: false

    /*! Where the stack points, in the parent's coordinates. */
    property real anchorPos: 0
    property int edge: Qt.BottomEdge

    /*! Distance from this item's edge-facing side to where the dock band
        starts. Popups anchor against the BAND, not against the surface, because
        the surface is deliberately much bigger than the dock (see Dock.mask). */
    property real bandOffset: 0

    /*! How much room this popup needs beyond the band — read by Dock to size
        its input mask. Zero when closed. */
    readonly property real popupExtent: panel.visible ? (root.horizontal ? panel.height : panel.width) + 14 : 0

    /*! Cap on how many entries are drawn. A dock stack is a shortcut, not a
        file browser; rendering 2,000 icons to be scrolled past is a way to
        make opening a folder slower than opening the file manager. */
    property int maxItems: 30

    property int columns: 5
    property real cellSize: 76

    readonly property bool horizontal: root.edge === Qt.BottomEdge || root.edge === Qt.TopEdge

    signal requestClose

    function openFile(url: string): void {
        // xdg-open rather than a hard-coded handler: the point of a stack is
        // that it opens things the way the rest of the desktop would.
        Quickshell.execDetached(["xdg-open", url]);
        root.requestClose();
    }

    FolderListModel {
        id: files
        folder: root.folder ? `file://${root.folder}` : ""
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: false
        // Newest first is the right default for the folders people actually
        // pin — Downloads, Screenshots, Desktop. Alphabetical is only useful
        // for a folder you already know the contents of.
        sortField: FolderListModel.Time
        sortReversed: false
    }

    readonly property int shown: Math.min(files.count, root.maxItems)
    readonly property int hidden: Math.max(0, files.count - root.maxItems)
    readonly property int rows: Math.max(1, Math.ceil(root.shown / root.columns))

    Spring {
        id: grow
        target: root.open ? 1 : 0
        response: 0.34
        damping: 0.76
    }

    // Dismiss on a click anywhere else. A stack that can only be closed by
    // opening something in it is a trap.
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onPressed: root.requestClose()
        z: -1
    }

    Item {
        id: panel

        readonly property real pad: 12
        readonly property real footerH: root.hidden > 0 ? 22 : 0

        width: root.columns * root.cellSize + panel.pad * 2
        height: root.rows * root.cellSize + panel.pad * 2 + panel.footerH + 24
        visible: grow.value > 0.001
        opacity: grow.value

        x: root.horizontal ? Math.max(8, Math.min(root.width - panel.width - 8, root.anchorPos - panel.width / 2)) : (root.edge === Qt.LeftEdge ? root.bandOffset + 10 : root.width - root.bandOffset - panel.width - 10)
        y: root.horizontal ? (root.edge === Qt.BottomEdge ? root.height - root.bandOffset - panel.height - 10 : root.bandOffset + 10) : Math.max(8, Math.min(root.height - panel.height - 8, root.anchorPos - panel.height / 2))

        // Grow out of the icon that was clicked, not out of thin air.
        transform: Scale {
            origin.x: panel.width / 2
            origin.y: root.edge === Qt.BottomEdge ? panel.height : 0
            xScale: 0.9 + 0.1 * grow.value
            yScale: 0.9 + 0.1 * grow.value
        }

        Squircle {
            anchors.fill: parent
            radius: 18
            smoothing: 1
            fillColor: Qt.rgba(0.11, 0.11, 0.12, 0.94)
            strokeColor: Qt.rgba(1, 1, 1, 0.12)
            strokeWidth: 1
        }

        Text {
            id: title
            anchors.top: parent.top
            anchors.topMargin: 7
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.folder.split("/").pop() || root.folder
            color: "white"
            opacity: 0.7
            font.pixelSize: 12
            font.bold: true
        }

        Grid {
            anchors.top: title.bottom
            anchors.topMargin: 4
            anchors.horizontalCenter: parent.horizontalCenter
            columns: root.columns

            Repeater {
                model: root.shown

                Item {
                    id: cell
                    required property int index
                    width: root.cellSize
                    height: root.cellSize

                    readonly property bool isDir: files.get(cell.index, "fileIsDir") ?? false
                    readonly property string fileName: files.get(cell.index, "fileName") ?? ""
                    readonly property string filePath: files.get(cell.index, "filePath") ?? ""
                    readonly property bool isImage: /\.(png|jpe?g|gif|webp|bmp|svg|avif)$/i.test(cell.fileName)

                    Squircle {
                        anchors.fill: parent
                        anchors.margins: 3
                        radius: 9
                        smoothing: 1
                        fillColor: cellHover.hovered ? Qt.rgba(1, 1, 1, 0.11) : "transparent"
                    }

                    // Thumbnail for images, icon for everything else.
                    Image {
                        id: thumb
                        visible: cell.isImage
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 8
                        width: 38
                        height: 38
                        fillMode: Image.PreserveAspectCrop
                        clip: true
                        asynchronous: true
                        cache: true
                        source: cell.isImage ? `file://${cell.filePath}` : ""
                        // ⚠️ Decode at CELL size, never at native. A stack of
                        // twenty 45-megapixel RAWs decoded at full resolution
                        // is several GB of texture for thirty-eight pixels of
                        // output, and it stalls the whole shell doing it.
                        sourceSize.width: 76
                        sourceSize.height: 76
                    }

                    // Drawn, not looked up — see FolderIcon for why. Qt
                    // resolves NO theme icon in a bare Wayland session, so
                    // `iconPath("text-x-generic")` returns an empty string and
                    // every file in the stack would be a blank gap.
                    FolderIcon {
                        visible: cell.isDir
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 8
                        width: 38
                        height: 38
                        tint: "#9ab7d8"
                    }

                    Item {
                        visible: !cell.isDir && !cell.isImage
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 8
                        width: 38
                        height: 38

                        Squircle {
                            anchors.centerIn: parent
                            width: 27
                            height: 34
                            radius: 6
                            smoothing: 1
                            fillColor: Qt.rgba(1, 1, 1, 0.86)
                        }

                        // Three ruled lines, so a document reads as a document
                        // at 38px rather than as a blank card.
                        Column {
                            anchors.centerIn: parent
                            spacing: 3
                            Repeater {
                                model: 3
                                Rectangle {
                                    width: 15
                                    height: 1.5
                                    radius: 1
                                    color: Qt.rgba(0.25, 0.27, 0.31, 0.85)
                                }
                            }
                        }
                    }

                    Text {
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 6
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 4
                        horizontalAlignment: Text.AlignHCenter
                        text: cell.fileName
                        color: "white"
                        opacity: 0.85
                        font.pixelSize: 9
                        elide: Text.ElideMiddle
                        maximumLineCount: 2
                        wrapMode: Text.WrapAnywhere
                    }

                    HoverHandler {
                        id: cellHover
                    }
                    TapHandler {
                        onTapped: root.openFile(`file://${cell.filePath}`)
                    }
                }
            }
        }

        Text {
            visible: root.hidden > 0
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 5
            anchors.horizontalCenter: parent.horizontalCenter
            text: `+${root.hidden} more — open folder`
            color: "white"
            opacity: 0.55
            font.pixelSize: 10

            TapHandler {
                onTapped: root.openFile(`file://${root.folder}`)
            }
        }
    }
}
