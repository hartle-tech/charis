pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

/*!
    \qmltype Glass
    \brief A panel that refracts what is behind it, rather than blurring it.

    THE DIFFERENCE THIS EXISTS TO MAKE. Every "glass" surface on Linux is a
    blur: sample the backdrop, average it, tint it. That is frosted plastic, and
    it reads as a translucent hole cut into the content behind it.

    Real glass has THICKNESS, and a thick edge bends what you see through it.
    That single property is why an Apple sheet reads as a physical object
    resting above the content. So this displaces the backdrop sample by the
    surface normal — taken from the signed distance field of the panel's own
    shape — strongest at the rim and zero in the middle, which is what a lens
    does.

    The distance field uses the same superellipse exponent as \l Squircle, so
    the refraction follows a continuous-curvature edge and the bend has no seam
    in it either.

    \section2 What you have to give it

    A \c backdrop: the item whose pixels should be refracted. Qt Quick cannot
    read "whatever happens to be behind this on screen" — there is no such
    thing in a scene graph — so the caller names the source explicitly. In a
    Wayland shell that is usually a \c ScreenshotItem or the wallpaper; inside
    an application it is whatever the panel floats above.

    \qml
    Glass {
        anchors.fill: parent
        backdrop: wallpaperImage
        radius: 28
        refraction: 14
        tint: "#101014"
        tintAmount: 0.25
    }
    \endqml

    \section2 Cost

    One offscreen texture for the backdrop plus one full-screen-ish fragment
    pass. That is real money on an integrated GPU, so bind \l enabled to
    \l FrameBudget.quality rather than assuming it is free — a machine that
    cannot afford refraction should get flat translucency and still feel
    responsive, which is always the better trade.
*/
Item {
    id: root

    /*! The item to refract. Nothing renders without one. */
    property Item backdrop: null

    /*! Take the backdrop out of the scene once it has been sampled.

        True when the backdrop exists only to be refracted — a wallpaper an
        overlay draws for itself, which must not also be painted over the
        desktop. False when it is a real background that has to keep showing
        through and around the glass. */
    property bool hideBackdrop: false

    /*! Corner radius, matching \l Squircle. */
    property real radius: 24

    /*! 0 = circular corner, 1 = continuous. Same meaning as Squircle.smoothing. */
    property real smoothing: 1

    /*! Width in pixels of the bevelled edge the refraction happens in. */
    property real thickness: 18

    /*! How far, in pixels, the rim displaces the backdrop sample. */
    property real refraction: 12

    /*! Brightness of the specular edge highlight. */
    property real rim: 0.14

    property color tint: "#101014"
    property real tintAmount: 0.22

    /*! Turn the whole effect off. When false the panel falls back to flat
        translucent tint — which is what a machine under load should get. */
    property bool enabled: true

    // n = 2 is a circle, 5 is the continuous corner — identical mapping to
    // Squircle, so the two agree when used together.
    readonly property real _expo: 2 + 3 * Math.max(0, Math.min(1, root.smoothing))

    // The backdrop has to become a texture before a shader can sample it.
    // `live` is left true because the wallpaper under a dock does change —
    // a video wallpaper, a workspace switch — and a stale glass panel showing
    // last week's desktop is worse than no glass.
    ShaderEffectSource {
        id: grab
        anchors.fill: parent
        visible: false
        live: root.enabled && root.visible
        // 🔴 THE BACKDROP MUST BE A VISIBLE ITEM, AND THIS IS WHY.
        //
        // Qt Quick does not render an item whose `visible` is false into a
        // ShaderEffectSource's texture — it renders nothing, and the shader
        // samples transparent black. A dock whose glass was fed an invisible
        // wallpaper drew a flat black slab and looked, exactly, like an opaque
        // panel with the glass switched off.
        //
        // `hideSource` is the documented way out: the source item is visible,
        // so it renders into the texture, and Qt then omits it from the scene
        // so it is not also painted on top of everything. Set it when the
        // backdrop exists ONLY to be sampled — a wallpaper the dock draws for
        // itself — and leave it false when the caller's backdrop is a real
        // background that must keep showing.
        hideSource: root.hideBackdrop
        sourceItem: root.backdrop
        // Sample exactly the region this panel covers, in the backdrop's own
        // coordinates. Without this the shader samples the whole backdrop
        // scaled into the panel, and the refraction bends a shrunken copy of
        // the entire wallpaper instead of the part actually behind the glass.
        sourceRect: root.backdrop ? Qt.rect(root.mapToItem(root.backdrop, 0, 0).x, root.mapToItem(root.backdrop, 0, 0).y, root.width, root.height) : Qt.rect(0, 0, 0, 0)
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        visible: root.enabled && root.backdrop !== null

        property variant src: grab
        property vector2d srcSize: Qt.vector2d(Math.max(1, root.width), Math.max(1, root.height))
        property real radius: root.radius
        property real expo: root._expo
        property real thickness: root.thickness
        property real refraction: root.refraction
        property real rim: root.rim
        property real tintAmount: root.tintAmount
        property vector4d tint: Qt.vector4d(root.tint.r, root.tint.g, root.tint.b, 1)

        fragmentShader: Qt.resolvedUrl("shaders/glass.frag.qsb")
    }

    // Fallback. Not an error path — this is what a loaded machine, or one whose
    // driver refuses the shader, should show, and it must still look
    // deliberate rather than broken.
    Squircle {
        anchors.fill: parent
        visible: !fx.visible
        radius: root.radius
        smoothing: root.smoothing
        fillColor: Qt.rgba(root.tint.r, root.tint.g, root.tint.b, 0.55)
        strokeColor: Qt.rgba(1, 1, 1, 0.10)
        strokeWidth: 1
    }
}
