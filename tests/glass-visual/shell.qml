// Charis — Glass refraction visual proof.
//
// "It looks like glass" is not a test. This renders the SAME scene twice —
// once with refraction disabled, once with it on — and writes both to disk so
// they can be compared numerically. If the shader is not actually displacing
// its samples, the two images are identical and the difference is exactly zero.
// A blur would also produce a difference, so the backdrop is hard-edged
// stripes: refraction BENDS them, a blur would only soften them, and the two
// are trivially distinguishable in the output.

import QtQuick
import Quickshell
import Charis

ShellRoot {
    id: root

    property int done: 0

    function finish() {
        root.done += 1;
        if (root.done >= 2) {
            console.log("GRABBED both frames");
            Qt.exit(0);
        }
    }

    component Scene: Item {
        id: scene
        required property real refractAmount
        width: 320
        height: 220
        visible: true

        // Hard-edged stripes. A gradient would hide the bend; sharp edges make
        // any displacement obvious and measurable.
        Item {
            id: backdrop
            anchors.fill: parent
            Column {
                Repeater {
                    model: 22
                    Rectangle {
                        required property int index
                        width: 320
                        height: 10
                        color: index % 2 === 0 ? "#ffffff" : "#101014"
                    }
                }
            }
        }

        Glass {
            anchors.fill: parent
            anchors.margins: 30
            backdrop: backdrop
            radius: 34
            smoothing: 1
            thickness: 26
            refraction: scene.refractAmount
            rim: 0.10
            tintAmount: 0.0
        }
    }

    // ⚠️ Inside a real window. grabToImage refuses on an item that is not
    // attached to one — "item is not attached to a window" — and a ShellRoot is
    // not a window. Offscreen still renders, so this stays headless.
    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 660
        implicitHeight: 240
        color: "#000000"

        Scene {
            id: off
            x: 0
            refractAmount: 0
        }
        Scene {
            id: on
            x: 330
            refractAmount: 22
        }
    }

    Timer {
        interval: 900
        running: true
        onTriggered: {
            off.grabToImage(r => {
                r.saveToFile("/tmp/glass-off.png");
                root.finish();
            });
            on.grabToImage(r => {
                r.saveToFile("/tmp/glass-on.png");
                root.finish();
            });
        }
    }
}
