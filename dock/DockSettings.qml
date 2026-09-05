pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Charis

/*!
    The dock's settings, built with Charis.

    Every control here is a Squircle and a Spring, so the settings window is the
    library's second customer after Studio. A toolkit whose own preferences
    dialog has to be built with something else is not finished.

    \section2 Live, not "Apply"

    Every change takes effect on the dock immediately and is written to
    `dock.json` on release. There is no OK/Cancel, because for visual settings
    the preview IS the decision: nobody can choose a corner radius from a number,
    and an Apply button turns every adjustment into a guess followed by a
    round trip.

    ⚠️ Written on RELEASE, not per frame. A slider dragged across its range
    would otherwise write the config file a hundred times, and `FileView` is
    watching that file — so each write would bounce straight back in as a
    reload while the finger is still down.
*/
Item {
    id: root

    /*! The live Dock, so controls can drive it directly and the preview is the
        real thing rather than a mock-up of it. */
    required property var dock

    /*! Mirrored from the config, because the compositor's blur is not a
        property of the dock item. */
    property real backdropBlur: 8

    /*!
        Emitted continuously while a control is moved. The caller sets the
        config value, which flows back to the dock through its existing
        binding — so the preview is live and the binding survives.

        🔴 THE PANEL USED TO ASSIGN `dock.baseIconSize` DIRECTLY, AND THAT
        BROKE THE DOCK PERMANENTLY. An imperative assignment in QML destroys
        the property's binding, so the first time this window opened — the
        sliders initialise, `onValueChanged` fires once, and every assignment
        lands — the dock stopped following its config file for the rest of the
        session. Measured: config said iconSize 64, the dock believed 48, and
        nothing anywhere reported a problem. Data flows one way now: panel →
        config → dock.
    */
    signal changed(string key, var value)

    /*! Emitted on release, when the value should be persisted to disk. */
    signal committed(string key, var value)

    readonly property color bg: "#17171b"
    readonly property color panel: "#1f1f25"
    readonly property color line: "#2f2f38"
    readonly property color text: "#e9e9ec"
    readonly property color dim: "#8e8e99"
    readonly property color accent: "#6f9ceb"

    implicitWidth: 380
    implicitHeight: 640

    Rectangle {
        anchors.fill: parent
        color: root.bg
    }

    // ── Controls ────────────────────────────────────────────────────────

    component Slider: Item {
        id: sl
        required property string label
        required property real from
        required property real to
        property real value: 0
        property int decimals: 0
        property string settingKey: ""
        /*! A line under the track, for a control whose effect is not obvious
            from its name — or reaches further than its name suggests. */
        property string hint: ""
        signal settled(real v)

        width: parent ? parent.width : 300
        height: sl.hint ? 58 : 44

        readonly property real frac: (sl.value - sl.from) / Math.max(0.0001, sl.to - sl.from)

        Text {
            id: lbl
            x: 0
            y: 2
            text: sl.label
            color: root.dim
            font.pixelSize: 11
        }

        Text {
            y: 40
            visible: sl.hint !== ""
            text: sl.hint
            color: root.dim
            font.pixelSize: 10
            width: sl.width
            wrapMode: Text.Wrap
        }
        Text {
            anchors.right: parent.right
            y: 2
            text: sl.value.toFixed(sl.decimals)
            color: root.text
            font.pixelSize: 11
            font.family: "monospace"
        }

        Item {
            id: track
            y: 22
            width: parent.width
            height: 18

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: root.line
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * sl.frac
                height: 4
                radius: 2
                color: root.accent
            }

            // The knob is spring-driven so it eases into place when the value
            // is changed from elsewhere, and tracks the finger exactly while
            // being dragged — the spring's whole reason for existing.
            Spring {
                id: knob
                target: track.width * sl.frac
                response: knobDrag.active ? 0.05 : 0.28
                damping: 1.0
                epsilon: 0.01
            }

            Rectangle {
                x: knob.value - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: knobDrag.active || knobHover.hovered ? 16 : 13
                height: width
                radius: width / 2
                color: "white"

                Behavior on width {
                    NumberAnimation {
                        duration: 110
                    }
                }
            }

            HoverHandler {
                id: knobHover
            }
            DragHandler {
                id: knobDrag
                target: null
                xAxis.enabled: true
                yAxis.enabled: false
                dragThreshold: 0
                onCentroidChanged: {
                    if (!knobDrag.active)
                        return;
                    const f = Math.max(0, Math.min(1, knobDrag.centroid.position.x / track.width));
                    sl.value = sl.from + f * (sl.to - sl.from);
                }
                onActiveChanged: if (!knobDrag.active)
                    sl.settled(sl.value)
            }
            TapHandler {
                onTapped: e => {
                    const f = Math.max(0, Math.min(1, e.position.x / track.width));
                    sl.value = sl.from + f * (sl.to - sl.from);
                    sl.settled(sl.value);
                }
            }
        }
    }

    component Toggle: Item {
        id: tg
        required property string label
        property string hint: ""
        property bool checked: false
        signal settled(bool v)

        width: parent ? parent.width : 300
        height: tg.hint ? 44 : 32

        Text {
            y: 2
            text: tg.label
            color: root.text
            font.pixelSize: 12.5 - 0.5
        }
        Text {
            y: 20
            visible: tg.hint !== ""
            text: tg.hint
            color: root.dim
            font.pixelSize: 10
            width: tg.width - 60
            wrapMode: Text.Wrap
        }

        Item {
            id: sw
            anchors.right: parent.right
            y: 2
            width: 38
            height: 21

            Spring {
                id: slide
                target: tg.checked ? 1 : 0
                response: 0.26
                damping: 0.85
            }

            Squircle {
                anchors.fill: parent
                radius: 10.5
                smoothing: 1
                fillColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25 + 0.75 * slide.value)
            }
            Rectangle {
                x: 2.5 + slide.value * 17
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                radius: 8
                color: "white"
            }
            TapHandler {
                onTapped: {
                    tg.checked = !tg.checked;
                    tg.settled(tg.checked);
                }
            }
        }
    }

    component Segmented: Item {
        id: seg
        required property string label
        required property var options   // [[value, text], …]
        property string value: ""
        signal settled(string v)

        width: parent ? parent.width : 300
        height: 46

        Text {
            y: 2
            text: seg.label
            color: root.dim
            font.pixelSize: 11
        }

        Row {
            y: 20
            spacing: 4

            Repeater {
                model: seg.options

                Item {
                    id: opt
                    required property var modelData
                    readonly property bool on: seg.value === opt.modelData[0]
                    width: Math.max(60, txt.implicitWidth + 20)
                    height: 24

                    Squircle {
                        anchors.fill: parent
                        radius: 7
                        smoothing: 1
                        fillColor: opt.on ? root.accent : (optHover.hovered ? "#2b2b33" : "#232329")
                    }
                    Text {
                        id: txt
                        anchors.centerIn: parent
                        text: opt.modelData[1]
                        color: opt.on ? "#111" : root.text
                        font.pixelSize: 11
                        font.bold: opt.on
                    }
                    HoverHandler {
                        id: optHover
                    }
                    TapHandler {
                        onTapped: {
                            seg.value = opt.modelData[0];
                            seg.settled(seg.value);
                        }
                    }
                }
            }
        }
    }

    /*!
        A colour control that is a row of swatches plus a live hex field.

        🔴 THE DOCK'S COLOURS WERE CONFIG-ONLY AND THAT COUNTED AS "you can
        modify the appearance". They could be changed by editing JSON in a text
        editor, which is not a setting a person has; it is a setting the
        program has. The operator asked for background, style and COLOURS and
        the panel offered opacity and roundness.

        Swatches rather than a colour wheel, deliberately. A dock's panel is
        seen behind other people's artwork at 55% opacity — the useful choices
        are a handful of neutrals plus the accent, and a full picker invites
        a magenta dock that looks broken. The hex field is there for anyone who
        disagrees, which is the right shape for a default: easy to do the sane
        thing, possible to do anything.
    */
    component Swatches: Item {
        id: sw
        required property string label
        property string value: "#1e1e1e"
        property var options: []
        signal settled(string v)

        width: parent ? parent.width : 300
        height: 52

        Text {
            y: 2
            text: sw.label
            color: root.dim
            font.pixelSize: 11
        }
        Text {
            anchors.right: parent.right
            y: 2
            text: sw.value
            color: root.text
            font.pixelSize: 10
            font.family: "monospace"
        }

        Row {
            y: 20
            spacing: 6

            Repeater {
                model: sw.options

                Item {
                    id: chip
                    required property var modelData
                    // Compared case-insensitively: a hex written by hand is as
                    // likely to be #1E1E1E as #1e1e1e, and a swatch that never
                    // shows as selected reads as a control that does nothing.
                    readonly property bool on: sw.value.toLowerCase() === String(chip.modelData).toLowerCase()
                    width: 26
                    height: 26

                    Squircle {
                        anchors.fill: parent
                        radius: 8
                        smoothing: 1
                        fillColor: chip.modelData
                        strokeColor: chip.on ? root.accent : "#3a3a44"
                        strokeWidth: chip.on ? 2 : 1
                    }
                    TapHandler {
                        onTapped: {
                            sw.value = chip.modelData;
                            sw.settled(sw.value);
                        }
                    }
                }
            }
        }
    }

    component Heading: Text {
        color: root.dim
        font.pixelSize: 10
        font.bold: true
        font.capitalization: Font.AllUppercase
        topPadding: 10
    }

    // ── Layout ──────────────────────────────────────────────────────────
    Flickable {
        id: flick
        anchors.fill: parent
        anchors.margins: 18
        contentHeight: col.height + 20
        clip: true

        // ⚠️ AN AFFORDANCE, NOT DECORATION. The panel is taller than it is
        // allowed to be, so the last section — every behaviour toggle — sits
        // below the fold with the content sliced clean off at the edge. With no
        // bar there is nothing on screen that says the list continues, and a
        // settings window that appears to be missing half its settings is
        // indistinguishable from one that is.
        //
        // It fades out when nothing is happening, like a trackpad scrollbar,
        // and appears the moment the content moves.
        Rectangle {
            parent: flick
            anchors.right: parent.right
            anchors.rightMargin: -10
            y: flick.contentY + (flick.contentY / Math.max(1, flick.contentHeight - flick.height)) * (flick.height - height)
            width: 3
            radius: 1.5
            height: Math.max(28, flick.height * (flick.height / Math.max(1, flick.contentHeight)))
            visible: flick.contentHeight > flick.height
            color: "#ffffff"
            opacity: flick.moving ? 0.35 : 0.12

            Behavior on opacity {
                NumberAnimation {
                    duration: 220
                }
            }
        }

        Column {
            id: col
            width: parent.width
            spacing: 6

            Text {
                text: "Dock"
                color: root.text
                font.pixelSize: 19
                font.bold: true
                bottomPadding: 4
            }

            Heading {
                text: "Size and position"
            }

            Segmented {
                label: "Edge"
                options: [["bottom", "Bottom"], ["left", "Left"], ["right", "Right"], ["top", "Top"]]
                value: root.dock.edge === Qt.LeftEdge ? "left" : root.dock.edge === Qt.RightEdge ? "right" : root.dock.edge === Qt.TopEdge ? "top" : "bottom"
                onSettled: v => { root.changed("edge", v); root.committed("edge", v); }
            }

            Slider {
                label: "Icon size"
                from: 24
                to: 128
                value: root.dock.baseIconSize
                onValueChanged: root.changed("iconSize", Math.round(value))
                onSettled: v => root.committed("iconSize", Math.round(v))
            }

            Slider {
                label: "Magnification"
                from: 1
                to: 3
                decimals: 2
                value: root.dock.magnification
                onValueChanged: root.changed("magnification", value)
                onSettled: v => root.committed("magnification", v)
            }

            Slider {
                label: "Magnification reach (icons)"
                from: 1
                to: 6
                decimals: 1
                value: root.dock.influenceCells
                onValueChanged: root.changed("influenceCells", value)
                onSettled: v => root.committed("influenceCells", v)
            }

            Slider {
                label: "Icon spacing"
                from: 0
                to: 24
                value: root.dock.spacing
                onValueChanged: root.changed("spacing", Math.round(value))
                onSettled: v => root.committed("spacing", Math.round(v))
            }

            Slider {
                label: "Gap from screen edge"
                from: 0
                to: 40
                value: root.dock.edgeGap
                onValueChanged: root.changed("edgeGap", Math.round(value))
                onSettled: v => root.committed("edgeGap", Math.round(v))
            }

            Heading {
                text: "Appearance"
            }

            Swatches {
                label: "Background colour"
                options: ["#1e1e1e", "#101014", "#2a2320", "#1b2430", "#202a20", "#f2f2f4"]
                value: root.dock.panelColor.toString().substring(0, 7)
                onSettled: v => { root.changed("panelColor", v); root.committed("panelColor", v); }
            }

            Swatches {
                label: "Border colour"
                // With alpha: the dock's rim is a hairline of light over
                // whatever is behind it, and an opaque border reads as a box
                // drawn around the dock rather than as an edge catching light.
                options: ["#1affffff", "#33ffffff", "#00000000", "#40000000", "#336f9ceb"]
                value: root.dock.borderColor.toString()
                onSettled: v => { root.changed("borderColor", v); root.committed("borderColor", v); }
            }

            Slider {
                label: "Background opacity"
                from: 0
                to: 1
                decimals: 2
                value: root.dock.panelOpacity
                onValueChanged: root.changed("panelOpacity", value)
                onSettled: v => root.committed("panelOpacity", v)
            }

            Slider {
                label: "Corner roundness"
                from: 0
                to: 0.5
                decimals: 2
                value: root.dock.cornerRoundness
                onValueChanged: root.changed("cornerRoundness", value)
                onSettled: v => root.committed("cornerRoundness", v)
            }

            Slider {
                label: "Border width"
                from: 0
                to: 4
                value: root.dock.borderWidth
                onValueChanged: root.changed("borderWidth", Math.round(value))
                onSettled: v => root.committed("borderWidth", Math.round(v))
            }

            Toggle {
                label: "Refracting glass"
                hint: "Bends the wallpaper at the dock's rim instead of a flat tint. Costs a texture and a shader pass."
                checked: root.dock.useGlass
                onCheckedChanged: root.changed("useGlass", checked)
                onSettled: v => root.committed("useGlass", v)
            }

            Slider {
                label: "Glass refraction"
                from: 0
                to: 40
                value: root.dock.blurAmount
                onValueChanged: root.changed("blurAmount", Math.round(value))
                onSettled: v => root.committed("blurAmount", Math.round(v))
            }

            Slider {
                label: "Backdrop blur"
                // Named for what it really does. The compositor can be told to
                // blur behind the dock's surface but not how hard to blur it
                // there, so this is the system-wide radius — and saying
                // "Backdrop blur" alone would leave the user to discover that
                // by noticing their terminal had changed.
                hint: "Compositor-wide. Changes the blur behind every window, not only the dock."
                from: 0
                to: 20
                value: root.backdropBlur
                onValueChanged: root.changed("backdropBlur", Math.round(value))
                onSettled: v => root.committed("backdropBlur", Math.round(v))
            }

            Heading {
                text: "Behaviour"
            }

            Toggle {
                label: "Hide automatically"
                checked: root.dock.autoHide
                onCheckedChanged: root.changed("autoHide", checked)
                onSettled: v => root.committed("autoHide", v)
            }

            Toggle {
                label: "Animations"
                hint: "Off makes every motion instant. Large sliding motion is genuinely unpleasant for some people."
                checked: root.dock.animations
                onCheckedChanged: root.changed("animations", checked)
                onSettled: v => root.committed("animations", v)
            }

            Toggle {
                label: "Resize by dragging the edge"
                checked: root.dock.resizable
                onCheckedChanged: root.changed("resizable", checked)
                onSettled: v => root.committed("resizable", v)
            }

            Segmented {
                label: "Folders open as"
                options: [["grid", "Grid"], ["list", "List"], ["icons", "Icons"]]
                value: root.dock.folderView
                onSettled: v => { root.changed("folderView", v); root.committed("folderView", v); }
            }
        }
    }
}
