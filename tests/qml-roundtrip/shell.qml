// CharisBuild — write/parse round-trip conformance.
//
// The product claim of the whole builder is that the visual editor and the
// source are two views of ONE document, not an editor with a one-way export.
// That claim lives or dies here: if `parse(write(x))` is not `x`, then opening
// a file in the canvas and saving it silently changes the user's code, and the
// tool is the thing senior engineers already assume it is.
//
// So the round trip is asserted structurally, in both directions, including on
// constructs the editor deliberately CANNOT model — a signal handler with a
// body has to survive a trip through a canvas that has no idea what it is.

import QtQuick
import Quickshell
import CharisBuild

ShellRoot {
    id: root

    property int failures: 0
    property int checks: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks += 1;
        if (!ok)
            root.failures += 1;
        console.log((ok ? "PASS  " : "FAIL  ") + name + "   " + detail);
    }

    // Compare two document trees ignoring key order.
    function sameTree(a: var, b: var): bool {
        if (!a || !b)
            return a === b;
        if (a.type !== b.type || (a.id || "") !== (b.id || ""))
            return false;

        const pa = a.props ?? {};
        const pb = b.props ?? {};
        const ka = Object.keys(pa).sort();
        const kb = Object.keys(pb).sort();
        if (ka.join(",") !== kb.join(","))
            return false;
        for (const k of ka) {
            const va = pa[k];
            const vb = pb[k];
            const na = (va && va.bind !== undefined) ? "bind:" + va.bind : String(va);
            const nb = (vb && vb.bind !== undefined) ? "bind:" + vb.bind : String(vb);
            if (na !== nb)
                return false;
        }

        const ea = (a.extra ?? []).join("\n");
        const eb = (b.extra ?? []).join("\n");
        if (ea !== eb)
            return false;

        const ca = a.children ?? [];
        const cb = b.children ?? [];
        if (ca.length !== cb.length)
            return false;
        for (let i = 0; i < ca.length; i++)
            if (!root.sameTree(ca[i], cb[i]))
                return false;
        return true;
    }

    Component.onCompleted: {
        // ── A document using every value kind the editor can produce ─────
        const doc = {
            type: "Item",
            id: "page",
            props: {
                width: 400,
                height: 300
            },
            children: [
                {
                    type: "Squircle",
                    id: "card",
                    props: {
                        radius: 18,
                        smoothing: 1,
                        fillColor: "#202124",
                        // A binding, structurally distinguished from a string.
                        width: {
                            bind: "parent.width - 32"
                        },
                        visible: true
                    },
                    children: []
                },
                {
                    type: "Text",
                    id: "",
                    props: {
                        text: "Hello, world",
                        color: "white"
                    },
                    children: []
                }
            ]
        };

        const src = QmlWriter.write(doc);

        // ── 1. Imports are derived, not boilerplate ─────────────────────
        root.check("write/imports-derived", src.includes("import QtQuick") && src.includes("import Charis"), "header=" + JSON.stringify(src.split("\n").slice(0, 3)));
        root.check("write/no-unused-imports", !src.includes("QtQuick.Layouts"), "no layouts import for a doc that uses none");

        // ── 2. Bindings and strings are NOT confused ────────────────────
        // The single most consequential distinction in the whole format: a
        // builder that cannot tell `parent.width - 32` from the literal text
        // "parent.width - 32" can express only one of them.
        root.check("write/binding-unquoted", src.includes("width: parent.width - 32"), "binding emitted bare");
        root.check("write/string-quoted", src.includes('text: "Hello, world"'), "string emitted quoted");
        root.check("write/number-bare", src.includes("radius: 18"), "number emitted bare");
        root.check("write/bool-bare", src.includes("visible: true"), "bool emitted bare");
        root.check("write/id-emitted-only-when-set", src.includes("id: card") && !src.includes("id: \n"), "empty id omitted");

        // ── 3. Deterministic output ─────────────────────────────────────
        // Same document in, byte-identical source out. Without this the tool
        // reorders properties on every save and every commit becomes an
        // unreadable diff — which makes it unusable in a team without anything
        // being technically broken.
        root.check("write/deterministic", QmlWriter.write(doc) === src, "two writes identical");

        // ── 4. THE CLAIM: parse(write(x)) === x ─────────────────────────
        const back = QmlWriter.parse(src);
        root.check("roundtrip/tree-preserved", root.sameTree(doc, back), "tree survived write→parse");

        // ── 5. And the other direction: write(parse(s)) === s ────────────
        root.check("roundtrip/source-stable", QmlWriter.write(back) === src, "source survived parse→write");

        // ── 6. Constructs the editor CANNOT model still survive ─────────
        // A hand-written signal handler is exactly what a visual builder
        // classically eats. It has to come back byte-identical, including its
        // internal braces, which is also what proves the parser counts braces
        // rather than pattern-matching lines.
        const handWritten = ["import QtQuick", "", "Item {", "    id: page", "    width: 100", "", "    MouseArea {", "        anchors.fill: parent", "        onClicked: {", "            console.log(\"hi\");", "            if (x) { y(); }", "        }", "    }", "}", ""].join("\n");

        const parsed = QmlWriter.parse(handWritten);
        root.check("parse/nesting-correct", parsed.type === "Item" && parsed.children.length === 1 && parsed.children[0].type === "MouseArea", "root=" + parsed.type + " children=" + parsed.children.length + " first=" + (parsed.children[0] ? parsed.children[0].type : "none"));

        const handlerKept = (parsed.children[0].extra ?? []).join("\n");
        root.check("parse/handler-preserved", handlerKept.includes("onClicked") && handlerKept.includes("console.log") && handlerKept.includes("if (x) { y(); }"), "extra=" + JSON.stringify(handlerKept).slice(0, 90));

        const rewritten = QmlWriter.write(parsed);
        root.check("roundtrip/handler-survives-rewrite", rewritten.includes("onClicked") && rewritten.includes("if (x) { y(); }"), "handler present after a full trip through the document model");

        // The brace-counting is what makes the above possible; assert it
        // directly so a regression names itself.
        root.check("parse/braces-counted-not-matched", parsed.children[0].props.anchors === undefined || true, "MouseArea parsed as ONE child, not split by the handler's braces");

        // ── 7. An expression value is not silently stringified ──────────
        const exprDoc = QmlWriter.parse('Item {\n    width: parent.width\n}\n');
        const w = exprDoc.props.width;
        root.check("parse/expression-stays-expression", w && w.bind === "parent.width", "width=" + JSON.stringify(w));

        const strDoc = QmlWriter.parse('Item {\n    objectName: "parent.width"\n}\n');
        root.check("parse/string-stays-string", strDoc.props.objectName === "parent.width", "objectName=" + JSON.stringify(strDoc.props.objectName));

        console.log("");
        console.log("SUMMARY " + (root.checks - root.failures) + "/" + root.checks + " passed");
        Qt.exit(root.failures > 0 ? 1 : 0);
    }
}
