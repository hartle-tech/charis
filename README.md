# Charis

**Apple-grade motion for Qt Quick — and a visual builder whose output is just code.**

Qt Quick animates with a duration and an easing curve. Change the target
half-way and the curve restarts: the item stops dead and accelerates from zero,
because a curve knows position but not velocity. That single artefact is most of
the gap between motion that reads as *animated* and motion that reads as
*physical*, and no amount of curve-tuning closes it.

Charis closes it, with the four things Qt Quick does not ship.

```qml
import QtQuick
import Charis

Spring { id: x; target: dragging ? pointerX : restX; response: 0.35; damping: 0.8 }
Squircle { radius: 22; smoothing: 1; fillColor: "#2b3a5c" }
```

---

## The four

**`Spring`** — a real damped harmonic oscillator in SwiftUI's
`(response, dampingFraction)` parameterisation, integrated per frame against
*real* elapsed time. Retarget it mid-flight and nothing restarts: the force
changes, the momentum survives, and the motion curves into its new destination.

> Verified against the closed-form solution of the same differential equation —
> an oracle sharing no code with the implementation, so it can fail. Zero
> overshoot at ζ=1; 109.169 measured against 109.478 analytic at ζ=0.6.

**`Ticker`** — one frame clock for the whole process. Springs subscribe when
they move and are dropped when they settle, so an idle UI draws nothing at all.

> Measured: the dock idles at **0.0002 s of CPU over 30 s — 0.001% of one core**
> with seven icons on screen.

**`Squircle`** — continuous-curvature corners. An ordinary `radius:` corner is a
straight edge meeting a circular arc; they agree on position and direction but
not curvature, which jumps from 0 to 1/r instantly. Human vision is measurably
sensitive to that discontinuity even though almost nobody can name it.

**`FrameBudget`** — a single `quality` value from the median of a rolling
window, so expensive effects scale themselves to what the machine is actually
managing. Nobody configures anything; the same build is correct on a 144 Hz
desktop and a struggling laptop.

---

## The same animation takes the same time on every monitor

Motion here is defined in *seconds* and integrated against real frame time, so
it never assumed a frame rate to begin with.

```
settling time, identical spring, five refresh rates
  30Hz 0.8000s · 60Hz 0.7833s · 90Hz 0.7889s · 144Hz 0.7917s · 240Hz 0.7917s
  spread: 1.12%
```

That claim is mutation-tested. Replace the caller's `dt` with a hard-coded
60 Hz step — the exact bug the check exists to catch — and the spread becomes
**130.77%**: an 8× difference in how long the same animation takes, depending
only on which screen it is on.

---

## What is built with it

**Charis Dock** — pinned apps, running apps and folder stacks, with parabolic
magnification, long-press menus built from each app's own `.desktop` actions,
and drag-and-drop. Measured scale profile with the pointer on the middle of
seven icons:

```
1.000 · 1.150 · 1.653 · 1.900 · 1.653 · 1.150 · 1.000
```

Symmetric to 1e-9, monotonic, exactly 1.0 past the influence radius.

**Charis Studio** — a visual builder where the code is not an export.

Almost every visual builder ever shipped has the same fatal property: the editor
owns a private format and the code it emits is one-way. Touch the code and the
builder overwrites your edits or refuses to open the file. That is why "visual
builder" is a slur among senior engineers.

Here the canvas, the outline, the inspector and the source are five views of one
document, and `write`/`parse` are inverses over a defined subset — asserted in
both directions, including on constructs the editor deliberately cannot model. A
hand-written signal handler survives a round trip through a canvas that has no
idea what it is.

Studio is built with Charis. Every panel is a `Squircle`, every transition a
`Spring`.

---

## Install

```sh
./install.sh --check     # report what is present, change nothing
./install.sh             # install for the current user, no root
```

POSIX `sh`, no root, no package manager invoked behind your back. Charis is pure
QML — nothing to compile, no ABI to match — so installing is copying a directory
onto a QML import path. Verified in Debian 12 and Alpine 3.20 containers.

Missing dependencies are reported with the exact command for your distribution
rather than installed for you. On NixOS, use the flake instead — the installer
says so.

```qml
// then, in any Qt 6.11 project
import Charis
```

---

## Requirements

| | |
|---|---|
| Qt 6.11+ | `QtQuick`, `QtQuick.Shapes`; `QtQuick.Effects` for shadows |
| Quickshell | only for the shell surfaces (the dock). The library and Studio do not need it. |

`Charis/` and `CharisBuild/` import nothing but Qt Quick. That constraint is
load-bearing: the moment one of them imports Quickshell, the library stops being
useful to anyone who is not writing a Wayland shell.

---

## Tests

```sh
./scripts/test-charis.sh
```

44 checks across three suites: spring physics against the closed form,
magnification layout, and `write`/`parse` round-tripping.

---

Part of [aphrOS](https://aphros.hartle.tech). Apache-2.0.
