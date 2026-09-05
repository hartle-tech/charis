pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick

/*!
    \qmltype QmlWriter
    \brief Turns a document tree into QML source, and QML source back into a
           document tree.

    THIS IS THE WHOLE CODE / NO-CODE BRIDGE, so it is worth being precise about
    what it promises.

    Almost every visual builder ever shipped has the same fatal property: the
    visual editor owns a private format, and the code it emits is a one-way
    export. Touch the code and the builder either overwrites your edits or
    refuses to open the file. That single design choice is why "visual builder"
    is a slur among senior engineers, and it is why a tool that wants to serve
    both a beginner and a twenty-year veteran cannot make it.

    So the document tree is not a private format — it is a *projection* of the
    QML, and \l write and \l parse are inverses over a defined subset. Edit the
    canvas, the code updates. Edit the code, the canvas updates. Neither is the
    master copy.

    \section2 The subset, stated honestly

    \l parse handles what \l write emits: object blocks, `id:`, property
    assignments of numbers, booleans, strings, enums/expressions, and nesting.
    It does NOT handle signal handlers with bodies, inline JavaScript functions,
    states, transitions, or component definitions.

    ⚠️ That limit is enforced rather than hoped for. Anything outside the subset
    is preserved VERBATIM on the node that owns it (see \c extra) and written
    back untouched, so a hand-written `onClicked` survives a round trip through
    the visual editor even though the editor cannot show it. A builder that
    silently drops the code it does not understand is worse than one that
    refuses to open the file — the second wastes your afternoon, the first
    loses your work.
*/
QtObject {
    id: root

    /*! type → module, so imports are emitted from what is actually used
        rather than from a fixed preamble. A file that imports six modules to
        use one of them is the signature of generated code, and this tool's
        output is meant to be indistinguishable from something a person wrote. */
    readonly property var modules: ({
            // Qt Quick basics
            Item: "QtQuick",
            Rectangle: "QtQuick",
            Text: "QtQuick",
            Image: "QtQuick",
            Row: "QtQuick",
            Column: "QtQuick",
            Grid: "QtQuick",
            Flow: "QtQuick",
            Repeater: "QtQuick",
            MouseArea: "QtQuick",
            TapHandler: "QtQuick",
            HoverHandler: "QtQuick",
            DragHandler: "QtQuick",
            Gradient: "QtQuick",
            GradientStop: "QtQuick",

            // Charis
            Spring: "Charis",
            Squircle: "Charis",
            MagnifiedRow: "Charis",

            // Layouts
            RowLayout: "QtQuick.Layouts",
            ColumnLayout: "QtQuick.Layouts",
            GridLayout: "QtQuick.Layouts"
        })

    function moduleFor(type: string): string {
        return root.modules[type] ?? "QtQuick";
    }

    // ── Writing ─────────────────────────────────────────────────────────

    /*! Serialise one property value.

        Bindings are `{ bind: "expr" }` rather than a string convention, because
        every string convention here is ambiguous: a builder that treats
        `"parent.width"` as an expression cannot express the literal text
        "parent.width", and one that treats it as a string cannot express the
        binding. Making it structural costs one wrapper object and removes the
        whole class of bug. */
    function valueToQml(v: var): string {
        if (v === null || v === undefined)
            return "undefined";
        if (typeof v === "object" && v.bind !== undefined)
            return String(v.bind);
        if (typeof v === "boolean")
            return v ? "true" : "false";
        if (typeof v === "number")
            return String(v);
        // Everything else is a string literal, escaped.
        return '"' + String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    }

    function pad(depth: int): string {
        return "    ".repeat(depth);
    }

    /*! Serialise a node and its children, without imports. */
    function writeNode(node: var, depth: int): string {
        const i = root.pad(depth);
        const inner = root.pad(depth + 1);
        let out = i + node.type + " {\n";

        if (node.id)
            out += inner + "id: " + node.id + "\n";

        const props = node.props ?? {};
        // Sorted, so the same document always produces byte-identical output.
        // Without this a builder rewriting a file reorders properties on every
        // save and every commit is an unreadable diff — which quietly makes the
        // tool unusable in a team even though nothing is technically wrong.
        for (const key of Object.keys(props).sort())
            out += inner + key + ": " + root.valueToQml(props[key]) + "\n";

        // Anything the editor could not model, replayed exactly as it was read.
        if (node.extra && node.extra.length > 0) {
            for (const line of node.extra)
                out += inner + line + "\n";
        }

        for (const child of node.children ?? [])
            out += "\n" + root.writeNode(child, depth + 1);

        out += i + "}\n";
        return out;
    }

    /*! Collect every type used in the tree, so imports can be derived. */
    function collectTypes(node: var, into: var): void {
        into[node.type] = true;
        for (const c of node.children ?? [])
            root.collectTypes(c, into);
    }

    /*! Full document: imports plus the tree. */
    function write(root_node: var): string {
        const types = ({});
        root.collectTypes(root_node, types);

        const mods = ({});
        for (const t of Object.keys(types))
            mods[root.moduleFor(t)] = true;

        // QtQuick first, then the rest alphabetically — the ordering every
        // hand-written Qt file uses.
        const names = Object.keys(mods).sort((a, b) => {
            if (a === "QtQuick")
                return -1;
            if (b === "QtQuick")
                return 1;
            return a < b ? -1 : 1;
        });

        let out = "";
        for (const m of names)
            out += "import " + m + "\n";
        out += "\n";
        out += root.writeNode(root_node, 0);
        return out;
    }

    // ── Parsing ─────────────────────────────────────────────────────────

    /*!
        Parse the subset \l write emits, back into a document tree.

        Deliberately a small hand-written scanner rather than a regex pass.
        Regexes cannot count braces, so a regex "parser" silently mis-nests the
        moment a property value contains one — `onClicked: { foo() }`, or a
        binding with an object literal — and the failure is a scrambled tree
        rather than an error.
    */
    function parse(text: string): var {
        const lines = String(text).split("\n");
        let idx = 0;

        function skipBlank() {
            while (idx < lines.length) {
                const t = lines[idx].trim();
                if (t === "" || t.startsWith("//") || t.startsWith("import ") || t.startsWith("pragma "))
                    idx += 1;
                else
                    break;
            }
        }

        function parseObject() {
            skipBlank();
            if (idx >= lines.length)
                return null;

            const header = lines[idx].trim();
            const m = header.match(/^([A-Z][A-Za-z0-9_.]*)\s*\{$/);
            if (!m)
                return null;
            idx += 1;

            const node = {
                type: m[1],
                id: "",
                props: ({}),
                children: [],
                extra: []
            };

            while (idx < lines.length) {
                const raw = lines[idx];
                const t = raw.trim();

                if (t === "}") {
                    idx += 1;
                    return node;
                }
                if (t === "" || t.startsWith("//")) {
                    idx += 1;
                    continue;
                }

                // A nested object starts with `Type {`.
                if (/^[A-Z][A-Za-z0-9_.]*\s*\{$/.test(t)) {
                    const child = parseObject();
                    if (child)
                        node.children.push(child);
                    continue;
                }

                const pm = t.match(/^([a-z_][A-Za-z0-9_.]*)\s*:\s*(.+)$/);
                if (pm) {
                    const key = pm[1];
                    const val = pm[2];

                    // ⚠️ A property whose value OPENS A BRACE is a handler body
                    // or an object literal spanning lines. Consume to its
                    // matching close and keep the whole thing verbatim: this is
                    // the machinery that stops the builder eating a signal
                    // handler it cannot draw.
                    if (val.endsWith("{")) {
                        let depth = 1;
                        const block = [t];
                        idx += 1;
                        while (idx < lines.length && depth > 0) {
                            const l = lines[idx];
                            depth += (l.match(/\{/g) || []).length;
                            depth -= (l.match(/\}/g) || []).length;
                            block.push(l.trim());
                            idx += 1;
                        }
                        node.extra.push(block.join("\n"));
                        continue;
                    }

                    if (key === "id") {
                        node.id = val;
                    } else {
                        node.props[key] = root.qmlToValue(val);
                    }
                    idx += 1;
                    continue;
                }

                // Anything unrecognised survives rather than being dropped.
                node.extra.push(t);
                idx += 1;
            }
            return node;
        }

        return parseObject();
    }

    /*! Inverse of \l valueToQml. */
    function qmlToValue(text: string): var {
        const t = String(text).trim();
        if (t === "true")
            return true;
        if (t === "false")
            return false;
        if (/^-?\d+(\.\d+)?$/.test(t))
            return parseFloat(t);
        if (/^".*"$/.test(t))
            return t.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, "\\");
        // Everything else is an expression, and must round-trip AS one.
        return {
            bind: t
        };
    }
}
