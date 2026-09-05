# Charis as a flake, for the distribution where the portable installer is the
# wrong answer.
#
# On NixOS there is no single Qt qml directory to copy into — modules live in
# per-package store paths assembled into each program's wrapper — so
# `install.sh` legitimately finds nothing on a machine that is running Qt at
# that moment. It says so and points here.
{
  description = "Spring motion and material primitives for Qt Quick, and a visual builder built with them";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAll (pkgs: rec {
        charis = pkgs.callPackage ./package.nix { inherit (pkgs) quickshell; };
        default = charis;
      });

      # `import Charis` in any Qt program built with this overlay.
      overlays.default = final: prev: {
        charis = final.callPackage ./package.nix { inherit (final) quickshell; };
      };

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            qt6.qtdeclarative
            quickshell
          ];
          shellHook = ''
            export QML2_IMPORT_PATH="$PWD/qml''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
            echo "Charis dev shell — QML2_IMPORT_PATH points at ./qml"
            echo "  quickshell -p ./studio    the visual builder"
            echo "  quickshell -p ./dock      the dock"
            echo "  ./scripts/test.sh         44 checks"
          '';
        };
      });
    };
}
