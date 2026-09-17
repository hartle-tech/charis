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
    resting above the content rather than a window cut into it.

    So the panel is given a SURFACE. Its signed distance field — the same
    superellipse exponent \l Squircle uses, so the two agree and the corner is
    Apple's continuous curvature rather than a circle — is turned into a convex
    bevel, the bevel's slope into a 3D normal, and the normal into a refracted
    ray by Snell's law at \l ior. Where that ray lands is where the backdrop is
    sampled. One index per colour channel, so the rim carries a real chromatic
    fringe; a Blinn-Phong highlight from \l lightAngle; and a Schlick Fresnel
    term, which is what makes a glass silhouette glow while its face stays
    quiet. There is no border anywhere in it.

    \c shaders/glass.frag carries the whole derivation, and — more useful — the
    four defects that were missing from the version before it, each of which
    the operator of an aphrOS machine named before the code did.

    \section2 What you have to give it

    A \c backdrop: the item whose pixels should be refracted. Qt Quick cannot
    read "whatever happens to be behind this on screen" — there is no such
    thing in a scene graph — so the caller names the source explicitly. In a
    Wayland shell that is usually a screencopy of the output or the wallpaper;
    inside an application it is whatever the panel floats above.

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

    /*! The item to refract, BLURRED. Nothing renders without one.

        Apple's material is blurred across its face, and on a Wayland shell
        that blur has to happen before this component sees the pixels — a
        MultiEffect over the capture, normally. */
    property Item backdrop: null

    /*! The same content, SHARP, for the bevel to lens.

        🔴 WITHOUT THIS THE REFRACTION IS INVISIBLE. Measured on the bench,
        2026-09-17 23:55: displacing a sample of an image whose detail has
        already been averaged away moves nothing the eye can see, so a
        perfectly correct lens over a blurred source renders as a flat
        translucent slab. That is the whole reason this material kept reading
        as "a blurred rectangle" however right the maths was.

        A real glass sheet is cloudy in the middle and SHARP at its ground-off
        edge, where it shows a compressed image of what is just beyond it.
        Left null the blurred backdrop is used for both and \l clarity stops
        mattering, which keeps every existing caller working unchanged. */
    property Item sharpBackdrop: null

    /*! How far the bevel crossfades to \l sharpBackdrop. 0 is the old,
        uniformly blurred behaviour. */
    property real clarity: 0.85

    /*! Whether \l sharpBackdrop is taken out of the scene once sampled.

        Separate from \l hideBackdrop because the two sources usually differ
        in kind: the blurred one is almost always a private copy that exists
        only to be sampled, while the sharp one may be a REAL background that
        has to keep showing — a wallpaper, a page under a floating panel.
        Hiding it then blanks the very thing the panel is supposed to be lying
        on top of. Defaults to whatever \l hideBackdrop is, which is right for
        a shell panel where both are captures. */
    property bool hideSharpBackdrop: root.hideBackdrop

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

    /*! Depth of glass, in pixels, the refracted ray crosses. Bigger means the
        bevel pulls more of the surrounding image into itself. */
    property real refraction: 34

    /*! Index of refraction. Glass is about 1.5, which is what Apple's material
        behaves like; 1.0 is no bending at all. */
    property real ior: 1.5

    /*! How steep the rolled edge is — the tangent scale of the height field
        the normal comes from. Larger tilts the normal further at the rim, so
        both the lensing and the Fresnel edge strengthen together, the way they
        do on a thicker piece of glass. */
    property real bevel: 1.0

    /*! Strength of the Fresnel edge: the steep brightening at grazing angles
        that makes a glass silhouette glow while its face stays quiet.

        This is the term that replaces a drawn border. A border is uniform and
        reads as a board; this is only large where the surface turns over. */
    property real fresnel: 0.30

    /*! How far the three colour channels disagree about that displacement, as
        a fraction of it. A real lens refracts short wavelengths harder, so the
        channels do not land in the same place, and that coloured fringe in the
        last few pixels of the edge is the most recognisable single feature of
        Apple's material. 0 turns it off. */
    property real dispersion: 0.55

    /*! Brightness of the directional specular highlight. */
    property real rim: 0.34

    /*! Blinn-Phong exponent for that highlight. Higher is tighter and glossier;
        lower spreads it along more of the edge. */
    property real rimWidth: 20

    /*! Direction the light comes FROM, in the panel's own coordinates, where y
        grows downward. The default is over the viewer's left shoulder, which is
        where every Apple material puts it. */
    property real lightAngle: -122

    /*! A broad, soft brightness gradient across the face of the panel,
        brightest on the lit side. Small values only: this is the difference
        between a sheet and a flat fill, not an effect in its own right. */
    property real sheen: 0.03

    /*! Saturation multiplier applied to the refracted backdrop. Above 1
        because Apple's material is more colourful than what is behind it —
        vibrancy is what stops glass reading as grey plastic. */
    property real saturation: 1.20

    property color tint: "#101014"
    property real tintAmount: 0.22

    /*! Luminance the body is lifted to when the backdrop is darker than it.

        🔴 WITHOUT THIS THE PANEL IS A BLACK SLAB OVER DARK CONTENT. Blending
        toward a dark tint has nothing to work with when the backdrop is
        already dark, so the sheet vanishes into the background and reads as a
        painted rectangle. Apple's dark glass is always a little brighter than
        black; that is what makes it an object lying on the content rather than
        a hole cut into it. 0 restores the old, wrong behaviour. */
    property real lift: 0.12

    /*! Turn the whole effect off. When false the panel falls back to flat
        translucent tint — which is what a machine under load should get. */
    property bool enabled: true

    /*! Why the material is or is not drawing, in one string.

        A shader that silently samples nothing is indistinguishable from a
        shader that is switched off, and every hour lost to this component has
        gone on telling those two apart. This is how you tell them apart
        without guessing, and it is worth rendering into a corner of whatever
        you are photographing. */
    readonly property string diag: `size=${Math.round(root.width)}x${Math.round(root.height)} backdrop=${root.backdrop !== null}` + (root.backdrop ? ` backdropSize=${Math.round(root.backdrop.width)}x${Math.round(root.backdrop.height)}` : "") + ` origin=${Math.round(root._origin.x)},${Math.round(root._origin.y)} shaderVisible=${fx.visible} status=${fx.status} live=${grab.live} enabled=${root.enabled}` + (fx.log ? ` log=${fx.log}` : "")

    /*! Where, in the backdrop's own coordinates, the region behind this panel
        begins. Only consulted when \l autoOrigin is false. */
    property point sourceOrigin: Qt.point(0, 0)

    /*! Work the origin out from the scene graph, rather than being told it.

        True is right and is what a component should do by default, but it
        depends on the scene graph having settled — see \l _origin for the
        trap. Set it false and give \l sourceOrigin when the caller already
        knows the offset, which is almost always the case for a shell panel
        drawing over a capture of its own output. */
    property bool autoOrigin: true

    /*! Recompute the sampled region. Call it after moving the panel or its
        backdrop in a way the change signals below cannot see — a resized
        ancestor, most often. */
    function refresh(): void {
        root._originTick = root._originTick + 1;
    }

    // n = 2 is a circle, 5 is the continuous corner — identical mapping to
    // Squircle, so the two agree when used together.
    readonly property real _expo: 2 + 3 * Math.max(0, Math.min(1, root.smoothing))

    readonly property real _lightRad: root.lightAngle * Math.PI / 180

    // 🔥 `mapToItem` IN A BINDING IS NOT A BINDING, and this cost a day.
    //
    // QML cannot see the dependencies of a function call, so a binding whose
    // right-hand side is `mapToItem(...)` is evaluated exactly ONCE — when the
    // item is created, which for anything laid out by a Row, a Layout or an
    // anchor is BEFORE it has a position or a size. The sampled region stayed
    // Qt.rect(0, 0, 0, 0), the shader read an empty texture, and the panel drew
    // a flat black slab. That is indistinguishable from the glass being
    // switched off, which is how the dock's `useGlass` toggle spent its entire
    // life doing nothing, and how the aphrOS bar's islands came out near-black
    // over a bright wallpaper (measured: interior 20, wallpaper below it 189).
    //
    // So the mapping is driven by an explicit counter that every relevant
    // change signal bumps, and callers who know the offset can skip the whole
    // mechanism with \l sourceOrigin.
    property int _originTick: 0

    readonly property point _origin: {
        void root._originTick;
        if (!root.autoOrigin)
            return root.sourceOrigin;
        if (!root.backdrop)
            return Qt.point(0, 0);
        void root.x;
        void root.y;
        void root.width;
        void root.height;
        void root.backdrop.width;
        void root.backdrop.height;
        const p = root.mapToItem(root.backdrop, 0, 0);
        return Qt.point(p.x, p.y);
    }

    onXChanged: root.refresh()
    onYChanged: root.refresh()
    onWidthChanged: root.refresh()
    onHeightChanged: root.refresh()
    onBackdropChanged: root.refresh()
    onVisibleChanged: root.refresh()
    Component.onCompleted: root.refresh()

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
        sourceRect: root.backdrop ? Qt.rect(root._origin.x, root._origin.y, Math.max(1, root.width), Math.max(1, root.height)) : Qt.rect(0, 0, 0, 0)
    }

    // The sharp copy the bevel lenses. Falls back to the blurred one, so a
    // caller that has only a single image passes the same texture twice and
    // the crossfade becomes a no-op rather than a black edge.
    ShaderEffectSource {
        id: grabSharp
        anchors.fill: parent
        visible: false
        live: root.enabled && root.visible
        hideSource: root.sharpBackdrop ? root.hideSharpBackdrop : root.hideBackdrop
        sourceItem: root.sharpBackdrop ?? root.backdrop
        sourceRect: grab.sourceRect
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        visible: root.enabled && root.backdrop !== null

        property variant src: grab
        property variant srcSharp: grabSharp
        property vector2d srcSize: Qt.vector2d(Math.max(1, root.width), Math.max(1, root.height))
        property vector2d lightDir: Qt.vector2d(Math.cos(root._lightRad), Math.sin(root._lightRad))
        property real radius: root.radius
        property real expo: root._expo
        property real thickness: root.thickness
        property real refraction: root.refraction
        property real dispersion: root.dispersion
        property real rim: root.rim
        property real rimWidth: root.rimWidth
        property real sheen: root.sheen
        property real tintAmount: root.tintAmount
        property real lift: root.lift
        property real saturation: root.saturation
        property real clarity: root.sharpBackdrop ? root.clarity : 0
        property real ior: root.ior
        property real fresnel: root.fresnel
        property real bevel: root.bevel
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
