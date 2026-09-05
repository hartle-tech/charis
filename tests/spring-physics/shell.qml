// Charis — Spring physics conformance test.
//
// WHY THIS EXISTS AS A REAL TEST AND NOT A SCREENSHOT. Motion is the one part
// of a UI where "it looks right" is worth almost nothing: a spring that is 15%
// over-damped, or that runs 40% faster on a 144 Hz panel than a 60 Hz one,
// looks completely fine in isolation and is only felt as "this doesn't feel
// like a Mac" months later, with no way to bisect what changed.
//
// So the integrator is checked against the CLOSED-FORM solution of the same
// differential equation. That is an independent oracle — it shares no code,
// no constants and no assumptions with the implementation, so it can actually
// fail. (A test that compares the spring against another copy of the spring
// cannot.)
//
// Run:
//   QML2_IMPORT_PATH=<…>/qml QT_QPA_PLATFORM=offscreen \
//     quickshell -p code/nix/pkgs/charis/tests/spring-physics
//
// Exits 0 on pass, 1 on any failure, and prints one line per check.

import QtQuick
import Quickshell
import Charis

ShellRoot {
    id: root

    readonly property real omega0: 2 * Math.PI / 0.4 // response = 0.4s

    property int failures: 0
    property int checks: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks += 1;
        if (!ok)
            root.failures += 1;
        console.log((ok ? "PASS  " : "FAIL  ") + name + "   " + detail);
    }

    function near(a: real, b: real, tolFrac: real): bool {
        const scale = Math.max(Math.abs(b), 1e-9);
        return Math.abs(a - b) / scale <= tolFrac;
    }

    // ── The oracle ──────────────────────────────────────────────────────
    // Step response of ẍ + 2ζω ẋ + ω²(x − A) = 0, from rest at 0.
    // Textbook, and deliberately written from the equation rather than
    // adapted from the implementation.
    function analytic(t: real, amp: real, zeta: real, w: real): real {
        if (Math.abs(zeta - 1) < 1e-9)
            return amp * (1 - (1 + w * t) * Math.exp(-w * t));
        if (zeta < 1) {
            const wd = w * Math.sqrt(1 - zeta * zeta);
            return amp * (1 - Math.exp(-zeta * w * t) * (Math.cos(wd * t) + (zeta * w / wd) * Math.sin(wd * t)));
        }
        const r = w * Math.sqrt(zeta * zeta - 1);
        const a1 = (zeta * w + r) / (2 * r);
        const a2 = -(zeta * w - r) / (2 * r);
        return amp * (1 - a1 * Math.exp(-(zeta * w - r) * t) - a2 * Math.exp(-(zeta * w + r) * t));
    }

    // Drive a spring at a FIXED timestep and report what it did. Fixed dt is
    // the whole point: it is how "would this behave the same at 144 Hz" gets
    // asked without owning four monitors.
    function run(dt: real, zeta: real, eps: real): var {
        const s = springFactory.createObject(root, {
            response: 0.4,
            damping: zeta,
            epsilon: eps,
            autoDrive: false   // ← this test owns the clock
        });
        s.reset(0);
        s.target = 100;

        let peak = 0;
        let steps = 0;

        // ⚠️ Probe by STEP INDEX, never by an accumulated time.
        //
        // The obvious `t += dt; if (t >= 0.1)` is wrong and wrong in a way
        // that reads as a physics bug. 1/60 is not representable in binary, so
        // six additions of it come to 0.09999999999999999 — just under the
        // threshold — and the probe fires one step late. The test then compares
        // a sample taken at t=0.1167 against the analytic value at t=0.1000 and
        // reports the integrator as 19% fast. It is not: the harness asked the
        // wrong question. Multiplying instead of accumulating removes the drift
        // entirely, and comparing at the sample's OWN time removes the rest.
        const probeSteps = [Math.round(0.1 / dt), Math.round(0.2 / dt), Math.round(0.3 / dt)];
        const samples = [];

        while (s.advance(dt)) {
            steps += 1;
            if (s.value > peak)
                peak = s.value;
            for (let i = 0; i < probeSteps.length; i++) {
                if (steps === probeSteps[i])
                    samples.push({
                        t: steps * dt,
                        value: s.value
                    });
            }
            if (steps > 200000) {
                console.log("FAIL  runaway: never settled at dt=" + dt);
                root.failures += 1;
                break;
            }
        }

        const out = {
            settle: steps * dt,
            peak: peak,
            final: s.value,
            steps: steps,
            samples: samples
        };
        s.destroy();
        return out;
    }

    Component {
        id: springFactory
        Spring {}
    }

    Component.onCompleted: {
        const w = root.omega0;

        // ── 1. Zero overshoot when critically damped ────────────────────
        // The defining property of ζ = 1. If this fails the sign or the
        // factor of 2 in the damping term is wrong, and everything else is
        // coincidence.
        const crit = root.run(1 / 60, 1.0, 0.001);
        root.check("crit/no-overshoot", crit.peak <= 100.0 + 1e-6, "peak=" + crit.peak.toFixed(6));
        root.check("crit/converges", root.near(crit.final, 100, 1e-5), "final=" + crit.final.toFixed(6));

        // ── 2. Trajectory matches the closed form ───────────────────────
        // Not just the endpoint — an over-damped integrator also reaches the
        // endpoint, just wrongly on the way there, which is exactly the
        // failure a human would describe as "feels mushy".
        for (const sample of crit.samples) {
            const want = root.analytic(sample.t, 100, 1.0, w);
            root.check("crit/trajectory@" + sample.t.toFixed(4) + "s", root.near(sample.value, want, 0.02), "got=" + sample.value.toFixed(3) + " analytic=" + want.toFixed(3));
        }

        // ── 3. Overshoot of an under-damped spring ──────────────────────
        // Closed form: exp(−πζ/√(1−ζ²)). For ζ=0.6 that is 9.478%.
        const bouncy = root.run(1 / 60, 0.6, 0.001);
        const wantPeak = 100 * (1 + Math.exp(-Math.PI * 0.6 / Math.sqrt(1 - 0.36)));
        root.check("bouncy/overshoot", root.near(bouncy.peak, wantPeak, 0.03), "peak=" + bouncy.peak.toFixed(3) + " analytic=" + wantPeak.toFixed(3));

        // ── 4. THE CLAIM: refresh-rate independence ─────────────────────
        // The library's central promise. Motion is specified in seconds, so
        // the same spring must take the same WALL TIME to settle whether the
        // panel runs at 30 Hz or 240 Hz. A fixed-dt integrator fails this
        // badly and nobody notices until the UI is on a second monitor.
        const rates = [30, 60, 90, 144, 240];
        const settles = [];
        for (const hz of rates)
            settles.push(root.run(1 / hz, 1.0, 0.01).settle);

        const mean = settles.reduce((a, b) => a + b, 0) / settles.length;
        let worst = 0;
        for (const s of settles)
            worst = Math.max(worst, Math.abs(s - mean) / mean);

        let table = "";
        for (let i = 0; i < rates.length; i++)
            table += rates[i] + "Hz=" + settles[i].toFixed(4) + "s ";
        root.check("refresh-independence", worst < 0.03, "spread=" + (worst * 100).toFixed(2) + "%  " + table);

        // ── 5. Stability under a pathological frame ─────────────────────
        // A converge, a GC pause or a monitor waking hands over a dt of
        // seconds. The spring must arrive, not detonate.
        const s = springFactory.createObject(root, {
            response: 0.15,
            damping: 0.8,
            autoDrive: false
        });
        s.reset(0);
        s.target = 100;
        let sane = true;
        for (let i = 0; i < 200; i++) {
            s.advance(1.5); // 1.5 SECONDS per step
            if (!isFinite(s.value) || Math.abs(s.value) > 1000)
                sane = false;
        }
        root.check("stability/huge-dt", sane && root.near(s.value, 100, 0.01), "value=" + s.value.toFixed(4));
        s.destroy();

        // ── 6. Retargeting preserves momentum ───────────────────────────
        // The entire reason springs beat easing curves. Retarget mid-flight
        // and velocity must survive; a curve-based animation would reset it
        // to zero and visibly stall.
        const r = springFactory.createObject(root, {
            response: 0.4,
            damping: 0.9,
            autoDrive: false
        });
        r.reset(0);
        r.target = 100;
        for (let i = 0; i < 10; i++)
            r.advance(1 / 60);
        const vBefore = r.velocity;
        r.target = 200;
        const vAfter = r.velocity;
        root.check("retarget/keeps-velocity", Math.abs(vBefore - vAfter) < 1e-9 && vBefore > 0, "v_before=" + vBefore.toFixed(3) + " v_after=" + vAfter.toFixed(3));
        r.destroy();

        // ── 7. A small-span spring must still animate ───────────────────
        // The epsilon footgun. `epsilon` defaults to 0.5, which is right for
        // pixels and catastrophic for a scale factor: |1.0 − 1.3| < 0.5 is
        // true on the first frame, so a naive implementation settles instantly
        // and the magnification silently has no animation at all. The property
        // still arrives at the correct value, which is exactly why nobody
        // would find this by looking.
        const scaleSpring = springFactory.createObject(root, {
            response: 0.4,
            damping: 1.0,
            autoDrive: false
        });
        scaleSpring.reset(1.0);
        scaleSpring.target = 1.3;
        let scaleFrames = 0;
        while (scaleSpring.advance(1 / 60) && scaleFrames < 10000)
            scaleFrames += 1;
        root.check("epsilon/small-span-animates", scaleFrames > 20 && root.near(scaleSpring.value, 1.3, 1e-4), "frames=" + scaleFrames + " final=" + scaleSpring.value.toFixed(6));
        scaleSpring.destroy();

        // ── 8. Idle costs nothing ───────────────────────────────────────
        // The whole reason Ticker exists. Every spring above ran with
        // autoDrive:false, so nothing should ever have subscribed; and after
        // an auto-driven spring settles, Ticker must have dropped it. A
        // non-zero count here means the process is drawing a frame forever,
        // which on a layer-shell surface means the compositor is too.
        root.check("ticker/idle-at-rest", Ticker.subscriberCount === 0 && !Ticker.running, "subscribers=" + Ticker.subscriberCount + " running=" + Ticker.running);

        // The auto-driven half has to be observed across real frames.
        const auto = springFactory.createObject(root, {
            response: 0.25,
            damping: 1.0
        });
        auto.reset(0);
        auto.target = 400;
        root.check("ticker/subscribes-on-target", Ticker.subscriberCount === 1, "subscribers=" + Ticker.subscriberCount);
        settleWatch.spring = auto;
        settleWatch.start();
    }

    property Timer _settleWatch: Timer {
        id: settleWatch
        property var spring: null
        interval: 2000
        repeat: false
        onTriggered: {
            root.check("ticker/unsubscribes-when-settled", Ticker.subscriberCount === 0 && !Ticker.running && root.near(settleWatch.spring.value, 400, 1e-4), "subscribers=" + Ticker.subscriberCount + " running=" + Ticker.running + " value=" + settleWatch.spring.value.toFixed(4));

            console.log("");
            console.log("SUMMARY " + (root.checks - root.failures) + "/" + root.checks + " passed");
            Qt.exit(root.failures > 0 ? 1 : 0);
        }
    }
}
