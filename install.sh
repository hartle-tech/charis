#!/bin/sh
# Charis installer — portable by default, no root, any distribution.
#
#   ./install.sh              install for the current user
#   ./install.sh --check      report what is present and what is missing, change nothing
#   ./install.sh --uninstall  remove everything this script installed
#   ./install.sh --prefix DIR install somewhere else
#
# ⚠️ `id -un`, never $USER. $USER is unset in systemd services, in most
# containers, and under `su` without a login shell — and the resulting probe
# path is "/etc/profiles/per-user//lib/qt-6/qml", which does not exist, so a
# perfectly good Qt installation is reported as missing. Measured here: the
# NixOS check said "Qt 6 NOT FOUND" on a machine that was running Qt at the time.
#
# WHY THIS IS SHORT, AND WHY THAT IS THE POINT.
#
# Charis is pure QML. There is nothing to compile, no ABI to match, no
# architecture to pick. "Installing" it is copying a directory onto a QML import
# path, which is why it can be genuinely portable rather than portable-if-you-
# have-the-right-glibc. The whole install is a copy, two launcher scripts and
# two desktop entries, all under $HOME.
#
# The one real dependency is a Qt 6 runtime, and for the shell surfaces
# (the dock) also Quickshell. This script does NOT try to install those behind
# your back: it detects them, and if they are missing it prints the exact
# command for YOUR distribution and stops. An installer that silently invokes a
# package manager as root is how people end up with a broken system from a tool
# they were only evaluating.
#
# ⚠️ POSIX sh on purpose — no bash, no arrays, no [[ ]]. This has to run on a
# minimal Alpine container and on a ten-year-old CentOS box, and `#!/bin/bash`
# is not present on either.
set -eu

VERSION="0.1.0"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN_DIR="$HOME/.local/bin"
QML_DIR="$HOME/.local/lib/qt-6/qml"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

MODE=install

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    --prefix) PREFIX="$2"; shift ;;
    --help|-h)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

CHARIS_HOME="$PREFIX/charis"

# ── Reporting ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  B=$(printf '\033[1m'); R=$(printf '\033[0m')
  G=$(printf '\033[32m'); Y=$(printf '\033[33m'); D=$(printf '\033[31m')
else
  B=""; R=""; G=""; Y=""; D=""
fi
ok()   { printf '%s  ok %s %s\n' "$G" "$R" "$1"; }
warn() { printf '%s  !! %s %s\n' "$Y" "$R" "$1"; }
bad()  { printf '%s  xx %s %s\n' "$D" "$R" "$1"; }
head_() { printf '\n%s%s%s\n' "$B" "$1" "$R"; }

# ── Distribution detection ────────────────────────────────────────────────
# /etc/os-release is the one thing every modern distribution agrees on. ID_LIKE
# matters as much as ID: deriving from it means Mint, Pop!_OS, EndeavourOS,
# Nobara and the rest are handled without naming any of them.
distro_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown} ${ID_LIKE:-}"
  else
    echo unknown
  fi
}

DISTRO=$(distro_id)

quickshell_hint() {
  case "$DISTRO" in
    *nixos*)          echo "nix profile install nixpkgs#quickshell" ;;
    *arch*|*endeavour*|*manjaro*)
                      echo "paru -S quickshell        # or: yay -S quickshell-git" ;;
    *fedora*|*rhel*|*centos*)
                      echo "sudo dnf copr enable errornointernet/quickshell && sudo dnf install quickshell" ;;
    *debian*|*ubuntu*)
                      echo "no distro package yet — build from https://quickshell.outfoxxed.me/docs/guide/install" ;;
    *suse*)           echo "no distro package yet — build from https://quickshell.outfoxxed.me/docs/guide/install" ;;
    *alpine*)         echo "no distro package yet — build from https://quickshell.outfoxxed.me/docs/guide/install" ;;
    *)                echo "see https://quickshell.outfoxxed.me/docs/guide/install" ;;
  esac
}

qt_hint() {
  case "$DISTRO" in
    *nixos*)          echo "nix profile install nixpkgs#qt6.qtdeclarative nixpkgs#qt6.qt5compat" ;;
    *arch*|*endeavour*|*manjaro*)
                      echo "sudo pacman -S qt6-declarative qt6-shadertools" ;;
    *fedora*|*rhel*|*centos*)
                      echo "sudo dnf install qt6-qtdeclarative qt6-qtshadertools" ;;
    *debian*|*ubuntu*)
                      echo "sudo apt install qml6-module-qtquick qt6-declarative-dev" ;;
    *suse*)           echo "sudo zypper install qt6-declarative-devel" ;;
    *alpine*)         echo "sudo apk add qt6-qtdeclarative" ;;
    *)                echo "install your distribution's Qt 6 QtQuick runtime" ;;
  esac
}

# ── Dependency probing ────────────────────────────────────────────────────
find_qt_qml_dir() {
  # The QtQuick module's own directory, wherever this distro put it. Probing for
  # the directory rather than for a `qmake` binary on purpose: many
  # distributions split the runtime from the development package, and a machine
  # can perfectly well run QML with no qmake installed at all.
  for d in \
      "${QML2_IMPORT_PATH:-}" \
      /usr/lib/qt6/qml /usr/lib64/qt6/qml \
      /usr/lib/x86_64-linux-gnu/qt6/qml \
      /usr/lib/aarch64-linux-gnu/qt6/qml \
      "$HOME/.nix-profile/lib/qt-6/qml" \
      "$HOME/.local/state/nix/profile/lib/qt-6/qml" \
      /etc/profiles/per-user/"$(id -un)"/lib/qt-6/qml ; do
    [ -n "$d" ] || continue
    # QML2_IMPORT_PATH may be a colon list.
    IFS=:
    for p in $d; do
      [ -n "$p" ] || continue
      if [ -d "$p/QtQuick" ]; then unset IFS; echo "$p"; return 0; fi
    done
    unset IFS
  done
  return 1
}

check_deps() {
  missing=0

  head_ "Charis $VERSION — environment"
  printf '  distribution : %s\n' "$DISTRO"
  printf '  install root : %s\n' "$CHARIS_HOME"

  # ⚠️ NixOS is a special case and saying so is more useful than a wrong
  # answer. There is no single "Qt qml directory" on NixOS: modules live in
  # per-package store paths assembled into each program's wrapper, so this
  # probe legitimately finds nothing on a machine that is running Qt right
  # now. Reporting "NOT FOUND" there would be technically true and completely
  # misleading.
  case "$DISTRO" in
    *nixos*)
      head_ "NixOS detected"
      echo "  This portable installer is not the right path here. NixOS has no single"
      echo "  Qt qml directory to install into — modules live in per-package store"
      echo "  paths, assembled per program. The probe below will say Qt is missing on"
      echo "  a machine that is running Qt right now."
      echo
      echo "  Use the flake instead:   nix profile install github:hartle-tech/charis"
      echo "  or add the module to your configuration. See the README."
      ;;
  esac

  head_ "Required"

  if QTQML=$(find_qt_qml_dir); then
    ok "Qt 6 QtQuick runtime    $QTQML"
  else
    bad "Qt 6 QtQuick runtime    NOT FOUND"
    printf '       %s\n' "$(qt_hint)"
    missing=1
  fi

  if [ -n "$QTQML" ] && [ -d "$QTQML/QtQuick/Shapes" ]; then
    ok "QtQuick.Shapes          (Squircle needs it)"
  else
    warn "QtQuick.Shapes MISSING  — Squircle will not render"
    printf '       %s\n' "$(qt_hint)"
  fi

  if [ -n "$QTQML" ] && [ -d "$QTQML/QtQuick/Effects" ]; then
    ok "QtQuick.Effects         (icon shadows)"
  else
    warn "QtQuick.Effects MISSING — shadows will not render"
  fi

  head_ "Optional — needed only for the shell surfaces (the dock)"

  if command -v quickshell >/dev/null 2>&1; then
    ok "quickshell              $(command -v quickshell)"
  else
    warn "quickshell NOT FOUND    — the library and Studio still work; the dock does not"
    printf '       %s\n' "$(quickshell_hint)"
  fi

  if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    ok "Wayland session"
  else
    warn "not a Wayland session   — the dock needs wlr-layer-shell"
  fi

  return $missing
}

# ── Actions ───────────────────────────────────────────────────────────────
do_install() {
  if ! check_deps; then
    head_ "Stopping"
    echo "  Qt 6 is required and was not found. Install it with the command above,"
    echo "  then run this script again. Nothing has been written."
    exit 1
  fi

  head_ "Installing"

  mkdir -p "$CHARIS_HOME" "$BIN_DIR" "$QML_DIR" "$APP_DIR"

  # The library. A copy, not a symlink: a symlink into a download directory
  # breaks the moment the user tidies up, and the failure ("module Charis is not
  # installed") points nowhere near the cause.
  rm -rf "$QML_DIR/Charis" "$QML_DIR/CharisBuild"
  cp -r "$SELF_DIR/qml/Charis" "$QML_DIR/Charis"
  ok "Charis      → $QML_DIR/Charis"
  if [ -d "$SELF_DIR/qml/CharisBuild" ]; then
    cp -r "$SELF_DIR/qml/CharisBuild" "$QML_DIR/CharisBuild"
    ok "CharisBuild → $QML_DIR/CharisBuild"
  fi

  rm -rf "$CHARIS_HOME/studio" "$CHARIS_HOME/dock"
  [ -d "$SELF_DIR/studio" ] && cp -r "$SELF_DIR/studio" "$CHARIS_HOME/studio" && ok "Studio      → $CHARIS_HOME/studio"
  [ -d "$SELF_DIR/dock" ] && cp -r "$SELF_DIR/dock" "$CHARIS_HOME/dock" && ok "Dock        → $CHARIS_HOME/dock"

  # Launchers. QML2_IMPORT_PATH is PREPENDED, not replaced — replacing it is how
  # an installer breaks every other Qt application the user has, and the damage
  # outlives the uninstall.
  for app in studio dock; do
    [ -d "$CHARIS_HOME/$app" ] || continue
    cat > "$BIN_DIR/charis-$app" <<EOF
#!/bin/sh
# Generated by the Charis installer. Safe to delete.
exec env QML2_IMPORT_PATH="$QML_DIR\${QML2_IMPORT_PATH:+:\$QML2_IMPORT_PATH}" \\
  quickshell -p "$CHARIS_HOME/$app" "\$@"
EOF
    chmod +x "$BIN_DIR/charis-$app"
    ok "launcher    → $BIN_DIR/charis-$app"
  done

  if [ -d "$CHARIS_HOME/studio" ]; then
    cat > "$APP_DIR/charis-studio.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Charis Studio
Comment=Build Qt Quick interfaces visually and in code
Exec=$BIN_DIR/charis-studio
Terminal=false
Categories=Development;IDE;
StartupWMClass=quickshell
EOF
    ok "desktop     → $APP_DIR/charis-studio.desktop"
  fi

  head_ "Done"
  case ":$PATH:" in
    *":$BIN_DIR:"*) echo "  Run:  charis-studio" ;;
    *)
      # Saying so beats "command not found" from a fresh install, which reads
      # as the installer having failed.
      warn "$BIN_DIR is not on your PATH"
      echo "       add it:  export PATH=\"\$HOME/.local/bin:\$PATH\""
      echo "       or run:  $BIN_DIR/charis-studio"
      ;;
  esac
  echo
  echo "  Import it in any Qt 6 project:"
  echo "      QML2_IMPORT_PATH=$QML_DIR   and then  import Charis"
  echo
}

do_uninstall() {
  head_ "Removing"
  for p in \
      "$QML_DIR/Charis" "$QML_DIR/CharisBuild" \
      "$CHARIS_HOME" \
      "$BIN_DIR/charis-studio" "$BIN_DIR/charis-dock" \
      "$APP_DIR/charis-studio.desktop" ; do
    if [ -e "$p" ]; then rm -rf "$p"; ok "removed $p"; fi
  done
  # Deliberately NOT removed: ~/.config/charis. That is the user's dock
  # arrangement and their Studio projects, and an uninstaller that deletes
  # user data because it also created the directory is unforgivable.
  if [ -d "$HOME/.config/charis" ]; then
    warn "kept $HOME/.config/charis (your settings — delete it yourself if you want it gone)"
  fi
}

case "$MODE" in
  check)     check_deps || exit 1 ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
esac
