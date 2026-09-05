pragma ComponentBehavior: Bound

import QtQuick
import Charis
import CharisBuild

/*!
    The four panes: palette, outline, canvas, inspector — plus the source.

    Every panel is a \l Squircle and every transition is a \l Spring, because
    this application is the library's own first customer. Anything awkward here
    is a defect in Charis, not in Studio.
*/
Item {
    id: root

    /*! The `shell.qml` ShellRoot, which owns the document and all mutations.
        Passed in rather than reached for, so this file has no global state and
        could be embedded twice. */
    required property var document

    readonly property color bg: "#141416"
    readonly property color panel: "#1b1b1f"
    readonly property color line: "#2c2c33"
    readonly property color text: "#e8e8ea"
    readonly property color dim: "#8b8b95"
    readonly property color accent: "#6f9ceb"

    component Panel: Squircle {
        radius: 12
        smoothing: 1
        fillColor: root.panel
        strokeColor: root.line
        strokeWidth: 1
    }

    component PaneTitle: Text {
        color: root.dim
        font.pixelSize: 11
        font.bold: true
        font.capitalization: Font.AllUppercase
    }

    // ── Palette ─────────────────────────────────────────────────────────
    Panel {
        id: palette
        x: 12
        y: 12
        width: 168
        height: parent.height - 24

        PaneTitle {
            x: 14
            y: 12
            text: "Components"
        }

        Column {
            x: 8
            y: 36
            width: parent.width - 16
            spacing: 3

            Repeater {
                model: ["Rectangle", "Squircle", "Text", "Image", "Row", "Column", "Grid", "MouseArea", "Item"]

                Item {
                    id: entry
                    required property string modelData
                    width: parent.width
                    height: 30

                    Squircle {
                        anchors.fill: parent
                        radius: 7
                        smoothing: 1
                        fillColor: entryHover.hovered ? "#26262c" : "transparent"
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: 10
                        text: entry.modelData
                        color: root.text
                        font.pixelSize: 12
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        text: "+"
                        color: root.accent
                        font.pixelSize: 15
                        opacity: entryHover.hovered ? 1 : 0
                    }

                    HoverHandler {
                        id: entryHover
                    }
                    TapHandler {
                        onTapped: root.document.addNode(entry.modelData)
                    }
                }
            }
        }

        // The outline lives under the palette: adding and arranging are the
        // same activity, and splitting them across the window means crossing it
        // for every single edit.
        PaneTitle {
            x: 14
            y: 372
            text: "Outline"
        }

        Flickable {
            x: 8
            y: 396
            width: parent.width - 16
            height: parent.height - 408
            contentHeight: outline.height
            clip: true

            Column {
                id: outline
                width: parent.width
                spacing: 2

                Repeater {
                    model: root.flatten(root.document.doc, [])

                    Item {
                        id: nodeRow
                        required property var modelData
                        width: outline.width
                        height: 26

                        readonly property bool selected: JSON.stringify(nodeRow.modelData.path) === JSON.stringify(root.document.selection)

                        Squircle {
                            anchors.fill: parent
                            radius: 6
                            smoothing: 1
                            fillColor: nodeRow.selected ? "#2f4368" : (rowHover.hovered ? "#26262c" : "transparent")
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            x: 8 + nodeRow.modelData.depth * 12
                            width: parent.width - x - 8
                            elide: Text.ElideRight
                            text: nodeRow.modelData.node.type + (nodeRow.modelData.node.id ? "  #" + nodeRow.modelData.node.id : "")
                            color: nodeRow.selected ? root.text : root.dim
                            font.pixelSize: 12
                        }

                        HoverHandler {
                            id: rowHover
                        }
                        TapHandler {
                            onTapped: root.document.selection = nodeRow.modelData.path
                        }
                    }
                }
            }
        }
    }

    /*! Depth-first list of `{ node, path, depth }`, so the outline can be a
        flat Repeater. A nested Repeater-of-Repeaters would be the obvious
        shape and makes selection paths much harder to compute, because each
        level would have to know its ancestors' indices. */
    function flatten(node: var, path: var): var {
        const out = [
            {
                node: node,
                path: path,
                depth: path.length
            }
        ];
        const kids = node.children ?? [];
        for (let i = 0; i < kids.length; i++)
            for (const e of root.flatten(kids[i], path.concat([i])))
                out.push(e);
        return out;
    }

    // ── Canvas ──────────────────────────────────────────────────────────
    Panel {
        id: canvas
        x: palette.x + palette.width + 12
        y: 12
        width: parent.width - palette.width - inspector.width - 48
        height: parent.height * 0.58

        PaneTitle {
            x: 14
            y: 12
            text: "Canvas — live"
        }

        // A checkerboard, so a transparent or white component is still visible.
        // A canvas that is one flat colour makes half of what you build
        // invisible, and the user concludes the tool is broken.
        Item {
            id: stage
            anchors.fill: parent
            anchors.topMargin: 34
            anchors.margins: 10
            clip: true

            // A grid, so a transparent or white component is still visible
            // against the canvas. A single flat colour makes half of what you
            // build invisible and the user concludes the tool is broken.
            //
            // ⚠️ RULED LINES, NOT A CHECKERBOARD. The obvious checkerboard is
            // one Rectangle per cell — 1,425 of them on a 900x400 stage, all
            // real scene-graph nodes, redrawn on every resize, for decoration.
            // Two Repeaters of thin lines is ~80 nodes and looks the same.
            // The first version also asked for a NEGATIVE model count before
            // the stage had been sized, which Qt warns about and then ignores.
            Repeater {
                model: Math.max(0, Math.ceil(stage.width / 24))
                Rectangle {
                    required property int index
                    x: index * 24
                    width: 1
                    height: stage.height
                    color: "#1c1c22"
                }
            }
            Repeater {
                model: Math.max(0, Math.ceil(stage.height / 24))
                Rectangle {
                    required property int index
                    y: index * 24
                    height: 1
                    width: stage.width
                    color: "#1c1c22"
                }
            }

            Item {
                id: mount
                anchors.centerIn: parent
                width: parent.width
                height: parent.height
            }
        }
    }

    // ── Live preview ────────────────────────────────────────────────────
    //
    // The canvas is not a drawing OF the document, it is the document, running.
    // A builder that renders its own approximation of your UI is lying to you
    // about the one thing you came to it for.
    property var _instance: null
    property string previewError: ""

    function rebuild(): void {
        if (root._instance) {
            root._instance.destroy();
            root._instance = null;
        }
        try {
            root._instance = Qt.createQmlObject(root.document.source, mount, "charis-studio-preview");
            root.previewError = "";
        } catch (e) {
            // Errors are SHOWN, not swallowed. A canvas that silently keeps
            // displaying the last thing that compiled makes a typo look like a
            // frozen application.
            root.previewError = String(e.message ?? e);
        }
    }

    Connections {
        target: root.document
        function onRevisionChanged() {
            root.rebuild();
        }
    }
    Component.onCompleted: root.rebuild()

    Rectangle {
        visible: root.previewError !== ""
        anchors.left: canvas.left
        anchors.right: canvas.right
        anchors.bottom: canvas.bottom
        anchors.margins: 10
        height: Math.min(90, errText.implicitHeight + 16)
        radius: 8
        color: "#3a1f22"
        border.color: "#7a3b40"
        border.width: 1

        Text {
            id: errText
            anchors.fill: parent
            anchors.margins: 8
            text: root.previewError
            color: "#ffb4b4"
            font.pixelSize: 11
            font.family: "monospace"
            wrapMode: Text.Wrap
            elide: Text.ElideRight
        }
    }

    // ── Source ──────────────────────────────────────────────────────────
    Panel {
        id: code
        x: canvas.x
        y: canvas.y + canvas.height + 12
        width: canvas.width
        height: parent.height - canvas.height - 36

        PaneTitle {
            x: 14
            y: 12
            text: "Source — QtQuick + Charis, no Quickshell"
        }

        Flickable {
            anchors.fill: parent
            anchors.topMargin: 32
            anchors.margins: 10
            contentHeight: srcText.implicitHeight
            clip: true

            TextEdit {
                id: srcText
                width: parent.width
                text: root.document.source
                color: root.text
                font.family: "monospace"
                font.pixelSize: 12
                selectionColor: root.accent
                wrapMode: TextEdit.NoWrap
                readOnly: false

                // ⚠️ Only on focus loss, never per keystroke. Reparsing as the
                // user types re-emits the source from the document mid-word and
                // the caret jumps to the top of the file on every character —
                // which makes the pane completely unusable while looking, from
                // the code's point of view, like it is working perfectly.
                onActiveFocusChanged: {
                    if (srcText.activeFocus)
                        return;
                    const parsed = QmlWriter.parse(srcText.text);
                    if (parsed) {
                        root.document.doc = parsed;
                        root.document.selection = [];
                        root.document.touch();
                    }
                }
            }
        }
    }

    // ── Inspector ───────────────────────────────────────────────────────
    Panel {
        id: inspector
        width: 260
        x: parent.width - width - 12
        y: 12
        height: parent.height - 24

        readonly property var node: root.document.nodeAt(root.document.selection)

        PaneTitle {
            x: 14
            y: 12
            text: "Inspector"
        }

        Text {
            x: 14
            y: 32
            text: inspector.node ? inspector.node.type : "nothing selected"
            color: root.text
            font.pixelSize: 14
            font.bold: true
        }

        Row {
            x: 14
            y: 56
            spacing: 6
            visible: inspector.node !== null

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "id"
                color: root.dim
                font.pixelSize: 11
            }

            Rectangle {
                width: 150
                height: 22
                radius: 5
                color: "#232329"
                border.color: idField.activeFocus ? root.accent : root.line
                border.width: 1

                TextInput {
                    id: idField
                    anchors.fill: parent
                    anchors.margins: 5
                    text: inspector.node ? (inspector.node.id ?? "") : ""
                    color: root.text
                    font.pixelSize: 12
                    onEditingFinished: {
                        if (!inspector.node)
                            return;
                        inspector.node.id = idField.text;
                        root.document.touch();
                    }
                }
            }
        }

        Flickable {
            x: 8
            y: 88
            width: parent.width - 16
            height: parent.height - 140
            contentHeight: props.height
            clip: true

            Column {
                id: props
                width: parent.width
                spacing: 4

                Repeater {
                    model: inspector.node ? Object.keys(inspector.node.props ?? {}).sort() : []

                    Row {
                        id: propRow
                        required property string modelData
                        spacing: 6

                        readonly property var raw: inspector.node.props[propRow.modelData]
                        readonly property bool isBinding: propRow.raw !== null && typeof propRow.raw === "object" && propRow.raw.bind !== undefined

                        Text {
                            width: 84
                            anchors.verticalCenter: parent.verticalCenter
                            text: propRow.modelData
                            color: root.dim
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            width: 150
                            height: 22
                            radius: 5
                            color: "#232329"
                            // A bound property is tinted, because "120" and a
                            // binding that evaluates to 120 look identical in a
                            // text box and behave nothing alike.
                            border.color: valField.activeFocus ? root.accent : (propRow.isBinding ? "#5a7f5a" : root.line)
                            border.width: 1

                            TextInput {
                                id: valField
                                anchors.fill: parent
                                anchors.margins: 5
                                text: propRow.isBinding ? propRow.raw.bind : String(propRow.raw)
                                color: propRow.isBinding ? "#a8d6a8" : root.text
                                font.pixelSize: 12
                                font.family: propRow.isBinding ? "monospace" : "sans-serif"

                                onEditingFinished: {
                                    // Re-infer the type from what was typed, via
                                    // exactly the same function the parser uses.
                                    // A second inference rule here is a second
                                    // source of truth, and they drift.
                                    root.document.setProp(propRow.modelData, QmlWriter.qmlToValue(valField.text));
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Actions ─────────────────────────────────────────────────────
        Row {
            x: 14
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 14
            spacing: 8

            component Btn: Item {
                id: btn
                property string label: ""
                property color tone: root.accent
                signal clicked
                width: 68
                height: 28

                Squircle {
                    anchors.fill: parent
                    radius: 8
                    smoothing: 1
                    fillColor: btnHover.hovered ? Qt.lighter(btn.tone, 1.15) : btn.tone
                }
                Text {
                    anchors.centerIn: parent
                    text: btn.label
                    color: "#111"
                    font.pixelSize: 12
                    font.bold: true
                }
                HoverHandler {
                    id: btnHover
                }
                TapHandler {
                    onTapped: btn.clicked()
                }
            }

            Btn {
                label: "Save"
                onClicked: root.document.save()
            }
            Btn {
                label: "Load"
                tone: "#8b8b95"
                onClicked: root.document.load()
            }
            Btn {
                label: "Delete"
                tone: "#c76b6b"
                onClicked: root.document.deleteSelected()
            }
        }
    }
}
