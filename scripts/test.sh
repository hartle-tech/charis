#!/usr/bin/env bash
# Run the Charis conformance suites.
#
# Headless: QT_QPA_PLATFORM=offscreen, no window is ever mapped, so this is
# safe to run on a machine someone is using.
#
#   ./scripts/test.sh                 all suites
#   ./scripts/test.sh spring-physics  one
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${1:-}"

command -v quickshell >/dev/null || {
  echo "quickshell not found — the suites use it as the QML runtime." >&2
  echo "See https://quickshell.outfoxxed.me/docs/guide/install" >&2
  exit 1
}

fail=0
for dir in "$ROOT"/tests/*/; do
  name=$(basename "$dir")
  [ -z "$SUITE" ] || [ "$SUITE" = "$name" ] || continue
  # glass-visual needs a REAL GPU context. ShaderEffect renders nothing at all
  # under QT_QPA_PLATFORM=offscreen — no error, no warning — so including it in
  # the headless sweep would report a working shader as broken. Run it by name
  # on a real session instead.
  if [ "$name" = "glass-visual" ] && [ -z "$SUITE" ]; then
    echo "── glass-visual ── skipped (needs a GPU context; run it by name)"
    continue
  fi
  echo
  echo "── $name ──────────────────────────────────────────"
  out=$(QML2_IMPORT_PATH="$ROOT/qml" QT_QPA_PLATFORM=offscreen \
        quickshell -p "$dir" 2>&1 |
        sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^ *DEBUG *qml: //' |
        grep -E 'PASS|FAIL|SUMMARY|Error|error:' || true)
  echo "$out"
  echo "$out" | grep -q '^PASS' || { echo "FAIL  suite produced no results"; fail=1; }
  echo "$out" | grep -q 'FAIL' && fail=1
done

echo
[ "$fail" = 0 ] && echo "✅ all suites passed" || echo "❌ suites FAILED"
exit "$fail"
