# Charis — the motion/material library, and the dock built on it.
#
# TWO OUTPUTS FROM ONE SOURCE TREE, AND THE SPLIT IS THE POINT.
#
#   qml/Charis/   plain Qt Quick. No Quickshell import, no aphrOS import. Drops
#                 into any Qt 6.11 application.
#   dock/         a Quickshell layer-shell surface that uses it.
#
# The library half is installed into the standard `lib/qt-6/qml` location so any
# Qt program can import it by putting this package on QML2_IMPORT_PATH — which
# is what makes it a library rather than a feature of one shell. Keep it that
# way: the moment something under qml/Charis imports Quickshell, the package
# stops being useful to anyone not writing a Wayland shell, and the whole reason
# for the separation is gone.
#
# ⚠️ NOT PART OF CAELESTIA. The dock deliberately runs as its own Quickshell
# process rather than as a module inside Caelestia's patched tree: Caelestia is
# a flake input carrying 38 build-time substituteInPlace edits against source we
# do not control, and putting the dock behind that fragility buys nothing.
{
  pkgs,
  lib,
  quickshell,
}:
let
  qmlPath = "lib/qt-6/qml";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "charis";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    # Tests and the design docs are not runtime artefacts, and including them
    # would rebuild the package (and restart the dock) every time a test is
    # edited.
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ./. + "/") (toString path);
        base = baseNameOf path;
      in
      (lib.hasPrefix "qml" rel || lib.hasPrefix "dock" rel || lib.hasPrefix "studio" rel)
      # ⚠️ AppleDouble droppings. This tree is edited from macOS and synced with
      # tar, which happily carries `._Dock.qml` sidecars along. Qt does not read
      # them, but Quickshell scans the config directory and they land in the
      # store as visible junk in a published package.
      && !lib.hasPrefix "._" base;
  };

  dontBuild = true;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/${qmlPath}"
    cp -r qml/Charis "$out/${qmlPath}/Charis"
    cp -r qml/CharisBuild "$out/${qmlPath}/CharisBuild"

    mkdir -p "$out/share/charis/dock" "$out/share/charis/studio"
    cp -r dock/. "$out/share/charis/dock/"
    cp -r studio/. "$out/share/charis/studio/"

    # The launcher pins QML2_IMPORT_PATH to this package's own library, so the
    # dock cannot pick up a different Charis from the ambient environment and
    # cannot fail to find one at all. Everything ELSE it needs — WAYLAND_DISPLAY,
    # XDG_DATA_DIRS, HOME — is deliberately inherited rather than pinned:
    #
    # ⚠️ XDG_DATA_DIRS in particular. With it unset, DesktopEntries is empty,
    # every icon path is "", and the dock renders a row of blank tiles. Baking a
    # value in here would freeze the app list to whatever was installed at build
    # time, so the service unit passes the session's own instead.
    # 🔴 THE IMAGE-FORMAT PLUGINS ARE NOT OPTIONAL FOR A DOCK.
    #
    # A dock is a grid of other people's artwork, in whatever format each of
    # them chose. Qt can decode PNG and JPEG on its own; everything else —
    # WEBP, ICNS, TGA, and the rest — lives in qtimageformats, and SVG lives in
    # qtsvg. A Qt build without them does not report a missing decoder: the
    # Image just never reaches status Ready, and the dock quietly draws its
    # "no icon" tile instead.
    #
    # Measured on this machine: the same dock, same config, same icon theme,
    # rendered kitty and Steam as grey letter tiles under one Quickshell build
    # and as their real icons under another. The only difference between the
    # two was that one wrapper carried qtimageformats. Nothing in either log
    # said a word about it.
    #
    # So the plugins come from this package rather than from whichever
    # Quickshell happens to be around, and a distribution that ships a lean Qt
    # cannot silently take icons away from the dock.
    for app in dock studio; do
      makeWrapper ${quickshell}/bin/quickshell "$out/bin/charis-$app" \
        --prefix QML2_IMPORT_PATH : "$out/${qmlPath}" \
        --prefix QT_PLUGIN_PATH : "${pkgs.qt6.qtimageformats}/lib/qt-6/plugins" \
        --prefix QT_PLUGIN_PATH : "${pkgs.qt6.qtsvg}/lib/qt-6/plugins" \
        --add-flags "-p $out/share/charis/$app"
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "Spring-based motion and material library for Qt Quick, and an Apple-class dock built on it";
    longDescription = ''
      Charis supplies the four things Qt Quick does not: spring motion
      integrated against real frame time (so an animation takes the same wall
      time at 30Hz and 240Hz), continuous-curvature corners, a single shared
      frame clock so an idle shell draws nothing at all, and an adaptive frame
      budget. The dock is the first thing built with it.
    '';
    license = licenses.asl20;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}
