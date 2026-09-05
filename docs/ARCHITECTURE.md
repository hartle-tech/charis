# Architecture

Three layers, and the boundaries between them are the design.

```
qml/Charis/        motion + material primitives   — plain Qt Quick
qml/CharisBuild/   document model + QML writer    — plain Qt Quick
dock/  studio/     applications                   — Quickshell (layer shell, IO)
```

**Nothing under `qml/` may import Quickshell.** That single rule is what makes
Charis a library rather than a feature of one shell: a Quickshell-only motion
library is useful to the few hundred people writing Wayland shells, whereas a Qt
Quick one is useful to everyone writing Qt. It is worth re-checking on every
addition, because it is easy to break and hard to notice.

## Why springs, not easing curves

An easing curve is a duration and a shape. It knows where the item is, not how
fast it is going, so retargeting mid-flight restarts it: the item stops dead and
accelerates from zero. That artefact is most of the gap between motion that
reads as animated and motion that reads as physical.

`Spring` integrates a damped harmonic oscillator per frame from position *and*
velocity, in SwiftUI's `(response, dampingFraction)` parameterisation — chosen
over mass/stiffness/damping because those three are miserable to tune: changing
stiffness changes both speed and bounce, so you chase your own tail.

Integration is semi-implicit Euler, substepped to 2 ms. The substep is not only
about stability: at one step per frame the integrator adds damping nobody asked
for, and it shows up as a shallow overshoot — the defect a person describes as
"mushy" without being able to name it.

## Why one clock

A running `FrameAnimation` is a running `QAbstractAnimation`, and Qt Quick draws
a frame for as long as any animation runs. On a layer-shell surface that means
committing a buffer every frame, so the compositor recomposites the whole screen
forever.

Measured with two identical 10×10 invisible surfaces for 8 s under
`WAYLAND_DEBUG=1`:

| | `wl_surface.commit` |
|---|---|
| no always-on animation | 5 |
| one always-on `FrameAnimation` | 1,077 |

215×, from a ten-pixel invisible square. `Ticker` is one `FrameAnimation` whose
`running` is bound to whether anything is subscribed; springs subscribe on
retarget and are dropped when they settle. Idle costs zero by construction.

It is also cheaper in motion — N animation objects become one callback — and
every subscriber shares one `dt`, so coordinated motion is actually coordinated
instead of N things that happen to be moving at once.

## Why the document model is not a private format

`QmlWriter.write` and `QmlWriter.parse` are inverses over a defined subset. The
canvas, outline, inspector and source are views of one tree; none is the master
copy.

Two decisions make it usable rather than merely correct:

- **Bindings are structural** — `{ bind: "expr" }`, not a string convention.
  Every string convention is ambiguous: read `"parent.width"` as an expression
  and you cannot express that literal text; read it as a string and you cannot
  express the binding.
- **Unmodellable constructs survive verbatim.** A hand-written signal handler
  round-trips byte-identical through a canvas that cannot draw it. A builder
  that silently drops what it does not understand is worse than one that refuses
  to open the file: the second wastes an afternoon, the first loses work.

Output is deterministic — properties sorted — so the same document produces
byte-identical source. Without that, every save reorders properties and every
commit is an unreadable diff.

## Testing

Physics is checked against the **closed-form solution of the same differential
equation** — an oracle sharing no code or constants with the implementation, so
it can actually fail. The refresh-independence check is mutation-tested: swap
the caller's `dt` for a fixed 60 Hz step and the spread goes from 1.12% to
130.77%.

An idle-cost claim is only testable against the compositor. `qmllint` and the
unit suites are both blind to a Wayland commit; `WAYLAND_DEBUG=1` piped to
`grep -c wl_surface.commit` is the whole tool.
