// Charis Studio — the visual builder, built with Charis.
//
// DOGFOODED ON PURPOSE. Every panel below is laid out with the same Squircle,
// the same Spring and the same shared Ticker the dock uses. If the library is
// not pleasant enough to build a real application with, that is a fact worth
// discovering here rather than from the first person who tries.
//
// ⚠️ WHAT IS AND IS NOT TIED TO QUICKSHELL. This file uses Quickshell for a
// window and for file IO, because that is the Qt runtime installed on this
// machine and a builder nobody can start is worth nothing. Two things are
// deliberately kept clean of it:
//
//   Charis/       the primitives — plain Qt Quick
//   CharisBuild/  the document model and QML writer — plain Qt Quick
//
// and, most importantly, so is the OUTPUT. A project exported from Studio is
// plain QML importing QtQuick and Charis, with no Quickshell anywhere. What the
// user builds is portable even while the builder is not yet, which is the right
// way round: the tool's own packaging is our problem to fix, whereas a lock-in
// baked into everyone's exported projects would be theirs forever.

import QtQuick
import Quickshell
import Quickshell.Io
import Charis
import CharisBuild

ShellRoot {
    id: app

    // ── Document ────────────────────────────────────────────────────────
    //
    // ONE source of truth, and it is the tree. The canvas renders it, the
    // inspector edits it, the code pane is `write()` of it, and typing in the
    // code pane is `parse()` back into it. No panel owns a private copy, which
    // is the failure that makes most builders lose your edits.
    //
    // Seeded with a small example rather than an empty canvas. A blank builder
    // asks the newcomer to know what to do before they have seen the tool do
    // anything, and it also hides the one thing worth noticing immediately:
    // the canvas, the outline, the inspector and the source are four views of
    // THIS object, and editing any of them moves the other three.
    property var doc: ({
            type: "Item",
            id: "root",
            props: {
                width: 420,
                height: 260
            },
            children: [
                {
                    type: "Squircle",
                    id: "card",
                    props: {
                        width: 320,
                        height: 180,
                        x: 40,
                        y: 30,
                        radius: 28,
                        smoothing: 1,
                        fillColor: "#2b3a5c",
                        strokeColor: "#4c78d0",
                        strokeWidth: 1
                    },
                    children: [],
                    extra: []
                },
                {
                    type: "Text",
                    id: "",
                    props: {
                        x: 72,
                        y: 66,
                        text: "Hello from Charis",
                        color: "#e8e8ea",
                        "font.pixelSize": 22
                    },
                    children: [],
                    extra: []
                },
                {
                    type: "Text",
                    id: "",
                    props: {
                        x: 72,
                        y: 98,
                        text: "Edit me in any of the four panes",
                        color: "#8fa8d6",
                        "font.pixelSize": 13
                    },
                    children: [],
                    extra: []
                }
            ],
            extra: []
        })

    /*! Path to the selected node: a list of child indices from the root. An
        index path rather than an object reference, because the tree is
        reassigned wholesale on every edit (QML only notices a `var` property
        changing if it is replaced) and a held reference would point into the
        previous version. */
    property var selection: []

    property int revision: 0

    function nodeAt(path: var): var {
        let n = app.doc;
        for (const i of path) {
            if (!n.children || !n.children[i])
                return null;
            n = n.children[i];
        }
        return n;
    }

    function touch(): void {
        // Reassign so bindings re-evaluate, then bump a counter for the things
        // that cannot bind to a deep mutation.
        app.doc = app.doc;
        app.revision += 1;
    }

    function addNode(type: string): void {
        const parent = app.nodeAt(app.selection) ?? app.doc;
        if (!parent.children)
            parent.children = [];
        parent.children.push({
            type: type,
            id: "",
            props: app.defaultsFor(type),
            children: [],
            extra: []
        });
        app.selection = app.selection.concat([parent.children.length - 1]);
        app.touch();
    }

    /*! Something visible, immediately. A component dropped onto a canvas with
        no size is a zero-pixel object the user cannot select or even see, and
        the universal first impression of a broken builder. */
    function defaultsFor(type: string): var {
        switch (type) {
        case "Rectangle":
            return {
                width: 120,
                height: 80,
                color: "#4c78d0",
                radius: 6
            };
        case "Squircle":
            return {
                width: 120,
                height: 80,
                radius: 22,
                smoothing: 1,
                fillColor: "#4c78d0"
            };
        case "Text":
            return {
                text: "Text",
                color: "#e8e8ea",
                // Quoted because a JS object key cannot contain a dot
                // unquoted. It is still emitted as `font.pixelSize: 16`,
                // which is what QML wants — grouped properties are a QML
                // notion that JS object literals have no syntax for.
                "font.pixelSize": 16
            };
        case "Image":
            return {
                width: 120,
                height: 120,
                fillMode: {
                    bind: "Image.PreserveAspectFit"
                }
            };
        case "Row":
        case "Column":
            return {
                spacing: 8
            };
        case "MouseArea":
            return {
                width: 120,
                height: 80
            };
        default:
            return {
                width: 120,
                height: 80
            };
        }
    }

    function deleteSelected(): void {
        if (app.selection.length === 0)
            return;
        const parentPath = app.selection.slice(0, -1);
        const idx = app.selection[app.selection.length - 1];
        const parent = app.nodeAt(parentPath);
        if (!parent || !parent.children)
            return;
        parent.children.splice(idx, 1);
        app.selection = parentPath;
        app.touch();
    }

    function setProp(key: string, value: var): void {
        const n = app.nodeAt(app.selection);
        if (!n)
            return;
        if (value === null)
            delete n.props[key];
        else
            n.props[key] = value;
        app.touch();
    }

    readonly property string source: {
        app.revision; // re-evaluate on every edit
        return QmlWriter.write(app.doc);
    }

    // ── Project IO ──────────────────────────────────────────────────────
    FileView {
        id: projectFile
        path: `${Quickshell.env("HOME")}/.local/share/charis-studio/project.qml`
        // Writes are explicit; a builder that saves on every keystroke makes
        // undo impossible outside itself.
        blockWrites: true
        onLoadFailed: err => {}
    }

    function save(): void {
        projectFile.setText(app.source);
        status.flash("Saved → " + projectFile.path);
    }

    function load(): void {
        projectFile.reload();
        const t = projectFile.text();
        if (!t || t.length === 0) {
            status.flash("Nothing saved yet");
            return;
        }
        const parsed = QmlWriter.parse(t);
        if (!parsed) {
            status.flash("Could not parse the saved project");
            return;
        }
        app.doc = parsed;
        app.selection = [];
        app.touch();
        status.flash("Loaded " + projectFile.path);
    }

    FloatingWindow {
        id: win

        title: "Charis Studio"
        implicitWidth: 1280
        implicitHeight: 800
        color: "#141416"

        StudioShell {
            anchors.fill: parent
            document: app
        }

        Rectangle {
            id: status

            function flash(msg: string): void {
                status.message = msg;
                statusTimer.restart();
            }

            property string message: ""

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18 + 30 * slide.value
            width: label.implicitWidth + 28
            height: 32
            radius: 16
            color: "#2b2b30"
            border.color: "#3d3d44"
            border.width: 1
            opacity: slide.value
            visible: opacity > 0.01

            Spring {
                id: slide
                target: statusTimer.running ? 1 : 0
                response: 0.35
                damping: 0.8
            }

            Timer {
                id: statusTimer
                interval: 2200
            }

            Text {
                id: label
                anchors.centerIn: parent
                text: status.message
                color: "#e8e8ea"
                font.pixelSize: 12
            }
        }
    }
}
